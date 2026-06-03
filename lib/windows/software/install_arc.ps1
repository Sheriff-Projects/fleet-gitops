<#
    install_arc.ps1 — Script d'installation Arc pour Fleet (custom package .exe)

    Contexte important :
    - fleetd exécute ce script en tant que NT AUTHORITY\SYSTEM.
    - Arc s'installe PAR UTILISATEUR dans %LOCALAPPDATA% (style Squirrel/Chromium).
    - Lancer l'installeur tel quel en SYSTEM l'installerait dans le profil système
      (C:\Windows\System32\config\systemprofile) -> invisible pour l'utilisateur.
    => On relance donc l'installeur dans le contexte de l'utilisateur connecté
       via une tâche planifiée temporaire, et on récupère son code de sortie.

    Variables Fleet :
    - $env:INSTALLER_PATH : chemin de arcInstaller.exe téléchargé par fleetd.

    À VALIDER pour ton tenant :
    - $InstallerArgs : Arc ne documente pas de flag silencieux officiel.
      Teste, dans cet ordre : "" (rien), "/S", "/silent", "--silent".
      Laisse "" si l'installeur s'exécute sans dialogue bloquant.
#>

$ErrorActionPreference = 'Stop'

# ---- Paramètres ----------------------------------------------------------
$AppName       = 'Arc'
$InstallerArgs = ''                       # cf. note ci-dessus
$TimeoutSec    = 900                       # 15 min max pour l'install
$WorkRoot      = Join-Path $env:ProgramData 'FleetArc'
$StageDir      = Join-Path $WorkRoot 'install'
$RunnerPath    = Join-Path $StageDir 'run-install.ps1'
$ResultPath    = Join-Path $StageDir 'result.txt'
$StagedExe     = Join-Path $StageDir 'arcInstaller.exe'
$LogPath       = Join-Path $WorkRoot 'install.log'
$TaskName      = 'Fleet-Install-Arc'

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try { Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue } catch {}
}

function Get-LoggedOnUser {
    # Renvoie "DOMAINE\utilisateur" de la session interactive, ou $null.
    try {
        $u = (Get-CimInstance Win32_ComputerSystem).UserName
        if ($u) { return $u }
    } catch {}
    try {
        $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" |
                    Select-Object -First 1
        if ($explorer) {
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
            if ($owner.User) { return "$($owner.Domain)\$($owner.User)" }
        }
    } catch {}
    return $null
}

try {
    # Préparation du dossier de travail (lisible/inscriptible par l'utilisateur)
    New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
    $acl  = Get-Acl $StageDir
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        'BUILTIN\Users','Modify','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -Path $StageDir -AclObject $acl

    Write-Log "Démarrage installation $AppName."

    # 1) Récupération de l'installeur fourni par Fleet
    $installer = $env:INSTALLER_PATH
    if ([string]::IsNullOrWhiteSpace($installer) -or -not (Test-Path $installer)) {
        Write-Log "INSTALLER_PATH introuvable : '$installer'"
        exit 1
    }
    Copy-Item -Path $installer -Destination $StagedExe -Force
    Write-Log "Installeur copié vers $StagedExe"

    # 2) Utilisateur connecté ?
    $user = Get-LoggedOnUser
    if (-not $user) {
        Write-Log "Aucun utilisateur interactif connecté. Arc s'installe par-utilisateur ; impossible d'installer maintenant."
        Write-Log "Recommandation : publier Arc en self-service pour que l'utilisateur déclenche l'install quand il est connecté."
        exit 1
    }
    Write-Log "Utilisateur cible : $user"

    # 3) Script enfant exécuté DANS le contexte utilisateur
    if (Test-Path $ResultPath) { Remove-Item $ResultPath -Force }
    $runner = @"
`$ErrorActionPreference = 'Continue'
try {
    `$args = '$InstallerArgs'
    if ([string]::IsNullOrWhiteSpace(`$args)) {
        `$p = Start-Process -FilePath '$StagedExe' -PassThru -Wait
    } else {
        `$p = Start-Process -FilePath '$StagedExe' -ArgumentList `$args -PassThru -Wait
    }
    Set-Content -Path '$ResultPath' -Value `$p.ExitCode -Encoding ASCII
} catch {
    Set-Content -Path '$ResultPath' -Value 1603 -Encoding ASCII
}
"@
    Set-Content -Path $RunnerPath -Value $runner -Encoding UTF8

    # 4) Tâche planifiée en contexte utilisateur (non élevé = install per-user)
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$RunnerPath`""
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $task      = New-ScheduledTask -Action $action -Principal $principal
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Log "Tâche '$TaskName' lancée."

    # 5) Attente du résultat
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not (Test-Path $ResultPath) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
    }

    $exitCode = 1
    if (Test-Path $ResultPath) {
        $exitCode = [int]((Get-Content $ResultPath -Raw).Trim())
        Write-Log "Installeur terminé, code de sortie : $exitCode"
    } else {
        Write-Log "Timeout ($TimeoutSec s) sans résultat de l'installeur."
        $exitCode = 1460  # ERROR_TIMEOUT
    }

    exit $exitCode
}
catch {
    Write-Log "ERREUR : $($_.Exception.Message)"
    exit 1
}
finally {
    # Nettoyage
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item $RunnerPath, $StagedExe -Force -ErrorAction SilentlyContinue } catch {}
}