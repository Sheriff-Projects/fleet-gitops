<#
    uninstall_arc.ps1 — Script de désinstallation Arc pour Fleet (custom package .exe)

    Logique :
    - Arc enregistre sa clé de désinstallation côté UTILISATEUR :
      HKEY_USERS\<SID>\Software\Microsoft\Windows\CurrentVersion\Uninstall\*
      (avec QuietUninstallString / UninstallString).
    - fleetd tourne en SYSTEM : on lit la ruche de l'utilisateur connecté,
      on récupère la commande de désinstallation, puis on l'exécute DANS le
      contexte de cet utilisateur via une tâche planifiée temporaire.

    Variable Fleet :
    - $PACKAGE_ID : pour un EXE, Fleet y substitue le NOM du logiciel à l'upload.
      Sert ici à cibler la bonne entrée (DisplayName).
#>

$ErrorActionPreference = 'Stop'

# ---- Cible : nom du logiciel (substitué par Fleet à l'upload) -------------
$TargetDisplayName = '$PACKAGE_ID'
# Repli si le placeholder n'a pas été substitué (exécution hors Fleet) :
if ($TargetDisplayName -eq ('$' + 'PACKAGE_ID') -or [string]::IsNullOrWhiteSpace($TargetDisplayName)) {
    $TargetDisplayName = 'Arc'
}

# ---- Paramètres ----------------------------------------------------------
$TimeoutSec = 300
$WorkRoot   = Join-Path $env:ProgramData 'FleetArc'
$StageDir   = Join-Path $WorkRoot 'uninstall'
$RunnerPath = Join-Path $StageDir 'run-uninstall.ps1'
$ResultPath = Join-Path $StageDir 'result.txt'
$LogPath    = Join-Path $WorkRoot 'uninstall.log'
$TaskName   = 'Fleet-Uninstall-Arc'

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try { Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue } catch {}
}

function Get-LoggedOnUser {
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

function Get-UserSid {
    param([string]$UserName)
    try {
        return (New-Object System.Security.Principal.NTAccount($UserName)
               ).Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch { return $null }
}

function Find-UninstallString {
    param([string]$Sid, [string]$DisplayName)
    # Cherche dans la ruche utilisateur (per-user) puis dans HKLM (défensif).
    $roots = @(
        "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -and $p.DisplayName -like "*$DisplayName*") {
                $cmd = $p.QuietUninstallString
                if ([string]::IsNullOrWhiteSpace($cmd)) { $cmd = $p.UninstallString }
                if ($cmd) {
                    return [pscustomobject]@{ DisplayName = $p.DisplayName; Command = $cmd }
                }
            }
        }
    }
    return $null
}

try {
    New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
    $acl  = Get-Acl $StageDir
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        'BUILTIN\Users','Modify','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -Path $StageDir -AclObject $acl

    Write-Log "Démarrage désinstallation (cible DisplayName ~ '$TargetDisplayName')."

    $user = Get-LoggedOnUser
    if (-not $user) {
        Write-Log "Aucun utilisateur interactif connecté ; impossible de désinstaller une appli per-user maintenant."
        exit 1
    }
    $sid = Get-UserSid -UserName $user
    if (-not $sid) { Write-Log "SID introuvable pour $user."; exit 1 }
    Write-Log "Utilisateur : $user (SID $sid)"

    $entry = Find-UninstallString -Sid $sid -DisplayName $TargetDisplayName
    if (-not $entry) {
        Write-Log "Aucune entrée de désinstallation trouvée -> rien à faire (déjà absent)."
        exit 0
    }
    Write-Log "Trouvé : $($entry.DisplayName)"
    Write-Log "Commande : $($entry.Command)"

    if (Test-Path $ResultPath) { Remove-Item $ResultPath -Force }

    # La commande Squirrel est typiquement : "...\Update.exe" --uninstall
    # On l'exécute telle quelle via cmd pour gérer guillemets/arguments.
    $escaped = $entry.Command.Replace("'", "''")
    $runner = @"
`$ErrorActionPreference = 'Continue'
try {
    `$p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c','$escaped' -PassThru -Wait
    Set-Content -Path '$ResultPath' -Value `$p.ExitCode -Encoding ASCII
} catch {
    Set-Content -Path '$ResultPath' -Value 1 -Encoding ASCII
}
"@
    Set-Content -Path $RunnerPath -Value $runner -Encoding UTF8

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$RunnerPath`""
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $task      = New-ScheduledTask -Action $action -Principal $principal
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Log "Tâche '$TaskName' lancée."

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not (Test-Path $ResultPath) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
    }

    $exitCode = 1
    if (Test-Path $ResultPath) {
        $exitCode = [int]((Get-Content $ResultPath -Raw).Trim())
        Write-Log "Désinstallation terminée, code : $exitCode"
    } else {
        Write-Log "Timeout ($TimeoutSec s)."
        $exitCode = 1460
    }
    exit $exitCode
}
catch {
    Write-Log "ERREUR : $($_.Exception.Message)"
    exit 1
}
finally {
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item $RunnerPath -Force -ErrorAction SilentlyContinue } catch {}
}