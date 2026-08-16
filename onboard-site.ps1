[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)] [string] $ConfigPath,
	[string] $ProfilesDirectory = ''
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path $toolRoot 'src\WordPressSshDeploy.psm1'
$configFile = if ([IO.Path]::IsPathRooted($ConfigPath)) {
	[IO.Path]::GetFullPath($ConfigPath)
} else {
	[IO.Path]::GetFullPath((Join-Path $toolRoot $ConfigPath))
}
if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) { throw "Configuration file was not found: $configFile" }
Import-Module $modulePath -Force
. $configFile
Assert-DeployConfiguration $DeployConfig
$profileDirectory = Split-Path -Parent $configFile
$canonicalProfilesDirectory = if ([string]::IsNullOrWhiteSpace($ProfilesDirectory)) { $profileDirectory } else { [IO.Path]::GetFullPath($ProfilesDirectory) }
Assert-ProfileIsolation -Configuration $DeployConfig -ProfilePath $configFile -ProfilesDirectory $profileDirectory -CanonicalProfilesDirectory $canonicalProfilesDirectory

$localPaths = @(
	'CodeRepositoryPath', 'WorkRoot', 'LocalWpPath', 'LocalUploadsPath',
	'LocalBackupDirectory', 'MysqldumpPath', 'GitPath', 'LocalPhpPath',
	'LocalWpCliPath', 'MysqlPath'
)
$checks = foreach ($name in $localPaths) {
	if (-not $DeployConfig.Contains($name)) { continue }
	$value = [string] $DeployConfig[$name]
	[pscustomobject] @{
		Check = $name
		Absolute = [IO.Path]::IsPathRooted($value)
		Exists = Test-Path -LiteralPath $value
		Value = $value
	}
}

Write-Host "WordPress site onboarding preflight: $($DeployConfig.SiteId)" -ForegroundColor Cyan
Write-Host "Profile: $configFile"
Write-Host "Environment: $($DeployConfig.Environment) | Remote: $($DeployConfig.RemoteUrl)"
Write-Host "Local URL: $($DeployConfig.LocalUrl) | Local DB: $($DeployConfig.LocalDbName)"
Write-Host ""
$checks | Format-Table Check, Absolute, Exists, Value -AutoSize
$badPaths = @($checks | Where-Object { -not $_.Absolute })
$missing = @($checks | Where-Object { -not $_.Exists })
if ($badPaths.Count -gt 0) { Write-Warning "These local operational paths are not absolute: $($badPaths.Check -join ', ')" }
if ($missing.Count -gt 0) { Write-Warning "These paths are not created yet: $($missing.Check -join ', ')" }
if ($badPaths.Count -eq 0 -and $missing.Count -eq 0) {
	Write-Host 'ONBOARDING PREFLIGHT: READY (local paths are absolute and present).' -ForegroundColor Green
} else {
	Write-Host 'ONBOARDING PREFLIGHT: ACTION REQUIRED (no server or database changes were made).' -ForegroundColor Yellow
}
