$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$deployScript = Get-Content -LiteralPath (Join-Path $repoRoot 'deploy.ps1') -Raw
$serverScript = Get-Content -LiteralPath (Join-Path $repoRoot 'server-deploy.sh') -Raw

$requiredLocalPatterns = @(
	"Assert-DeployModeAllowed",
	"Mode = 'code'",
	'Automatic Git commit/push was removed',
	'finally \{',
	'MYSQL_PWD'
)
foreach ($pattern in $requiredLocalPatterns) {
	if ($deployScript -notmatch $pattern) {
		throw "Local safety marker is missing: $pattern"
	}
}

$requiredRemotePatterns = @(
	'server\.config\.sh',
	'SERVER_ENVIRONMENT',
	'SERVER_EXPECTED_WP_DIR',
	'SERVER_EXPECTED_DB_NAME',
	'Database and uploads deployment is forbidden for production',
	'Another deployment operation is already running',
	'Sync path must not contain symbolic links',
	'trap cleanup_exit'
)
foreach ($pattern in $requiredRemotePatterns) {
	if ($serverScript -notmatch $pattern) {
		throw "Remote safety marker is missing: $pattern"
	}
}

Write-Output 'Stage 3 safety markers: OK'
