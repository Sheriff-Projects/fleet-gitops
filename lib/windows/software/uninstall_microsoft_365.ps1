# uninstall_microsoft_365.ps1
#
# Désinstalle Microsoft 365 du PC.
#
# Stratégie en 2 temps :
#   1. Méthode 1 — On utilise le setup.exe persistant qu'on avait copié lors
#      de l'install, plus un remove XML.
#   2. Méthode 2 — Si setup.exe n'est pas dispo (install manuel, machine
#      réinitialisée), fallback sur le UninstallString trouvé dans le registre.

$ErrorActionPreference = 'Continue'

$PersistentDir = "C:\ProgramData\SheriffProjects"
$PersistentSetupExe = Join-Path $PersistentDir "OfficeSetup.exe"
$LogDir = Join-Path $PersistentDir "Logs"
$LogFile = Join-Path $LogDir "microsoft_365_uninstall.log"
$ConfigXml = Join-Path $env:TEMP "m365_uninstall.xml"

New-Item -Path $LogDir -ItemType Directory -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

Write-Log "============================================================"
Write-Log "=== Microsoft 365 uninstall started ==="
Write-Log "============================================================"

# -------------------------------------------------------------------------
# 1. Tuer les apps Office en cours
# -------------------------------------------------------------------------
$officeApps = @('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'MSACCESS', 'ONENOTE', 'MSPUB', 'OfficeClickToRun')
foreach ($app in $officeApps) {
    $processes = Get-Process -Name $app -ErrorAction SilentlyContinue
    if ($processes) {
        Write-Log "Kill $app ($($processes.Count) processus)"
        $processes | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 2

# -------------------------------------------------------------------------
# 2. Méthode 1 — Via setup.exe persistant + remove XML
# -------------------------------------------------------------------------
$method1Success = $false

if (Test-Path $PersistentSetupExe) {
    Write-Log "setup.exe persistant trouvé à $PersistentSetupExe"

    $removeXml = @'
<Configuration ID="sheriff-projects-m365-uninstall">
  <Remove All="TRUE">
    <Product ID="O365BusinessRetail">
      <Language ID="fr-FR" />
    </Product>
  </Remove>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Logging Level="Standard" Path="C:\ProgramData\SheriffProjects\Logs" />
</Configuration>
'@

    Set-Content -Path $ConfigXml -Value $removeXml -Encoding UTF8
    Write-Log "Lancement de setup.exe /configure (uninstall)..."

    $process = Start-Process `
        -FilePath $PersistentSetupExe `
        -ArgumentList "/configure", "`"$ConfigXml`"" `
        -Wait `
        -PassThru `
        -WindowStyle Hidden

    Write-Log "setup.exe exit code : $($process.ExitCode)"

    if ($process.ExitCode -eq 0) {
        $method1Success = $true
        Write-Log "Méthode 1 (setup.exe) réussie"
    } else {
        Write-Log "[WARN] Méthode 1 a échoué (code $($process.ExitCode)), bascule sur méthode 2"
    }

    Remove-Item -Path $ConfigXml -Force -ErrorAction SilentlyContinue
} else {
    Write-Log "setup.exe persistant absent, bascule directement sur méthode 2"
}

# -------------------------------------------------------------------------
# 3. Méthode 2 — Fallback via UninstallString du registre
# -------------------------------------------------------------------------
if (-not $method1Success) {
    Write-Log "Recherche d'Office dans le registre..."

    $uninstallKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $officeEntries = @()
    foreach ($keyPath in $uninstallKeys) {
        $entries = Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -and (
                    $_.DisplayName -like "*Microsoft 365*" -or
                    $_.DisplayName -like "*Office 365*" -or
                    $_.DisplayName -like "*Microsoft Office*"
                )
            }
        $officeEntries += $entries
    }

    if ($officeEntries.Count -eq 0) {
        Write-Log "Aucune installation Office trouvée dans le registre — rien à faire"
        Write-Log "=== Microsoft 365 uninstall: nothing to do ==="
        exit 0
    }

    foreach ($entry in $officeEntries) {
        Write-Log "Office trouvé : $($entry.DisplayName) (v$($entry.DisplayVersion))"

        if ($entry.UninstallString) {
            Write-Log "  UninstallString : $($entry.UninstallString)"

            # UninstallString typique pour Office Click-to-Run :
            # "C:\Program Files\Common Files\microsoft shared\ClickToRun\OfficeClickToRun.exe"
            # scenario=install scenariosubtype=ARP sourcetype=None productstoremove=... culture=...

            try {
                # Split the uninstall string into executable and args
                if ($entry.UninstallString -match '^"([^"]+)"\s*(.*)$') {
                    $exe = $matches[1]
                    $args = $matches[2]
                } else {
                    $parts = $entry.UninstallString -split ' ', 2
                    $exe = $parts[0]
                    $args = if ($parts.Count -gt 1) { $parts[1] } else { '' }
                }

                # Ajoute DisplayLevel=False pour silent si pas déjà
                if ($args -notmatch 'DisplayLevel') {
                    $args += ' DisplayLevel=False'
                }

                Write-Log "  Exe  : $exe"
                Write-Log "  Args : $args"

                $process = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
                Write-Log "  Exit code : $($process.ExitCode)"
            } catch {
                Write-Log "[ERROR] Échec uninstall via registre : $_"
            }
        }
    }
}

# -------------------------------------------------------------------------
# 4. Cleanup des fichiers persistants Sheriff Projects
# -------------------------------------------------------------------------
if (Test-Path $PersistentSetupExe) {
    Write-Log "Suppression de $PersistentSetupExe"
    Remove-Item -Path $PersistentSetupExe -Force -ErrorAction SilentlyContinue
}

Write-Log "============================================================"
Write-Log "=== Microsoft 365 uninstall successful ==="
Write-Log "============================================================"

exit 0
