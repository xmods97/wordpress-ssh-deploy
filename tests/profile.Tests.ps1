$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repoRoot 'src\WordPressSshDeploy.psm1') -Force

Describe 'AST-only deployment profile loading' {
	It 'loads the literal example without dot-sourcing' {
		$config = Import-DeployProfileData (Join-Path $repoRoot 'deploy.config.example.ps1')
		$config.GetType().Name | Should Be 'Hashtable'
		$config.AllowProductionFull.GetType().FullName | Should Be 'System.Boolean'
		$config.AllowProductionFull | Should Be $false
	}

	It 'loads the Bella profile with typed production gates when present' {
		$path = 'D:\wordpress-ssh-deploy\profiles\deploy.config.bella-maria-production.ps1'
		if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
		$config = Import-DeployProfileData $path
		$config.Environment | Should Be 'production'
		$config.AllowProductionFull.GetType().FullName | Should Be 'System.Boolean'
		$config.AllowProductionFull | Should Be $true
		$config.ExpectedDbTablePrefix | Should Be 'wpmq_'
		$config.ExpectedDbTableCount | Should Be 19
	}

	It 'rejects commands and extra statements without executing them' {
		$temp = Join-Path ([IO.Path]::GetTempPath()) ('deploy-profile-' + [guid]::NewGuid().ToString('N') + '.ps1')
		$marker = Join-Path ([IO.Path]::GetTempPath()) ('deploy-profile-marker-' + [guid]::NewGuid().ToString('N'))
		$content = @"
`$DeployConfig = @{ Environment = 'staging' }
New-Item -ItemType File -Path '$marker' -Force | Out-Null
"@
		[IO.File]::WriteAllText($temp, $content, (New-Object Text.UTF8Encoding($false)))
		try {
			$thrown = $false
			try { Import-DeployProfileData $temp | Out-Null } catch { $thrown = $true }
			$thrown | Should Be $true
			(Test-Path -LiteralPath $marker) | Should Be $false
		} finally {
			Remove-Item -LiteralPath $temp, $marker -Force -ErrorAction SilentlyContinue
		}
	}

	It 'rejects executable expressions inside a literal hashtable' {
		$temp = Join-Path ([IO.Path]::GetTempPath()) ('deploy-profile-' + [guid]::NewGuid().ToString('N') + '.ps1')
		$content = "`$DeployConfig = @{ Environment = (Get-Date) }"
		[IO.File]::WriteAllText($temp, $content, (New-Object Text.UTF8Encoding($false)))
		try {
			$thrown = $false
			try { Import-DeployProfileData $temp | Out-Null } catch { $thrown = $true }
			$thrown | Should Be $true
		}
		finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
	}

	It 'rejects non-empty param and begin blocks' {
		foreach ($content in @(
			"param(`$x)`r`n`$DeployConfig = @{ Environment = 'staging' }",
			"begin { Write-Output 'unsafe' }`r`n`$DeployConfig = @{ Environment = 'staging' }"
		)) {
			$temp = Join-Path ([IO.Path]::GetTempPath()) ('deploy-profile-' + [guid]::NewGuid().ToString('N') + '.ps1')
			[IO.File]::WriteAllText($temp, $content, (New-Object Text.UTF8Encoding($false)))
			try {
				$thrown = $false
				try { Import-DeployProfileData $temp | Out-Null } catch { $thrown = $true }
				$thrown | Should Be $true
			} finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
		}
	}
}
