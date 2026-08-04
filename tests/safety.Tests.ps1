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

	It 'rejects DB and full modes in production' {
		{ Assert-DeployModeAllowed production db } | Should Throw 'forbidden for production'
		{ Assert-DeployModeAllowed production full } | Should Throw 'forbidden for production'
	}

	It 'keeps code as the local and remote default' {
		$deploySource | Should Match "Mode = 'code'"
		$serverSource | Should Match 'DEPLOY_MODE="\$\{DEPLOY_MODE:-code\}"'
	}

	It 'checks server policy before updating the repository' {
		$policyCall = $serverSource.LastIndexOf("`nassert_server_policy`n")
		$repositoryCall = $serverSource.IndexOf("`n`t`tupdate_repository`n", $policyCall)
		$policyCall | Should BeGreaterThan -1
		$repositoryCall | Should BeGreaterThan $policyCall
	}

	It 'keeps the protected runner outside the Git checkout' {
		$moduleSource | Should Match 'RemoteRunnerPath'
		$deploySource | Should Not Match 'RemoteRepoPath\)/server-deploy\.sh'
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
