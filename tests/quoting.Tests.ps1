$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repoRoot 'src\WordPressSshDeploy.psm1') -Force
. (Join-Path $repoRoot 'deploy.config.example.ps1')
$validConfiguration = $DeployConfig

Describe 'POSIX shell quoting' {
	It 'quotes empty, spaced, and Unicode values' {
		$unicode = ([char[]] @(0x0422, 0x0435, 0x0441, 0x0442)) -join ''
		(ConvertTo-ShSingleQuotedString '') | Should Be "''"
		(ConvertTo-ShSingleQuotedString 'two words') | Should Be "'two words'"
		(ConvertTo-ShSingleQuotedString $unicode) | Should Be ("'" + $unicode + "'")
	}

	It 'escapes a single quote without allowing shell interpolation' {
		$singleQuote = [string] [char] 39
		$expected = $singleQuote + 'a' + $singleQuote + '"' + $singleQuote + '"' + $singleQuote + 'b' + $singleQuote
		(ConvertTo-ShSingleQuotedString "a'b") | Should Be $expected
	}

	It 'forms a deterministic remote command with every safety value' {
		$command = New-RemoteDeployCommand $validConfiguration 'db' '/srv/tmp/example-deploy/a file.sql' '/srv/tmp/example-deploy/u.zip'
		$command | Should Match "ENVIRONMENT='staging'"
		$command | Should Match "EXPECTED_REMOTE_DOMAIN='staging\.example\.com'"
		$command | Should Match "EXPECTED_DB_TABLE_PREFIX='wp_'"
		$command | Should Match "DEPLOY_MODE='db'"
		$command | Should Match "SQL_FILE='/srv/tmp/example-deploy/a file\.sql'"
		$command | Should Match "sh '/usr/local/libexec/wordpress-ssh-deploy/example-site/server-deploy\.sh'$"
	}

	It 'does not expose a quoted value as a second command' {
		$command = New-RemoteDeployCommand $validConfiguration 'db' "x'; touch /tmp/unsafe; echo '" ''
		$command | Should Match 'SQL_FILE='
		$command | Should Not Match "SQL_FILE='x'; touch"
	}
}

Describe 'External command handling' {
	It 'reports a non-zero exit code without including command arguments' {
		$message = ''
		try {
			$fixture = Join-Path $repoRoot 'tests\fixtures\exit-code.ps1'
			Invoke-CheckedCommand 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fixture, '-Code', '7', '-Secret', 'top-secret') $repoRoot
			throw 'Expected command failure was not raised.'
		} catch {
			$message = $_.Exception.Message
		}
		$message | Should Match 'Command failed \(7\)'
		$message | Should Not Match 'top-secret'
	}

	It 'restores the working directory after failure' {
		$before = (Get-Location).Path
		try { Invoke-CheckedCommand 'powershell.exe' @('-NoProfile', '-Command', 'exit 3') $repoRoot } catch {}
		(Get-Location).Path | Should Be $before
	}

	It 'returns stdout from a successful command' {
		$output = Invoke-CommandOutput 'powershell.exe' @('-NoProfile', '-Command', "Write-Output 'ok'") $repoRoot
		[string] $output | Should Be 'ok'
	}
}
