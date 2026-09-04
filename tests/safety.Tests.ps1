$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repoRoot 'src\WordPressSshDeploy.psm1') -Force
$deploySource = Get-Content -LiteralPath (Join-Path $repoRoot 'deploy.ps1') -Raw
$serverSource = Get-Content -LiteralPath (Join-Path $repoRoot 'server-deploy.sh') -Raw
$moduleSource = Get-Content -LiteralPath (Join-Path $repoRoot 'src\WordPressSshDeploy.psm1') -Raw

Describe 'Production deployment policy' {
	It 'allows code in every environment' {
		foreach ($environment in @('development', 'staging', 'production')) {
			{ Assert-DeployModeAllowed $environment code } | Should Not Throw
		}
	}

	It 'rejects DB and deny-by-default full modes in production' {
		{ Assert-DeployModeAllowed production db } | Should Throw 'forbidden for production'
		{ Assert-DeployModeAllowed production db $true } | Should Throw 'forbidden for production'
		{ Assert-DeployModeAllowed production full } | Should Throw 'forbidden for production'
		{ Assert-DeployModeAllowed production full $true } | Should Not Throw
		{ Assert-DeployModeAllowed production full 'true' } | Should Throw 'AllowProductionFull must be a Boolean'
	}

	It 'uses explicit profile capabilities instead of a global production DB ban' {
		$all = @('preflight', 'code', 'db', 'code-db', 'uploads', 'plugins', 'full', 'components')
		foreach ($mode in @('db', 'code-db', 'uploads', 'plugins')) {
			{ Assert-DeployModeAllowed production $mode $false $all } | Should Not Throw
		}
		{ Assert-DeployModeAllowed production db $false @('preflight', 'code') } | Should Throw 'not enabled by this profile'
		{ Assert-DeployModeAllowed production full $false @('preflight', 'code', 'full') } | Should Throw 'forbidden for production'
		{ Assert-DeployModeAllowed production components $false @('preflight', 'components') } | Should Not Throw
	}

	It 'keeps component selection explicit across the client and runner' {
		$deploySource | Should Match "Mode = 'code'"
		$deploySource | Should Match '\$Components'
		$serverSource | Should Match 'DEPLOY_COMPONENTS="\$\{DEPLOY_COMPONENTS:-\}"'
		$serverSource | Should Match 'component_selected'
	}

	It 'keeps code as the local and remote default' {
		$deploySource | Should Match "Mode = 'code'"
		$serverSource | Should Match 'DEPLOY_MODE="\$\{DEPLOY_MODE:-code\}"'
	}

	It 'checks server policy before updating the repository' {
		$policyCall = $serverSource.LastIndexOf("`nassert_server_policy`n")
		$repositoryCall = $serverSource.IndexOf('update_repository', $policyCall)
		$policyCall | Should BeGreaterThan -1
		$repositoryCall | Should BeGreaterThan $policyCall
	}

	It 'keeps the protected runner outside the Git checkout' {
		$moduleSource | Should Match 'RemoteRunnerPath'
		$deploySource | Should Not Match 'RemoteRepoPath\)/server-deploy\.sh'
	}

	It 'uses resilient legacy SCP transport for long-lived transfers' {
		$deploySource | Should Match "'-O'"
		$deploySource | Should Match 'ServerAliveInterval=30'
		$deploySource | Should Match 'ServerAliveCountMax=10'
		$deploySource | Should Match 'ConnectTimeout=20'
		$deploySource | Should Match 'Invoke-CheckedCommandRetry.*scp'
	}
}

Describe 'Secrets and cleanup guards' {
	It 'does not pass a database password as a command-line option' {
		$deploySource | Should Not Match '--password='
		$deploySource | Should Match 'MYSQL_PWD'
	}

	It 'contains local finally cleanup and remote traps' {
		$deploySource | Should Match 'finally \{'
		$deploySource | Should Match 'Remote temporary file cleanup could not be confirmed'
		$deploySource | Should Match 'Local deployment artifacts retained at'
		$serverSource | Should Match 'trap cleanup_exit 0 1 2 15'
		$serverSource | Should Match 'cleanup_stale_temp_files'
	}

	It 'removes the PID file before releasing the lock directory' {
		$serverSource | Should Match 'rm -f "\$SERVER_LOCK_DIR/pid"'
		$serverSource | Should Match 'rmdir "\$SERVER_LOCK_DIR"'
	}

	It 'does not contain private key material' {
		$allSource = Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
		($allSource -join "`n") | Should Not Match 'BEGIN [A-Z ]*PRIVATE KEY'
	}
}
