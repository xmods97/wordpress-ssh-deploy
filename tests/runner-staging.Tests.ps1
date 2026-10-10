$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$deployPath = Join-Path $repoRoot 'deploy.ps1'
$tokens = $null
$parseErrors = $null
$deployAst = [System.Management.Automation.Language.Parser]::ParseFile($deployPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$stageFunctions = @($deployAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Assert-BellaRunnerStageProfile', 'Get-BellaRunnerCandidateFileHash', 'Invoke-BellaRunnerCandidateStage', 'Invoke-CheckedCommandRetry') }, $true))
foreach ($functionAst in $stageFunctions) { Invoke-Expression $functionAst.Extent.Text }

$runnerHash = '22FE072BFEF6C9637FA7B23467B8AFF5E454A572A58EF387C2053108D5B3D467'
$installerHash = '898AD0410257435B3174E4A9FDAA9D74698B673B77C06EF0B388F2103DE5B98B'

Describe 'Bella runner candidate staging' {
	BeforeEach {
		$script:stageTestRoot = Join-Path $TestDrive ('candidate-' + [Guid]::NewGuid().ToString('N'))
		New-Item -ItemType Directory -Path $script:stageTestRoot -Force | Out-Null
		$script:runnerSource = Join-Path $script:stageTestRoot 'server-deploy.sh'
		$script:installerSource = Join-Path $script:stageTestRoot 'bella-runner-install.sh'
		[IO.File]::WriteAllText($script:runnerSource, 'runner fixture')
		[IO.File]::WriteAllText($script:installerSource, 'installer fixture')
		$script:stageRemoteFiles = @{}
		$script:badSourceHashName = ''
		$script:corruptReadback = $false

		Mock Get-FileHash {
			$name = [IO.Path]::GetFileName($LiteralPath)
			$hash = switch ($name) {
				'server-deploy.sh' { $runnerHash; break }
				'server-deploy.sh.new' { $runnerHash; break }
				'bella-runner-install.sh' { $installerHash; break }
				default { '' }
			}
			if ($name -eq $script:badSourceHashName) { $hash = ('0' * 64) }
			if ($script:corruptReadback -and $LiteralPath -match '\\bella-runner-stage-[0-9a-f]{32}\\') { $hash = ('0' * 64) }
			[pscustomobject]@{ Hash = $hash }
		}

		Mock Invoke-CheckedCommandRetry {
			if ($FilePath -cne 'scp') { throw "Unexpected transport: $FilePath" }
			$source = $Arguments[$Arguments.Count - 2]
			$destination = $Arguments[$Arguments.Count - 1]
			if ($destination -match '^[^:]+:(?<remotePath>/.*)$') {
				$script:stageRemoteFiles[$Matches.remotePath] = [IO.File]::ReadAllBytes($source)
				return
			}
			if ($source -match '^[^:]+:(?<remotePath>/.*)$') {
				if (-not $script:stageRemoteFiles.ContainsKey($Matches.remotePath)) { throw 'Remote source missing in fake transport.' }
				[IO.File]::WriteAllBytes($destination, $script:stageRemoteFiles[$Matches.remotePath])
				return
			}
			throw 'Fake SCP received an unexpected argument shape.'
		}
	}

	It 'stages only the two pinned files under unique names and verifies both read-backs' {
		$result = Invoke-BellaRunnerCandidateStage -RunnerCandidatePath $script:runnerSource -InstallerCandidatePath $script:installerSource -RemoteTmpPath '/root/.wordpress-ssh-deploy/bella-maria/tmp' -Target 'root@bella.example' -ScpArguments @('-O', '-P', '22') -WorkingDirectory $script:stageTestRoot

	$result.RunnerSha256 | Should Be $runnerHash
	$result.InstallerSha256 | Should Be $installerHash
	$result.RunnerRemotePath | Should Match '^/root/\.wordpress-ssh-deploy/bella-maria/tmp/bella-runner-stage-[0-9a-f]{32}-server-deploy\.sh\.new$'
	$result.InstallerRemotePath | Should Match '^/root/\.wordpress-ssh-deploy/bella-maria/tmp/bella-runner-stage-[0-9a-f]{32}-bella-runner-install\.sh$'
	$script:stageRemoteFiles.Count | Should Be 2
		Assert-MockCalled Invoke-CheckedCommandRetry -Times 4 -Exactly -Scope It
		Assert-MockCalled Get-FileHash -Times 4 -Exactly -Scope It
	$deploySource = Get-Content -LiteralPath $deployPath -Raw
	$deploySource | Should Match 'StageBellaRunnerCandidate cannot be combined with'
	$deploySource | Should Match 'Invoke-BellaRunnerCandidateStage.*\| Out-Null'
	$deploySource | Should Match 'RUNNER_REMOTE_PATH='
	$deploySource | Should Match 'INSTALLER_REMOTE_PATH='
		$deploySource.IndexOf('function Invoke-BellaRunnerCandidateStage') | Should BeLessThan $deploySource.IndexOf('Assert-BellaRunnerStageProfile -Configuration $DeployConfig')
	$deploySource | Should Not Match 'Invoke-CheckedCommand ''ssh''.*bella-runner-stage'
	$deploySource | Should Not Match 'rm -f.*runnerRemotePath'
	$deploySource | Should Match $runnerHash
	$deploySource | Should Match $installerHash
	$profile = @{
		Environment = 'production'
		SshUser = 'root'
		RemoteUrl = 'https://bella-maria.com/'
		ExpectedRemoteDomain = 'bella-maria.com'
		RemoteTmpPath = '/root/.wordpress-ssh-deploy/bella-maria/tmp'
	}
	{ Assert-BellaRunnerStageProfile -Configuration $profile } | Should Not Throw
	$profile.ExpectedRemoteDomain = 'other.example'
	{ Assert-BellaRunnerStageProfile -Configuration $profile } | Should Throw 'restricted to the Bella Maria Production root profile'
	$profile.ExpectedRemoteDomain = 'bella-maria.com'
	$profile.RemoteTmpPath = '/tmp'
	{ Assert-BellaRunnerStageProfile -Configuration $profile } | Should Throw 'restricted to the Bella Maria Production root profile'
	$profile.RemoteTmpPath = '/root/.wordpress-ssh-deploy/bella-maria/tmp'
	$profile.SshUser = 'deploy'
	{ Assert-BellaRunnerStageProfile -Configuration $profile } | Should Throw 'restricted to the Bella Maria Production root profile'
	$profile.SshUser = 'root'
	$profile.Environment = 'staging'
	{ Assert-BellaRunnerStageProfile -Configuration $profile } | Should Throw 'restricted to the Bella Maria Production root profile'
	}

	It 'rejects a wrong local hash before any transport' {
		$script:badSourceHashName = 'bella-runner-install.sh'
		{ Invoke-BellaRunnerCandidateStage -RunnerCandidatePath $script:runnerSource -InstallerCandidatePath $script:installerSource -RemoteTmpPath '/root/.wordpress-ssh-deploy/bella-maria/tmp' -Target 'root@bella.example' -ScpArguments @('-O', '-P', '22') -WorkingDirectory $script:stageTestRoot } | Should Throw 'Local candidate SHA-256 mismatch'
		Assert-MockCalled Invoke-CheckedCommandRetry -Times 0 -Scope It
		$script:stageRemoteFiles.Count | Should Be 0
	}

	It 'fails closed when read-back differs and leaves the unique remote files untouched' {
		$script:corruptReadback = $true
		{ Invoke-BellaRunnerCandidateStage -RunnerCandidatePath $script:runnerSource -InstallerCandidatePath $script:installerSource -RemoteTmpPath '/root/.wordpress-ssh-deploy/bella-maria/tmp' -Target 'root@bella.example' -ScpArguments @('-O', '-P', '22') -WorkingDirectory $script:stageTestRoot } | Should Throw 'Read-back SHA-256 mismatch'
		$script:stageRemoteFiles.Count | Should Be 2
		Assert-MockCalled Invoke-CheckedCommandRetry -Times 3 -Exactly -Scope It
	}
}
