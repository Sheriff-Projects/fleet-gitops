# install_microsoft_365.ps1
#
# Installe Microsoft 365 (Word + Excel + PowerPoint + Outlook) via le
# Office Deployment Tool de Microsoft. Configuration Sheriff Projects :
#   - Langue : français (fr-FR)
#   - Channel : MonthlyEnterprise (stable, recommandé en entreprise)
#   - 64-bit
#   - Produit : O365BusinessRetail (Microsoft 365 Business)
#   - EXCLUS : Access, OneNote, Publisher, Teams, OneDrive, Skype, Bing
#
# Pour modifier la sélection des apps, modifie le bloc <Configuration> ci-dessous.
#
# Fleet passe le chemin de setup.exe via $env:INSTALLER_PATH.
# Le script :
#   1. Écrit config.xml sur disque
#   2. Copie setup.exe à un emplacement persistant (pour uninstall plus tard)
#   3. Lance setup.exe /configure config.xml (Microsoft télécharge ~3 GB + installe)
#   4. Log dans C:\ProgramData\SheriffProjects\Logs\
#
# Durée typique : 15-30 min selon la bande passante.

$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------------
$PersistentDir = "C:\ProgramData\SheriffProjects"
$PersistentSetupExe = Join-Path $PersistentDir "OfficeSetup.exe"
$LogDir = Join-Path $PersistentDir "Logs"
$LogFile = Join-Path $LogDir "microsoft_365_install.log"
$ConfigXml = Join-Path $env:TEMP "m365_install.xml"

# -------------------------------------------------------------------------
# Setup logging
# -------------------------------------------------------------------------
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
New-Item -Path $PersistentDir -ItemType Directory -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

Write-Log "============================================================"
Write-Log "=== Microsoft 365 install started ==="
Write-Log "============================================================"

# -------------------------------------------------------------------------
# 1. Vérifier que Fleet nous a bien passé setup.exe
# -------------------------------------------------------------------------
if (-not $env:INSTALLER_PATH) {
    Write-Log "[ERROR] `$env:INSTALLER_PATH non défini"
    exit 1
}

if (-not (Test-Path $env:INSTALLER_PATH)) {
    Write-Log "[ERROR] setup.exe introuvable à : $env:INSTALLER_PATH"
    exit 1
}

Write-Log "setup.exe trouvé : $env:INSTALLER_PATH"

# -------------------------------------------------------------------------
# 2. Copier setup.exe à un emplacement persistant pour l'uninstall futur
# -------------------------------------------------------------------------
Write-Log "Copie de setup.exe vers $PersistentSetupExe (pour uninstall)"
Copy-Item -Path $env:INSTALLER_PATH -Destination $PersistentSetupExe -Force

# -------------------------------------------------------------------------
# 3. Écrire config.xml d'installation
# -------------------------------------------------------------------------
# Documentation Microsoft : https://learn.microsoft.com/deployoffice/office-deployment-tool-configuration-options
#
# Pour changer le Product ID selon ta licence Microsoft 365 :
#   O365BusinessRetail  → Microsoft 365 Business Basic/Standard
#   O365ProPlusRetail   → Microsoft 365 Apps for Enterprise (E3, E5)
#   O365HomePremRetail  → Microsoft 365 Family (perso)
#   O365EnterpriseRetail → Microsoft 365 Enterprise
#
# Pour changer le channel :
#   Current             → mises à jour mensuelles (plus récent mais peut casser)
#   MonthlyEnterprise   → ⭐ recommandé (mensuel mais testé, on l'utilise)
#   SemiAnnual          → mises à jour 2x/an (très conservateur)
#   PerpetualVL2024     → Office 2024 sans souscription (volume license)

$configContent = @'
<Configuration ID="sheriff-projects-m365-install">
  <Add OfficeClientEdition="64" Channel="MonthlyEnterprise" SourcePath="" AllowCdnFallback="TRUE">
    <Product ID="O365BusinessRetail">
      <Language ID="fr-FR" />
      <ExcludeApp ID="Access" />
      <ExcludeApp ID="Bing" />
      <ExcludeApp ID="Groove" />
      <ExcludeApp ID="Lync" />
      <ExcludeApp ID="OneDrive" />
      <ExcludeApp ID="OneNote" />
      <ExcludeApp ID="Publisher" />
      <ExcludeApp ID="Teams" />
    </Product>
  </Add>
  <Property Name="SharedComputerLicensing" Value="0" />
  <Property Name="PinIconsToTaskbar" Value="FALSE" />
  <Property Name="AUTOACTIVATE" Value="0" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Property Name="DeviceBasedLicensing" Value="0" />
  <Property Name="SCLCacheOverride" Value="0" />
  <Updates Enabled="TRUE" Channel="MonthlyEnterprise" />
  <RemoveMSI />
  <AppSettings>
    <Setup Name="Company" Value="Sheriff Projects" />
  </AppSettings>
  <Display Level="None" AcceptEULA="TRUE" />
  <Logging Level="Standard" Path="C:\ProgramData\SheriffProjects\Logs" />
</Configuration>
'@

Write-Log "Écriture de config.xml à $ConfigXml"
Set-Content -Path $ConfigXml -Value $configContent -Encoding UTF8

# -------------------------------------------------------------------------
# 4. Lancer setup.exe /configure config.xml
# -------------------------------------------------------------------------
Write-Log "Lancement de setup.exe /configure (téléchargement + install, peut prendre 15-30 min)..."
Write-Log "  setup.exe : $env:INSTALLER_PATH"
Write-Log "  config    : $ConfigXml"

$process = Start-Process `
    -FilePath $env:INSTALLER_PATH `
    -ArgumentList "/configure", "`"$ConfigXml`"" `
    -Wait `
    -PassThru `
    -WindowStyle Hidden

$exitCode = $process.ExitCode
Write-Log "setup.exe exit code : $exitCode"

if ($exitCode -ne 0) {
    Write-Log "[ERROR] Installation Office a échoué"
    Write-Log "Logs Office : C:\ProgramData\SheriffProjects\Logs\"
    exit $exitCode
}

# -------------------------------------------------------------------------
# 5. Vérification — Word doit exister
# -------------------------------------------------------------------------
$wordPaths = @(
    "C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE",
    "C:\Program Files (x86)\Microsoft Office\root\Office16\WINWORD.EXE"
)

$wordFound = $false
foreach ($p in $wordPaths) {
    if (Test-Path $p) {
        $wordFound = $true
        Write-Log "Word.exe trouvé : $p"
        break
    }
}

if (-not $wordFound) {
    Write-Log "[ERROR] Word.exe introuvable après install"
    exit 1
}

# -------------------------------------------------------------------------
# 6. Cleanup config.xml temporaire
# -------------------------------------------------------------------------
Remove-Item -Path $ConfigXml -Force -ErrorAction SilentlyContinue

Write-Log "============================================================"
Write-Log "=== Microsoft 365 install successful ==="
Write-Log "============================================================"
Write-Log "Les utilisateurs doivent se connecter avec leur compte Microsoft 365"
Write-Log "au premier lancement de Word/Excel/etc. pour activer la license."

exit 0
