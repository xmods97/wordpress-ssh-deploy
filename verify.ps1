[CmdletBinding()]
param(
    [string] $ConfigPath = '',
    [switch] $Remote,
    [switch] $Local
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path $toolRoot 'src\WordPressSshDeploy.psm1'
$configFile = if ([string]::IsNullOrWhiteSpace($ConfigPath)) { Join-Path $toolRoot 'deploy.config.ps1' } elseif ([IO.Path]::IsPathRooted($ConfigPath)) { [IO.Path]::GetFullPath($ConfigPath) } else { [IO.Path]::GetFullPath((Join-Path $toolRoot $ConfigPath)) }
Import-Module $modulePath -Force
if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) { throw "Configuration file was not found: $configFile" }
. $configFile
Assert-DeployConfiguration $DeployConfig
if (-not $Remote -and -not $Local) { $Remote = $true; $Local = $true }
foreach ($target in @(@{ Name = 'local'; Url = [string] $DeployConfig.LocalUrl; Enabled = [bool] $Local }, @{ Name = 'remote'; Url = [string] $DeployConfig.RemoteUrl; Enabled = [bool] $Remote })) {
    if (-not $target.Enabled) { continue }
    try {
        $response = Invoke-WebRequest -Uri $target.Url -UseBasicParsing -MaximumRedirection 3 -TimeoutSec 20
        if ([int] $response.StatusCode -ne 200) { throw "HTTP $($response.StatusCode)" }
        Write-Host "OK  $($target.Name): $($target.Url) -> HTTP 200" -ForegroundColor Green
    } catch {
        throw "Verify failed for $($target.Name) $($target.Url): $($_.Exception.Message)"
    }
}
