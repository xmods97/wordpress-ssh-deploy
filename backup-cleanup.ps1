[CmdletBinding()]
param(
    [string] $ConfigPath = '',
    [switch] $ConfirmDelete,
    [string] $ProfilesDirectory = ''
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path $toolRoot 'src\WordPressSshDeploy.psm1'
$configFile = if ([string]::IsNullOrWhiteSpace($ConfigPath)) { throw 'Explicit -ConfigPath is required. Select a site profile through menu.ps1 or pass the profile path directly.' } elseif ([IO.Path]::IsPathRooted($ConfigPath)) { [IO.Path]::GetFullPath($ConfigPath) } else { [IO.Path]::GetFullPath((Join-Path $toolRoot $ConfigPath)) }
Import-Module $modulePath -Force
if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) { throw "Configuration file was not found: $configFile" }
. $configFile
Assert-DeployConfiguration $DeployConfig
$profileDirectory = Split-Path -Parent $configFile
$canonicalProfilesDirectory = if ([string]::IsNullOrWhiteSpace($ProfilesDirectory)) { $profileDirectory } else { [IO.Path]::GetFullPath($ProfilesDirectory) }
Assert-ProfileIsolation -Configuration $DeployConfig -ProfilePath $configFile -ProfilesDirectory $profileDirectory -CanonicalProfilesDirectory $canonicalProfilesDirectory
if (-not $DeployConfig.Contains('LocalBackupDirectory')) { throw 'LocalBackupDirectory is required for backup cleanup.' }
$root = [IO.Path]::GetFullPath([string] $DeployConfig.LocalBackupDirectory)
if (-not (Test-Path -LiteralPath $root -PathType Container)) { Write-Host "No local backup directory: $root"; return }
$keep = if ($DeployConfig.Contains('KeepLocalBackups')) { [int] $DeployConfig.KeepLocalBackups } else { [int] $DeployConfig.KeepBackups }
$ageDays = if ($DeployConfig.Contains('KeepBackupDays')) { [int] $DeployConfig.KeepBackupDays } else { 0 }
$maxBytes = if ($DeployConfig.Contains('MaxBackupSizeMB')) { [long] $DeployConfig.MaxBackupSizeMB * 1MB } else { 0 }
$retention = Get-LocalBackupRetentionPlan -BackupDirectory $root -Keep $keep -KeepDays $ageDays -MaxBytes $maxBytes
$remove = @($retention.Remove)
if ($remove.Count -eq 0) { Write-Host 'Backup cleanup preview: nothing would be removed; the newest backup group is always retained.'; return }
Write-Host "Backup cleanup preview for $root" -ForegroundColor Cyan
$remove | ForEach-Object { foreach ($item in @($_.Items)) { Write-Host "  REMOVE $($item.FullName)" -ForegroundColor Yellow } }
if (-not $ConfirmDelete) { Write-Host 'Preview only. Re-run with -ConfirmDelete to remove exactly these entries.'; return }
foreach ($group in $remove) { foreach ($item in @($group.Items)) { Remove-Item -LiteralPath $item.FullName -Recurse -Force } }
Write-Host "Removed $($remove.Count) backup group(s)." -ForegroundColor Green
