$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repoRoot 'src\WordPressSshDeploy.psm1') -Force
$gitPath = (Get-Command git -ErrorAction Stop).Source
$gitRoot = Split-Path -Parent (Split-Path -Parent $gitPath)
$shCandidates = @(
	(Join-Path $gitRoot 'usr\bin\sh.exe'),
	(Join-Path $gitRoot 'bin\sh.exe'),
	'C:\Users\xmods\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\usr\bin\sh.exe',
	'D:\laragon\bin\git\bin\sh.exe'
)
$shPath = $shCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

Describe 'Remote POSIX safety' {
	It 'has a POSIX shell available for verification' {
		$shPath | Should Not BeNullOrEmpty
	}

	It 'passes shell syntax checks' {
		foreach ($file in @('server-deploy.sh', 'server.config.example.sh', 'tests/server-safety.smoke.sh', 'tests/database-rollback.smoke.sh', 'tests/fixtures/server.config.production.sh', 'tests/fixtures/server.config.staging.sh', 'tests/fixtures/fake-php.sh', 'tests/fixtures/fake-mysqldump.sh', 'tests/fixtures/fake-mysql.sh', 'tests/fixtures/fake-df.sh')) {
			& $shPath -n (Join-Path $repoRoot $file)
			$LASTEXITCODE | Should Be 0
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
