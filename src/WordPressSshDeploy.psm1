Set-StrictMode -Version 2.0

function ConvertTo-ShSingleQuotedString {
	[CmdletBinding()]
	param(
		[AllowEmptyString()]
		[Parameter(Mandatory = $true)]
		[string] $Value
	)

	$singleQuote = [string] [char] 39
	$escaped = $Value.Replace($singleQuote, $singleQuote + '"' + $singleQuote + '"' + $singleQuote)
	return $singleQuote + $escaped + $singleQuote
}

function Invoke-CheckedCommand {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $FilePath,
		[Parameter(Mandatory = $true)] [string[]] $Arguments,
		[Parameter(Mandatory = $true)] [string] $WorkingDirectory
	)

	Push-Location $WorkingDirectory
	try {
		& $FilePath @Arguments
		if ($LASTEXITCODE -ne 0) {
			throw "Command failed ($LASTEXITCODE): $FilePath"
		}
	} finally {
		Pop-Location
	}
}

function Invoke-CommandOutput {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $FilePath,
		[Parameter(Mandatory = $true)] [string[]] $Arguments,
		[Parameter(Mandatory = $true)] [string] $WorkingDirectory
	)

	Push-Location $WorkingDirectory
	try {
		$output = & $FilePath @Arguments 2>&1
		if ($LASTEXITCODE -ne 0) {
			throw "Command failed ($LASTEXITCODE): $FilePath"
		}
		return $output
	} finally {
		Pop-Location
	}
}

function Get-DirectoryContentSizeBytes {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
		throw "Directory not found: $Path"
	}
	$total = [long] 0
	Get-ChildItem -LiteralPath $Path -File -Recurse -Force | ForEach-Object { $total += $_.Length }
	return $total
}

function Assert-AvailableDiskSpace {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $Path,
		[Parameter(Mandatory = $true)] [long] $RequiredBytes,
		[string] $Label = 'Target disk'
	)

	$fullPath = [IO.Path]::GetFullPath($Path)
	$root = [IO.Path]::GetPathRoot($fullPath)
	try {
		$available = ([IO.DriveInfo] $root).AvailableFreeSpace
	} catch {
		throw "$Label free-space check failed."
	}
	if ($available -lt $RequiredBytes) {
		throw "$Label does not have enough free space. Required: $RequiredBytes bytes; available: $available bytes."
	}
}

function Assert-SqlDumpFile {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		throw 'SQL dump was not created.'
	}
	$file = Get-Item -LiteralPath $Path
	if ($file.Length -lt 64) {
		throw 'SQL dump is empty or unexpectedly small.'
	}
	$hasHeader = Select-String -LiteralPath $Path -Pattern '^-- (MySQL|MariaDB) dump' -Quiet
	$hasStructure = Select-String -LiteralPath $Path -Pattern '^(CREATE TABLE|INSERT INTO|-- Table structure for table)' -Quiet
	if (-not $hasHeader -or -not $hasStructure) {
		throw 'SQL dump does not contain the expected dump header and table structure.'
	}
}

function Assert-ZipArchiveFile {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		throw 'ZIP archive was not created.'
	}
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	$archive = $null
	try {
		$archive = [IO.Compression.ZipFile]::OpenRead($Path)
		if ($archive.Entries.Count -eq 0) {
			throw 'ZIP archive contains no entries.'
		}
		$buffer = New-Object byte[] 8192
		foreach ($entry in $archive.Entries) {
			if ($entry.FullName.EndsWith('/')) { continue }
			$stream = $entry.Open()
			try { while ($stream.Read($buffer, 0, $buffer.Length) -gt 0) {} }
			finally { $stream.Dispose() }
		}
	} catch {
		throw "ZIP archive integrity check failed: $($_.Exception.Message)"
	} finally {
		if ($archive) { $archive.Dispose() }
	}
}

