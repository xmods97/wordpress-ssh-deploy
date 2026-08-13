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
$modulePath = Join-Path $toolRoot 'src\WordPressSshDeploy.psm1'
if ([string]::IsNullOrWhiteSpace($ProfilesDirectory)) { $ProfilesDirectory = Join-Path $env:USERPROFILE '.wordpress-ssh-deploy\profiles' }

function Resolve-Profile {
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { return [IO.Path]::GetFullPath($ConfigPath) }
    $default = Join-Path $toolRoot 'deploy.config.ps1'
    if (Test-Path -LiteralPath $default -PathType Leaf) { return $default }
    $profiles = @(Get-ChildItem -LiteralPath $ProfilesDirectory -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($profiles.Count -eq 0) { throw "No profile found. Create deploy.config.ps1 or put profiles in $ProfilesDirectory" }
    Write-Host "Profiles:"
    for ($i = 0; $i -lt $profiles.Count; $i++) { Write-Host "[$($i + 1)] $($profiles[$i].BaseName)" }
    $choice = [int](Read-Host 'Choose profile') - 1
    if ($choice -lt 0 -or $choice -ge $profiles.Count) { throw 'Invalid profile selection.' }
    return $profiles[$choice].FullName
}

$profilePath = Resolve-Profile
Import-Module $modulePath -Force
. $profilePath
Assert-DeployConfiguration $DeployConfig
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
    Write-Host '[0] Exit'
    $choice = Read-Host 'Select action'
    switch ($choice) {
        '1' { try { & $verify -ConfigPath $profilePath } catch { Write-Warning $_.Exception.Message } }
        '2' { try { & $siteGit -Action status -ConfigPath $profilePath } catch { Write-Warning $_.Exception.Message } }
        '3' { $m = Read-Host 'Commit message'; if ((Read-Host "Type $($DeployConfig.SiteId):COMMIT to confirm") -eq "$($DeployConfig.SiteId):COMMIT") { try { & $siteGit -Action commit -ConfigPath $profilePath -Message $m -ConfirmCommit } catch { Write-Warning $_.Exception.Message } } }
        '4' { if ((Read-Host "Type $($DeployConfig.SiteId):PUSH to confirm") -eq "$($DeployConfig.SiteId):PUSH") { try { & $siteGit -Action push -ConfigPath $profilePath -ConfirmPush } catch { Write-Warning $_.Exception.Message } } }
        '5' { try { & $deploy -ConfigPath $profilePath -Mode pull-full -DryRun } catch { Write-Warning $_.Exception.Message } }
        '6' { if ((Read-Host "Type $($DeployConfig.SiteId):PULL:$($DeployConfig.RemoteUrl) to confirm") -eq "$($DeployConfig.SiteId):PULL:$($DeployConfig.RemoteUrl)") { try { & $deploy -ConfigPath $profilePath -Mode pull-full -Confirm } catch { Write-Warning $_.Exception.Message } } }
        '7' { $workspace = Read-Host 'Paste verified pull workspace'; if ((Read-Host "Type $($DeployConfig.SiteId):APPLY:$($DeployConfig.LocalDbName) to confirm") -eq "$($DeployConfig.SiteId):APPLY:$($DeployConfig.LocalDbName)") { try { & $deploy -ConfigPath $profilePath -Mode apply-pull -PullWorkspace $workspace -Confirm } catch { Write-Warning $_.Exception.Message } } }
        '8' { try { & $deploy -ConfigPath $profilePath -PreflightOnly } catch { Write-Warning $_.Exception.Message } }
        '9' { try { & $backupCleanup -ConfigPath $profilePath; if ((Read-Host "Type $($DeployConfig.SiteId):CLEAN to delete the listed entries, or press Enter") -eq "$($DeployConfig.SiteId):CLEAN") { & $backupCleanup -ConfigPath $profilePath -ConfirmDelete } } catch { Write-Warning $_.Exception.Message } }
        '0' { return }
        default { Write-Warning 'Unknown action.' }
    }
    if ($choice -ne '0') { Read-Host 'Press Enter to continue' | Out-Null }
}
