$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repoRoot 'src\WordPressSshDeploy.psm1') -Force
	$gitPath = (Get-Command git -ErrorAction Stop).Source
	$gitRoot = Split-Path -Parent (Split-Path -Parent $gitPath)
	$shCandidates = @(
		'D:\laragon\bin\git\bin\sh.exe',
		(Join-Path $gitRoot 'usr\bin\sh.exe'),
		(Join-Path $gitRoot 'bin\sh.exe'),
		'C:\Users\xmods\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\usr\bin\sh.exe'
	)
$shPath = $shCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

Describe 'Remote POSIX safety' {
	It 'has a POSIX shell available for verification' {
		$shPath | Should Not BeNullOrEmpty
	}

	It 'passes shell syntax checks' {
		foreach ($file in @('server-deploy.sh', 'server.config.example.sh', 'root-ssh-wrapper.sh', 'root-ssh-wrapper.config.example.sh', 'tools/bella-root-wrapper-install.sh', 'tools/bella-runner-install.sh', 'tools/bella-git-policy-install.sh', 'tests/server-safety.smoke.sh', 'tests/root-ssh-wrapper.smoke.sh', 'tests/database-rollback.smoke.sh', 'tests/url-rewrite-rollback.smoke.sh', 'tests/fixtures/server.config.production.sh', 'tests/fixtures/server.config.staging.sh', 'tests/fixtures/fake-php.sh', 'tests/fixtures/fake-id.sh', 'tests/fixtures/fake-mysqldump.sh', 'tests/fixtures/fake-mysql.sh', 'tests/fixtures/fake-df.sh')) {
			& $shPath -n (Join-Path $repoRoot $file)
			$LASTEXITCODE | Should Be 0
		}
	}

	It 'uses private server Git source policy instead of a client-controlled branch' {
		$server = Get-Content -Raw (Join-Path $repoRoot 'server-deploy.sh')
		$server | Should Match 'SERVER_GIT_REMOTE="\$\{SERVER_GIT_REMOTE:-origin\}"'
		$server | Should Match 'SERVER_GIT_BRANCH="\$\{SERVER_GIT_BRANCH:-main\}"'
		$server | Should Match 'SERVER_GIT_SSH_PORT="\$\{SERVER_GIT_SSH_PORT:-22\}"'
		$server | Should Match 'GIT_SSH="\$GIT_SSH_WRAPPER" git fetch "\$SERVER_GIT_REMOTE" "\$SERVER_GIT_BRANCH"'
		$server | Should Match 'git checkout -b "\$SERVER_GIT_BRANCH" FETCH_HEAD'
		$server | Should Match 'git pull --ff-only "\$SERVER_GIT_REMOTE" "\$SERVER_GIT_BRANCH"'
		$server | Should Not Match 'git pull --ff-only origin main'
		$server | Should Not Match 'GIT_SSH_COMMAND='
		$server | Should Match 'ssh -p ''\$SERVER_GIT_SSH_PORT'' -i ''\$SERVER_GIT_SSH_KEY'' -o IdentitiesOnly=yes'
		$server | Should Match 'Server Git SSH port is outside the allowed range'
	}

	It 'uses the local MySQL socket when WordPress config selects localhost' {
		$server = Get-Content -Raw (Join-Path $repoRoot 'server-deploy.sh')
		$server | Should Match 'mysqldump --defaults-file="\$MYSQL_DEFAULTS_FILE"'
		$server | Should Match 'mysql --defaults-file="\$MYSQL_DEFAULTS_FILE"'
		$server | Should Match 'protocol=socket'
		$server | Should Not Match '--defaults-extra-file'
		$server | Should Not Match 'MYSQL_PWD'
	}

	It 'pins the Bella Git policy installer to the release branch and GitHub SSH port' {
		$installer = Get-Content -Raw (Join-Path $repoRoot 'tools/bella-git-policy-install.sh')
		$expectedPort = '443'
		$installer | Should Match "EXPECTED_REMOTE='origin'"
		$installer | Should Match "EXPECTED_BRANCH='codex/bella-maria-v2026-08-23-02'"
		$installer | Should Match "EXPECTED_SSH_PORT='$expectedPort'"
		$installer | Should Match 'grep -Fqx "SERVER_GIT_SSH_PORT='
		$installer | Should Match "EXPECTED_SYNC_PATHS='wp-content/themes/bella-maria-child'"
		$installer | Should Match 'grep -Fqx "SERVER_SYNC_PATHS='
	}

	It 'parses operational PowerShell tools under the current Windows PowerShell' {
		foreach ($file in @('tools/build-bella-maria-raw-release.ps1')) {
			$tokens = $null
			$errors = $null
			[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $file), [ref]$tokens, [ref]$errors) | Out-Null
			$errors.Count | Should Be 0
		}
	}

	It 'keeps the root wrapper protocol Bella-gated and fail-closed' {
		Push-Location $repoRoot
		try {
			$output = & $shPath -c 'PATH=/usr/bin:/bin; export PATH; sh ./tests/root-ssh-wrapper.smoke.sh' 2>&1
			$LASTEXITCODE | Should Be 0
			$output -join "`n" | Should Match 'Root SSH wrapper smoke: OK'
		} finally {
			Pop-Location
		}
	}

	It 'round-trips a hostile value through the real shell' {
		$value = "a'b; echo unsafe; " + '$(' + 'whoami' + ')'
		$command = "printf '%s' " + (ConvertTo-ShSingleQuotedString $value)
		$tempScript = [IO.Path]::GetTempFileName()
		try {
			[IO.File]::WriteAllText($tempScript, $command, (New-Object Text.UTF8Encoding($false)))
			$output = & $shPath $tempScript
			$LASTEXITCODE | Should Be 0
			[string] $output | Should Be $value
		} finally {
			Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
		}
	}

	It 'rejects production DB mode and cleans a failed-operation lock' {
		Push-Location $repoRoot
		try {
			$output = & $shPath -c 'PATH=/usr/bin:/bin; export PATH; sh ./tests/server-safety.smoke.sh' 2>&1
			$LASTEXITCODE | Should Be 0
			$output -join "`n" | Should Match 'Remote production policy: OK'
			$output -join "`n" | Should Match 'Remote lock cleanup: OK'
			$output -join "`n" | Should Match 'Remote preflight purity: OK'
			$output -join "`n" | Should Match 'Remote WP-CLI root guard: OK'
		} finally {
			Pop-Location
		}
	}

	It 'preserves a forced smoke-test failure exit status' {
		Push-Location $repoRoot
		try {
			$previousErrorActionPreference = $ErrorActionPreference
			try {
				$ErrorActionPreference = 'Continue'
				$output = & $shPath -c 'PATH=/usr/bin:/bin; export PATH; FIXTURE_FORCE_SMOKE_FAILURE=1; export FIXTURE_FORCE_SMOKE_FAILURE; sh ./tests/server-safety.smoke.sh' 2>&1
				$exitCode = $LASTEXITCODE
			} finally {
				$ErrorActionPreference = $previousErrorActionPreference
			}
			$exitCode | Should Be 1
			([string]($output -join "`n")) | Should Match 'Forced smoke failure'
		} finally {
			Pop-Location
		}
	}

	It 'restores the backup after a failed database import' {
		Push-Location $repoRoot
		try {
			$output = & $shPath -c 'PATH=/usr/bin:/bin; export PATH; sh ./tests/database-rollback.smoke.sh' 2>&1
			$LASTEXITCODE | Should Be 0
			$output -join "`n" | Should Match 'Database rollback after failed import: OK'
		} finally {
			Pop-Location
		}
	}

	It 'restores the backup after URL rewrite or verification failure' {
		Push-Location $repoRoot
		try {
			$output = & $shPath -c 'PATH=/usr/bin:/bin; export PATH; sh ./tests/url-rewrite-rollback.smoke.sh' 2>&1
			$LASTEXITCODE | Should Be 0
			$output -join "`n" | Should Match 'URL rewrite rollback: OK'
		} finally {
			Pop-Location
		}
	}

	It 'automatically restores the database after a later full-mode mutation failure' {
		Push-Location $repoRoot
		try {
			$output = & $shPath -c 'PATH=/usr/bin:/bin; export PATH; FIXTURE_FAIL_AFTER_IMPORT=1; export FIXTURE_FAIL_AFTER_IMPORT; sh ./tests/database-rollback.smoke.sh' 2>&1
			$LASTEXITCODE | Should Be 0
			$output -join "`n" | Should Match 'Post-import database rollback: OK'
		} finally {
			Pop-Location
		}
	}

	It 'applies ordinary backup retention after a failed import rollback' {
		Push-Location $repoRoot
		try {
			$output = & $shPath -c 'PATH=/usr/bin:/bin; export PATH; FIXTURE_EXPECT_ROLLBACK_RETENTION=1; export FIXTURE_EXPECT_ROLLBACK_RETENTION; sh ./tests/database-rollback.smoke.sh' 2>&1
			$LASTEXITCODE | Should Be 0
			$output -join "`n" | Should Match 'Rollback retention: OK'
		} finally {
			Pop-Location
		}
	}

	It 'preserves a named manual-recovery backup when import and rollback both fail' {
		Push-Location $repoRoot
		try {
			$output = & $shPath -c 'PATH=/usr/bin:/bin; export PATH; FIXTURE_FAIL_ALL_IMPORTS=1; export FIXTURE_FAIL_ALL_IMPORTS; sh ./tests/database-rollback.smoke.sh' 2>&1
			$LASTEXITCODE | Should Be 0
			$output -join "`n" | Should Match 'Database double-failure manual recovery: OK'
		} finally {
			Pop-Location
		}
	}

	It 'prints root-compatible manual recovery commands' {
		Push-Location $repoRoot
		try {
			$output = & $shPath -c 'PATH=/usr/bin:/bin; export PATH; FIXTURE_FAIL_ALL_IMPORTS=1; export FIXTURE_FAIL_ALL_IMPORTS; FIXTURE_EFFECTIVE_UID=0; export FIXTURE_EFFECTIVE_UID; sh ./tests/database-rollback.smoke.sh' 2>&1
			$LASTEXITCODE | Should Be 0
			$output -join "`n" | Should Match 'Database double-failure manual recovery: OK'
		} finally {
			Pop-Location
		}
	}

	It 'prints a root-compatible fallback recovery command when the marker is unavailable' {
		Push-Location $repoRoot
		try {
			$output = & $shPath -c 'PATH=/usr/bin:/bin; export PATH; FIXTURE_FAIL_ALL_IMPORTS=1; export FIXTURE_FAIL_ALL_IMPORTS; FIXTURE_CHMOD_FAIL_MARKER=1; export FIXTURE_CHMOD_FAIL_MARKER; FIXTURE_EFFECTIVE_UID=0; export FIXTURE_EFFECTIVE_UID; sh ./tests/database-rollback.smoke.sh' 2>&1
			$LASTEXITCODE | Should Be 0
			$output -join "`n" | Should Match 'Degraded marker fallback: OK'
		} finally {
			Pop-Location
		}
	}

	It 'keeps recovery output when chmod fails' {
		Push-Location $repoRoot
		try {
			$output = & $shPath -c 'PATH=/usr/bin:/bin; export PATH; FIXTURE_FAIL_ALL_IMPORTS=1; export FIXTURE_FAIL_ALL_IMPORTS; FIXTURE_CHMOD_FAIL=1; export FIXTURE_CHMOD_FAIL; sh ./tests/database-rollback.smoke.sh' 2>&1
			$LASTEXITCODE | Should Be 0
			$output -join "`n" | Should Match 'Degraded chmod recovery output: OK'
		} finally {
			Pop-Location
		}
	}

	It 'prints a fallback recovery command when marker permissions fail' {
		Push-Location $repoRoot
		try {
			$output = & $shPath -c 'PATH=/usr/bin:/bin; export PATH; FIXTURE_FAIL_ALL_IMPORTS=1; export FIXTURE_FAIL_ALL_IMPORTS; FIXTURE_CHMOD_FAIL_MARKER=1; export FIXTURE_CHMOD_FAIL_MARKER; sh ./tests/database-rollback.smoke.sh' 2>&1
			$LASTEXITCODE | Should Be 0
			$output -join "`n" | Should Match 'Degraded marker fallback: OK'
		} finally {
			Pop-Location
		}
	}

	It 'reports an explicit recovery state when the backup disappears' {
		Push-Location $repoRoot
		try {
			$output = & $shPath -c 'PATH=/usr/bin:/bin; export PATH; FIXTURE_FAIL_ALL_IMPORTS=1; export FIXTURE_FAIL_ALL_IMPORTS; FIXTURE_DELETE_BACKUP_ON_FIRST_IMPORT=1; export FIXTURE_DELETE_BACKUP_ON_FIRST_IMPORT; sh ./tests/database-rollback.smoke.sh' 2>&1
			$LASTEXITCODE | Should Be 0
			$output -join "`n" | Should Match 'Degraded missing-backup output: OK'
		} finally {
			Pop-Location
		}
	}

	It 'does not print a recovery command for a corrupted backup' {
		Push-Location $repoRoot
		try {
			$output = & $shPath -c 'PATH=/usr/bin:/bin; export PATH; FIXTURE_FAIL_ALL_IMPORTS=1; export FIXTURE_FAIL_ALL_IMPORTS; FIXTURE_CORRUPT_BACKUP_ON_FIRST_IMPORT=1; export FIXTURE_CORRUPT_BACKUP_ON_FIRST_IMPORT; sh ./tests/database-rollback.smoke.sh' 2>&1
			$LASTEXITCODE | Should Be 0
			$output -join "`n" | Should Match 'Corrupted backup recovery output: OK'
		} finally {
			Pop-Location
		}
	}

	It 'does not print a recovery command for a corrupted backup when protected directory creation fails' {
		Push-Location $repoRoot
		try {
			$output = & $shPath -c 'PATH=/usr/bin:/bin; export PATH; FIXTURE_FAIL_ALL_IMPORTS=1; export FIXTURE_FAIL_ALL_IMPORTS; FIXTURE_CORRUPT_BACKUP_ON_FIRST_IMPORT=1; export FIXTURE_CORRUPT_BACKUP_ON_FIRST_IMPORT; FIXTURE_CHMOD_FAIL_DIR=1; export FIXTURE_CHMOD_FAIL_DIR; sh ./tests/database-rollback.smoke.sh' 2>&1
			$LASTEXITCODE | Should Be 0
			$output -join "`n" | Should Match 'Corrupted degraded backup recovery output: OK'
		} finally {
			Pop-Location
		}
	}

	It 'keeps all shell files on LF line endings' {
		foreach ($file in Get-ChildItem -LiteralPath $repoRoot -Recurse -Filter '*.sh') {
			$bytes = [IO.File]::ReadAllBytes($file.FullName)
			$hasCrLf = $false
			for ($index = 0; $index -lt ($bytes.Length - 1); $index++) {
				if ($bytes[$index] -eq 13 -and $bytes[$index + 1] -eq 10) { $hasCrLf = $true; break }
			}
			$hasCrLf | Should Be $false
		}
	}
}