function New-RemoteDeployCommand {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Configuration,
		[Parameter(Mandatory = $true)] [ValidateSet('preflight', 'full', 'code', 'db')] [string] $DeployMode,
		[string] $SqlFile = '',
		[string] $UploadsFile = ''
	)

	$assignments = @(
		@('LOCAL_URL', $Configuration.LocalUrl),
		@('REMOTE_URL', $Configuration.RemoteUrl),
		@('ENVIRONMENT', $Configuration.Environment),
		@('EXPECTED_REMOTE_DOMAIN', $Configuration.ExpectedRemoteDomain),
		@('WP_DIR', $Configuration.RemoteWpPath),
		@('REPO_DIR', $Configuration.RemoteRepoPath),
		@('BACKUP_DIR', $Configuration.RemoteBackups),
		@('KEEP_BACKUPS', $Configuration.KeepBackups),
		@('MIN_REMOTE_FREE_SPACE_MB', $Configuration.MinimumRemoteFreeSpaceMB),
		@('GIT_SSH_KEY', $Configuration.RemoteGitSshKey),
		@('PHP_BIN', $Configuration.RemotePhpPath),
		@('WP_CLI_BIN', $Configuration.RemoteWpCliPath),
		@('EXPECTED_WP_DIR', $Configuration.ExpectedRemoteWpPath),
		@('EXPECTED_DB_NAME', $Configuration.ExpectedRemoteDbName),
		@('SYNC_PATHS', ($Configuration.SyncPaths -join ',')),
		@('DEPLOY_MODE', $DeployMode),
		@('SQL_FILE', $SqlFile),
		@('UPLOADS_ZIP', $UploadsFile)
	)

	$parts = @()
	foreach ($assignment in $assignments) {
		$parts += "$($assignment[0])=$(ConvertTo-ShSingleQuotedString ([string] $assignment[1]))"
	}
	$parts += "sh $(ConvertTo-ShSingleQuotedString $Configuration.RemoteRunnerPath)"
	return $parts -join ' '
}

function Add-ValidationError {
	param(
		[System.Collections.Generic.List[string]] $Errors,
		[string] $Message
	)

	$Errors.Add($Message)
}

function Test-HttpUrl {
	param([string] $Value)

	$uri = $null
	if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $uri)) {
		return $false
	}

	return $uri.Scheme -in @('http', 'https') -and -not [string]::IsNullOrWhiteSpace($uri.Host)
}

function Test-RemotePath {
	param([string] $Value)

	if ([string]::IsNullOrWhiteSpace($Value) -or -not $Value.StartsWith('/')) {
		return $false
	}
	if ($Value -eq '/' -or $Value -match '[\r\n]' -or $Value -match '(^|/)\.\.?(/|$)') {
		return $false
	}

	return $true
}

function Test-SyncPath {
	param([string] $Value)

	if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq '.') {
		return $false
	}
	if ([IO.Path]::IsPathRooted($Value) -or $Value -match '[\\:\r\n]') {
		return $false
	}
	if ($Value -match '(^|/)\.\.?(/|$)' -or $Value.EndsWith('/')) {
		return $false
	}
	if ($Value -match '(?i)^(\.git|\.deploy)(/|$)' -or $Value -match '(?i)^wp-config\.php$') {
		return $false
	}

	return $true
}

