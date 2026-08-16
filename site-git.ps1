[CmdletBinding()]
param(
    [ValidateSet('status', 'commit', 'push')]
    [string] $Action = 'status',
    [string] $ConfigPath = '',
    [string] $Message = '',
    [switch] $ConfirmCommit,
    [switch] $ConfirmPush,
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
$repo = [IO.Path]::GetFullPath([string] $DeployConfig.CodeRepositoryPath)
if (-not (Test-Path -LiteralPath $repo -PathType Container)) { throw "Site code repository was not found: $repo" }
$gitArgs = @('-C', $repo)
$remote = if ($DeployConfig.Contains('GitRemoteName')) { [string] $DeployConfig.GitRemoteName } else { 'origin' }
$branch = if ($DeployConfig.Contains('GitBranch')) { [string] $DeployConfig.GitBranch } else { 'main' }

function Invoke-SiteGit([string[]] $Arguments) {
    $output = @(& $DeployConfig.GitPath @($gitArgs + $Arguments))
    if ($LASTEXITCODE -ne 0) { throw "Git command failed: $($Arguments -join ' ')" }
    return $output
}

function Assert-SelectedBranch {
    $current = ([string] (Invoke-SiteGit @('branch', '--show-current'))).Trim()
    if ($current -ne $branch) { throw "Selected profile requires Git branch '$branch'; current branch is '$current'." }
}

function Assert-CleanSiteGit {
    $status = @(Invoke-SiteGit @('status', '--porcelain'))
    if ($status.Count -gt 0) { throw 'Site Git repository has uncommitted changes.' }
}

switch ($Action) {
    'status' {
        Assert-SelectedBranch
        Invoke-SiteGit @('status', '--short', '--branch')
    }
    'commit' {
        if (-not $ConfirmCommit) { throw 'Commit requires -ConfirmCommit.' }
        if ([string]::IsNullOrWhiteSpace($Message)) { throw 'Commit requires -Message.' }
        Assert-SelectedBranch
        $before = @(Invoke-SiteGit @('status', '--porcelain'))
        if ($before.Count -eq 0) { throw 'There are no site-code changes to commit.' }
        Invoke-SiteGit @('add', '-A') | Out-Null
        Invoke-SiteGit @('commit', '-m', $Message) | Out-Null
    }
    'push' {
        if (-not $ConfirmPush) { throw 'Push requires -ConfirmPush.' }
        Assert-SelectedBranch
        Assert-CleanSiteGit
        $upstream = ([string] (Invoke-SiteGit @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'))).Trim()
        if ($upstream -ne "$remote/$branch") { throw "Selected profile requires upstream '$remote/$branch'; current upstream is '$upstream'." }
        Invoke-SiteGit @('push', $remote, "HEAD:$branch") | Out-Null
    }
}
