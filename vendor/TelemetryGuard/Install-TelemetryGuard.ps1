#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installe TelemetryGuard - protection permanente contre la reactivation de la telemetrie.
.DESCRIPTION
    Version kit portable. Adaptations par rapport a l'original :
    - Chemins deja en C:\ProgramData\TelemetryGuard (portable)
    - Parametre -DisableSmartScreen transmis aux taches planifiees
    Copie Disable-WindowsTelemetry.ps1 dans C:\ProgramData\TelemetryGuard\
    Cree 2 taches planifiees : apres chaque Windows Update (Event ID 19) + au demarrage.
#>

param(
    [switch]$DisableSmartScreen,
    [switch]$BlockTelemetryIPs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$GuardDir     = 'C:\ProgramData\TelemetryGuard'
$MainScript   = 'Disable-WindowsTelemetry.ps1'
$SourceScript = Join-Path $PSScriptRoot $MainScript
$TargetScript = Join-Path $GuardDir $MainScript
$TaskNameWU   = 'TelemetryGuard-OnWindowsUpdate'
$TaskNameBoot = 'TelemetryGuard-OnStartup'

Write-Host "`n=== TelemetryGuard Installer (kit portable) ===" -ForegroundColor Cyan

if (-not (Test-Path $SourceScript)) {
    Write-Host "ERREUR : $MainScript introuvable dans le meme dossier que cet installeur." -ForegroundColor Red
    exit 1
}

# Dossier protege
if (-not (Test-Path $GuardDir)) { New-Item -ItemType Directory -Path $GuardDir -Force | Out-Null }

$acl = Get-Acl $GuardDir
$acl.SetAccessRuleProtection($true, $false)
$sidAdmins  = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
$sidSystem  = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
$adminRule  = New-Object System.Security.AccessControl.FileSystemAccessRule($sidAdmins, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule($sidSystem, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($adminRule)
$acl.AddAccessRule($systemRule)
Set-Acl -Path $GuardDir -AclObject $acl
Write-Host "OK  Dossier securise : $GuardDir" -ForegroundColor Green

Copy-Item -Path $SourceScript -Destination $TargetScript -Force
Write-Host "OK  Script copie : $TargetScript" -ForegroundColor Green

# Supprimer les taches existantes (idempotent)
foreach ($name in @($TaskNameWU, $TaskNameBoot)) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
    }
}

# Construire les arguments en tenant compte du profil installe
$scriptArgs = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$TargetScript`""
if ($DisableSmartScreen) { $scriptArgs += ' -DisableSmartScreen' }
if ($BlockTelemetryIPs)  { $scriptArgs += ' -BlockTelemetryIPs'  }

# Tache 1 : apres Windows Update (Event ID 19)
$xmlWU = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>TelemetryGuard - Reapplique les restrictions de telemetrie apres chaque Windows Update.</Description>
    <Author>TelemetryGuard</Author>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Delay>PT5M</Delay>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-WindowsUpdateClient'] and EventID=19]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions>
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$scriptArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Register-ScheduledTask -TaskName $TaskNameWU -Xml $xmlWU -Force | Out-Null
Write-Host "OK  Tache creee : $TaskNameWU (Windows Update Event ID 19 + 5 min)" -ForegroundColor Green

# Tache 2 : au demarrage (fallback)
$xmlBoot = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>TelemetryGuard - Fallback au demarrage.</Description>
    <Author>TelemetryGuard</Author>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>PT2M</Delay>
    </BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions>
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$scriptArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Register-ScheduledTask -TaskName $TaskNameBoot -Xml $xmlBoot -Force | Out-Null
Write-Host "OK  Tache creee : $TaskNameBoot (demarrage + 2 min)" -ForegroundColor Green

Write-Host "`n=== Installation terminee ===" -ForegroundColor Cyan
Write-Host "Script permanent : $TargetScript"
Write-Host "Profil           : SmartScreen=$(if ($DisableSmartScreen) {'desactive'} else {'garde (defaut)'})"
Write-Host "La telemetrie sera automatiquement desactivee apres chaque mise a jour Windows." -ForegroundColor Green