function Get-DeployConfigurationErrors {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[object] $Configuration
	)

	$errors = New-Object 'System.Collections.Generic.List[string]'
	if ($Configuration -isnot [System.Collections.IDictionary]) {
		Add-ValidationError $errors 'DeployConfig must be a hashtable or another IDictionary.'
		return $errors.ToArray()
	}

	$requiredStringKeys = @(
		'Environment',
		'LocalWpPath',
		'LocalUrl',
		'LocalUploadsPath',
		'LocalDbName',
		'LocalDbUser',
		'LocalDbHost',
		'MysqldumpPath',
		'GitPath',
		'SshUser',
		'SshHost',
		'RemoteUrl',
		'RemoteWpPath',
		'RemoteRepoPath',
		'RemoteRunnerPath',
		'RemoteTmpPath',
		'RemoteBackups',
		'RemoteGitSshKey',
		'RemotePhpPath',
		'RemoteWpCliPath',
		'ExpectedRemoteDomain',
		'ExpectedRemoteWpPath',
		'ExpectedRemoteDbName'
	)
	$optionalKeys = @('LocalDbPassword', 'SshKeyPath')
	$otherRequiredKeys = @('SshPort', 'KeepBackups', 'MinimumLocalFreeSpaceMB', 'MinimumRemoteFreeSpaceMB', 'SyncPaths')
	$allowedKeys = $requiredStringKeys + $optionalKeys + $otherRequiredKeys

	foreach ($key in $Configuration.Keys) {
		if ([string] $key -notin $allowedKeys) {
			Add-ValidationError $errors "Unknown configuration key: $key"
		}
	}

	foreach ($key in $requiredStringKeys) {
		if (-not $Configuration.Contains($key)) {
			Add-ValidationError $errors "Missing configuration value: $key"
			continue
		}
		if ($Configuration[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($Configuration[$key])) {
			Add-ValidationError $errors "Configuration value must be a non-empty string: $key"
		}
	}

	foreach ($key in $otherRequiredKeys) {
		if (-not $Configuration.Contains($key)) {
			Add-ValidationError $errors "Missing configuration value: $key"
		}
	}
	foreach ($key in $optionalKeys) {
		if ($Configuration.Contains($key) -and $null -ne $Configuration[$key] -and $Configuration[$key] -isnot [string]) {
			Add-ValidationError $errors "Optional configuration value must be a string: $key"
		}
	}

	if ($errors.Count -gt 0) {
		return $errors.ToArray()
	}

	if ($Configuration.Environment -notin @('development', 'staging', 'production')) {
		Add-ValidationError $errors 'Environment must be development, staging, or production.'
	}

	foreach ($key in @('LocalUrl', 'RemoteUrl')) {
		if (-not (Test-HttpUrl $Configuration[$key])) {
			Add-ValidationError $errors "$key must be an absolute HTTP or HTTPS URL."
		}
	}

	if (Test-HttpUrl $Configuration.RemoteUrl) {
		$remoteUri = [Uri] $Configuration.RemoteUrl
		if ($remoteUri.Host -ine $Configuration.ExpectedRemoteDomain) {
			Add-ValidationError $errors 'RemoteUrl host does not match ExpectedRemoteDomain.'
		}
	}

	if ($Configuration.ExpectedRemoteDomain -notmatch '^[A-Za-z0-9.-]+$') {
		Add-ValidationError $errors 'ExpectedRemoteDomain must contain only a DNS host name.'
	}
	if ($Configuration.SshHost -notmatch '^[A-Za-z0-9.-]+$') {
		Add-ValidationError $errors 'SshHost must contain only a DNS host name or IPv4 address.'
	}
	if ($Configuration.SshUser -notmatch '^[A-Za-z0-9._-]+$') {
		Add-ValidationError $errors 'SshUser contains unsupported characters.'
	}
	if ($Configuration.LocalDbName -notmatch '^[A-Za-z0-9_]+$') {
		Add-ValidationError $errors 'LocalDbName contains unsupported characters.'
	}
	if ($Configuration.ExpectedRemoteDbName -notmatch '^[A-Za-z0-9_]+$') {
		Add-ValidationError $errors 'ExpectedRemoteDbName contains unsupported characters.'
	}

	foreach ($key in @('RemoteWpPath', 'RemoteRepoPath', 'RemoteRunnerPath', 'RemoteTmpPath', 'RemoteBackups', 'RemoteGitSshKey', 'RemotePhpPath', 'RemoteWpCliPath', 'ExpectedRemoteWpPath')) {
		if (-not (Test-RemotePath $Configuration[$key])) {
			Add-ValidationError $errors "$key must be a non-root absolute POSIX path without dot segments."
		}
	}
	foreach ($key in @('RemoteRunnerPath', 'RemoteGitSshKey', 'RemotePhpPath', 'RemoteWpCliPath')) {
		if ($Configuration[$key] -notmatch '^/[A-Za-z0-9._/-]+$') {
			Add-ValidationError $errors "$key contains characters that are unsafe in a remote command."
		}
	}
	if ($Configuration.RemoteWpPath -ne $Configuration.ExpectedRemoteWpPath) {
		Add-ValidationError $errors 'RemoteWpPath does not match ExpectedRemoteWpPath.'
	}

	foreach ($key in @('LocalWpPath', 'LocalUploadsPath', 'MysqldumpPath', 'GitPath')) {
		if (-not [IO.Path]::IsPathRooted($Configuration[$key])) {
			Add-ValidationError $errors "$key must be an absolute local path."
		}
	}
	if ($Configuration.SshKeyPath -and -not [IO.Path]::IsPathRooted($Configuration.SshKeyPath)) {
		Add-ValidationError $errors 'SshKeyPath must be an absolute local path when configured.'
	}

	$remotePaths = @(
		$Configuration.RemoteWpPath.TrimEnd('/'),
		$Configuration.RemoteRepoPath.TrimEnd('/'),
		$Configuration.RemoteTmpPath.TrimEnd('/'),
		$Configuration.RemoteBackups.TrimEnd('/')
	)
	if (@($remotePaths | Select-Object -Unique).Count -ne $remotePaths.Count) {
		Add-ValidationError $errors 'RemoteWpPath, RemoteRepoPath, RemoteTmpPath, and RemoteBackups must be different paths.'
	}
	$wpPrefix = $Configuration.RemoteWpPath.TrimEnd('/') + '/'
	foreach ($key in @('RemoteRepoPath', 'RemoteTmpPath', 'RemoteBackups')) {
		if ($Configuration[$key].StartsWith($wpPrefix, [StringComparison]::Ordinal)) {
			Add-ValidationError $errors "$key must not be inside RemoteWpPath."
		}
	}
	$repoPrefix = $Configuration.RemoteRepoPath.TrimEnd('/') + '/'
	if ($Configuration.RemoteRunnerPath.StartsWith($wpPrefix, [StringComparison]::Ordinal) -or
		$Configuration.RemoteRunnerPath.StartsWith($repoPrefix, [StringComparison]::Ordinal)) {
		Add-ValidationError $errors 'RemoteRunnerPath must be outside RemoteWpPath and RemoteRepoPath.'
	}

	if ($Configuration.SshPort -isnot [int] -or $Configuration.SshPort -lt 1 -or $Configuration.SshPort -gt 65535) {
		Add-ValidationError $errors 'SshPort must be an integer from 1 to 65535.'
	}
	if ($Configuration.KeepBackups -isnot [int] -or $Configuration.KeepBackups -lt 1 -or $Configuration.KeepBackups -gt 1000) {
		Add-ValidationError $errors 'KeepBackups must be an integer from 1 to 1000.'
	}
	foreach ($key in @('MinimumLocalFreeSpaceMB', 'MinimumRemoteFreeSpaceMB')) {
		if ($Configuration[$key] -isnot [int] -or $Configuration[$key] -lt 1 -or $Configuration[$key] -gt 1048576) {
			Add-ValidationError $errors "$key must be an integer from 1 to 1048576."
		}
	}

	if ($Configuration.SyncPaths -isnot [Array]) {
		Add-ValidationError $errors 'SyncPaths must be a non-empty array of repository-relative paths.'
	} else {
		$syncPaths = @($Configuration.SyncPaths)
		if ($syncPaths.Count -eq 0) {
			Add-ValidationError $errors 'SyncPaths must contain at least one path.'
		}
		$seen = @{}
		foreach ($path in $syncPaths) {
			if ($path -isnot [string] -or -not (Test-SyncPath $path)) {
				Add-ValidationError $errors "Unsafe SyncPaths value: $path"
				continue
			}
			$key = $path.ToLowerInvariant()
			if ($seen.ContainsKey($key)) {
				Add-ValidationError $errors "Duplicate SyncPaths value: $path"
			}
			$seen[$key] = $true
		}
	}

	return $errors.ToArray()
}

function Assert-DeployConfiguration {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[object] $Configuration
	)

	$errors = @(Get-DeployConfigurationErrors -Configuration $Configuration)
	if ($errors.Count -gt 0) {
		$message = "Invalid deploy.config.ps1:`n - " + ($errors -join "`n - ")
		throw $message
	}
}

function Assert-DeployModeAllowed {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[ValidateSet('development', 'staging', 'production')]
		[string] $Environment,

		[Parameter(Mandatory = $true)]
		[ValidateSet('full', 'code', 'db')]
		[string] $Mode
	)

	if ($Environment -eq 'production' -and $Mode -ne 'code') {
		throw "Mode '$Mode' is forbidden for production. Use code mode."
	}
}

Export-ModuleMember -Function Get-DeployConfigurationErrors, Assert-DeployConfiguration, Assert-DeployModeAllowed, ConvertTo-ShSingleQuotedString, New-RemoteDeployCommand, Invoke-CheckedCommand, Invoke-CommandOutput, Get-DirectoryContentSizeBytes, Assert-AvailableDiskSpace, Assert-SqlDumpFile, Assert-ZipArchiveFile
