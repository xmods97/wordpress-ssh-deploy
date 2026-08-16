[CmdletBinding()]
param(
    [string] $ConfigPath = '',
    [string] $ProfilesDirectory = ''
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$deploy = Join-Path $toolRoot 'deploy.ps1'
$siteGit = Join-Path $toolRoot 'site-git.ps1'
$verify = Join-Path $toolRoot 'verify.ps1'
$backupCleanup = Join-Path $toolRoot 'backup-cleanup.ps1'
$onboard = Join-Path $toolRoot 'onboard-site.ps1'
$modulePath = Join-Path $toolRoot 'src\WordPressSshDeploy.psm1'
if ([string]::IsNullOrWhiteSpace($ProfilesDirectory)) { $ProfilesDirectory = [Environment]::GetEnvironmentVariable('WORDPRESS_SSH_DEPLOY_PROFILES_DIRECTORY') }
if ([string]::IsNullOrWhiteSpace($ConfigPath) -and [string]::IsNullOrWhiteSpace($ProfilesDirectory)) {
	throw 'Pass -ProfilesDirectory or set WORDPRESS_SSH_DEPLOY_PROFILES_DIRECTORY before opening the profile menu.'
}

function Resolve-Profile {
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { return [IO.Path]::GetFullPath($ConfigPath) }
    $profiles = @(Get-ChildItem -LiteralPath $ProfilesDirectory -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.example\.ps1$' } | Sort-Object Name)
    if ($profiles.Count -eq 0) { throw "No site profile found in $ProfilesDirectory. Copy a private deploy.config.<site>.ps1 there first." }
    Write-Host "Profiles:"
    for ($i = 0; $i -lt $profiles.Count; $i++) { Write-Host "[$($i + 1)] $($profiles[$i].BaseName)" }
    $choice = [int](Read-Host 'Choose profile') - 1
    if ($choice -lt 0 -or $choice -ge $profiles.Count) { throw 'Invalid profile selection.' }
    return $profiles[$choice].FullName
}

$profilePath = Resolve-Profile
$canonicalProfilesDirectory = if ([string]::IsNullOrWhiteSpace($ProfilesDirectory)) { Split-Path -Parent $profilePath } else { [IO.Path]::GetFullPath($ProfilesDirectory) }
Import-Module $modulePath -Force
. $profilePath
Assert-DeployConfiguration $DeployConfig
Assert-ProfileIsolation -Configuration $DeployConfig -ProfilePath $profilePath -ProfilesDirectory (Split-Path -Parent $profilePath) -CanonicalProfilesDirectory $canonicalProfilesDirectory
while ($true) {
    Clear-Host
    Write-Host "WordPress SSH Deploy: $($DeployConfig.SiteId)" -ForegroundColor Cyan
    Write-Host "Environment: $($DeployConfig.Environment) | Server: $($DeployConfig.RemoteUrl) | Local DB: $($DeployConfig.LocalDbName)"
    Write-Host "Profile: $profilePath"
    Write-Host ''
    Write-Host '[1] Verify local + remote URLs'
    Write-Host '[2] Site Git status'
    Write-Host '[3] Site Git commit'
    Write-Host '[4] Site Git push'
    Write-Host '[5] Pull-full dry run'
    Write-Host '[6] Pull-full execute'
    Write-Host '[7] Apply pulled workspace'
    Write-Host '[8] SSH preflight'
    Write-Host '[9] Local backup cleanup preview'
    Write-Host '[10] Onboarding preflight (read-only)'
    Write-Host '[11] Revalidate selected profile and all D: profiles'
    Write-Host '[0] Exit'
    $choice = Read-Host 'Select action'
    switch ($choice) {
        '1' { try { & $verify -ConfigPath $profilePath -ProfilesDirectory $canonicalProfilesDirectory } catch { Write-Warning $_.Exception.Message } }
        '2' { try { & $siteGit -Action status -ConfigPath $profilePath -ProfilesDirectory $canonicalProfilesDirectory } catch { Write-Warning $_.Exception.Message } }
        '3' { $m = Read-Host 'Commit message'; if ((Read-Host "Type $($DeployConfig.SiteId):COMMIT to confirm") -eq "$($DeployConfig.SiteId):COMMIT") { try { & $siteGit -Action commit -ConfigPath $profilePath -ProfilesDirectory $canonicalProfilesDirectory -Message $m -ConfirmCommit } catch { Write-Warning $_.Exception.Message } } }
        '4' { if ((Read-Host "Type $($DeployConfig.SiteId):PUSH to confirm") -eq "$($DeployConfig.SiteId):PUSH") { try { & $siteGit -Action push -ConfigPath $profilePath -ProfilesDirectory $canonicalProfilesDirectory -ConfirmPush } catch { Write-Warning $_.Exception.Message } } }
        '5' { try { & $deploy -ConfigPath $profilePath -ProfilesDirectory $canonicalProfilesDirectory -Mode pull-full -DryRun } catch { Write-Warning $_.Exception.Message } }
        '6' { if ((Read-Host "Type $($DeployConfig.SiteId):PULL:$($DeployConfig.RemoteUrl) to confirm") -eq "$($DeployConfig.SiteId):PULL:$($DeployConfig.RemoteUrl)") { try { & $deploy -ConfigPath $profilePath -ProfilesDirectory $canonicalProfilesDirectory -Mode pull-full -Confirm } catch { Write-Warning $_.Exception.Message } } }
        '7' { $workspace = Read-Host 'Paste verified pull workspace'; if ((Read-Host "Type $($DeployConfig.SiteId):APPLY:$($DeployConfig.LocalDbName) to confirm") -eq "$($DeployConfig.SiteId):APPLY:$($DeployConfig.LocalDbName)") { try { & $deploy -ConfigPath $profilePath -ProfilesDirectory $canonicalProfilesDirectory -Mode apply-pull -PullWorkspace $workspace -Confirm } catch { Write-Warning $_.Exception.Message } } }
        '8' { try { & $deploy -ConfigPath $profilePath -ProfilesDirectory $canonicalProfilesDirectory -PreflightOnly } catch { Write-Warning $_.Exception.Message } }
        '9' { try { & $backupCleanup -ConfigPath $profilePath -ProfilesDirectory $canonicalProfilesDirectory; if ((Read-Host "Type $($DeployConfig.SiteId):CLEAN to delete the listed entries, or press Enter") -eq "$($DeployConfig.SiteId):CLEAN") { & $backupCleanup -ConfigPath $profilePath -ProfilesDirectory $canonicalProfilesDirectory -ConfirmDelete } } catch { Write-Warning $_.Exception.Message } }
        '10' { try { & $onboard -ConfigPath $profilePath -ProfilesDirectory $ProfilesDirectory } catch { Write-Warning $_.Exception.Message } }
        '11' { try { Assert-DeployConfiguration $DeployConfig; Assert-ProfileIsolation -Configuration $DeployConfig -ProfilePath $profilePath -ProfilesDirectory (Split-Path -Parent $profilePath) -CanonicalProfilesDirectory $canonicalProfilesDirectory; Write-Host "OK Profile isolation: $($DeployConfig.SiteId)" -ForegroundColor Green } catch { Write-Warning $_.Exception.Message } }
        '0' { return }
        default { Write-Warning 'Unknown action.' }
    }
    if ($choice -ne '0') { Read-Host 'Press Enter to continue' | Out-Null }
}
