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

function Assert-SqlDumpTablePrefix {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $Path,
		[Parameter(Mandatory = $true)] [string] $ExpectedPrefix
	)

	if ($ExpectedPrefix -notmatch '^[A-Za-z0-9_]+$') {
		throw 'Expected SQL table prefix contains unsupported characters.'
	}
	$reader = $null
	$found = $false
	try {
		$reader = [IO.File]::OpenText($Path)
		while (($line = $reader.ReadLine()) -ne $null) {
			if ($line -notmatch '^CREATE TABLE(?: IF NOT EXISTS)? `([^`]+)`') { continue }
			$found = $true
			$tableName = $Matches[1]
			if (-not $tableName.StartsWith($ExpectedPrefix, [StringComparison]::Ordinal)) {
				throw "SQL dump table prefix mismatch: expected '$ExpectedPrefix', found '$tableName'."
			}
		}
	} finally {
		if ($reader) { $reader.Dispose() }
	}
	if (-not $found) {
		throw 'SQL dump contains no CREATE TABLE statements for table-prefix validation.'
	}
}

function Get-SqlByteSafeEncoding {
	# ISO-8859-1 maps bytes 0x00-0xFF to the identical code points and back, so a
	# GetString/GetBytes round-trip is lossless for arbitrary binary content. UTF-8
	# decoding would silently replace invalid sequences with U+FFFD and corrupt the dump.
	return [Text.Encoding]::GetEncoding(28591)
}

function Convert-SqlIdentifierPrefix {
	# Rewrites `<SourcePrefix> to `<TargetPrefix> in place, in a single forward pass over
	# the whole dump. Scanning from the start rather than from the enclosing line keeps
	# string, line-comment, and block-comment state correct across line boundaries, so a
	# /* ... */ comment opened on an earlier line still suppresses the rewrite.
	# Both prefixes are the same ASCII length, so no offset ever shifts.
	# Returns the number of identifiers rewritten.
	param(
		[Parameter(Mandatory = $true)] [char[]] $Characters,
		[Parameter(Mandatory = $true)] [string] $SourcePrefix,
		[Parameter(Mandatory = $true)] [string] $TargetPrefix
	)

	$length = $Characters.Length
	$prefixLength = $SourcePrefix.Length
	$replacements = 0
	$index = 0
	$inString = $false
	$inBlockComment = $false
	while ($index -lt $length) {
		$character = $Characters[$index]
		if ($inString) {
			# A backslash escapes the next byte, including a quote or another backslash.
			if ($character -eq '\') { $index += 2; continue }
			if ($character -eq "'") { $inString = $false }
			$index++
			continue
		}
		if ($inBlockComment) {
			if ($character -eq '*' -and ($index + 1) -lt $length -and $Characters[$index + 1] -eq '/') {
				$inBlockComment = $false
				$index += 2
				continue
			}
			$index++
			continue
		}
		if ($character -eq "'") { $inString = $true; $index++; continue }
		if ($character -eq '#' -or ($character -eq '-' -and ($index + 1) -lt $length -and $Characters[$index + 1] -eq '-')) {
			# Line comment: skip to the newline, which the next iteration consumes.
			while ($index -lt $length -and $Characters[$index] -ne "`n") { $index++ }
			continue
		}
		if ($character -eq '/' -and ($index + 1) -lt $length -and $Characters[$index + 1] -eq '*') {
			# /*! ... */ is an executable MySQL conditional comment, not a comment.
			if (($index + 2) -lt $length -and $Characters[$index + 2] -eq '!') { $index += 3; continue }
			$inBlockComment = $true
			$index += 2
			continue
		}
		if ($character -eq '`' -and ($index + $prefixLength) -lt $length) {
			$matched = $true
			for ($position = 0; $position -lt $prefixLength; $position++) {
				if ($Characters[$index + 1 + $position] -cne $SourcePrefix[$position]) { $matched = $false; break }
			}
			if ($matched) {
				for ($position = 0; $position -lt $prefixLength; $position++) {
					$Characters[$index + 1 + $position] = $TargetPrefix[$position]
				}
				$replacements++
				$index += $prefixLength + 1
				continue
			}
		}
		$index++
	}

	return $replacements
}

function Normalize-SqlDumpTablePrefix {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $Path,
		[Parameter(Mandatory = $true)] [string] $ExpectedPrefix,
		[Parameter(Mandatory = $true)] [int] $ExpectedTableCount
	)

	if ($ExpectedPrefix -notmatch '^[A-Za-z0-9_]+$') {
		throw 'Expected SQL table prefix contains unsupported characters.'
	}
	if ($ExpectedTableCount -lt 1) {
		throw 'Expected SQL table count must be positive.'
	}

	$encoding = Get-SqlByteSafeEncoding
	$contents = $encoding.GetString([IO.File]::ReadAllBytes($Path))
	$sourcePrefix = $ExpectedPrefix.ToLowerInvariant()
	$createMatches = [regex]::Matches($contents, '(?m)^CREATE TABLE(?: IF NOT EXISTS)? `([^`]+)`')
	if ($createMatches.Count -ne $ExpectedTableCount) {
		throw "SQL dump table count mismatch: expected $ExpectedTableCount, found $($createMatches.Count)."
	}

	$tableNames = @($createMatches | ForEach-Object { $_.Groups[1].Value })
	$targetCount = @($tableNames | Where-Object { $_.StartsWith($ExpectedPrefix, [StringComparison]::Ordinal) }).Count
	$sourceCount = @($tableNames | Where-Object { $_.StartsWith($sourcePrefix, [StringComparison]::Ordinal) }).Count
	if ($targetCount -eq $ExpectedTableCount) {
		Assert-SqlDumpTablePrefix $Path $ExpectedPrefix
		return
	}
	if ([string]::Equals($sourcePrefix, $ExpectedPrefix, [StringComparison]::Ordinal) -or $sourceCount -ne $ExpectedTableCount) {
		throw "SQL dump contains unexpected table identifiers for expected prefix '$ExpectedPrefix'."
	}

	# Replace in place: the rewrite is a same-length ASCII case change applied only to
	# identifier positions, so every other byte of the dump is preserved exactly.
	[char[]] $characters = $contents.ToCharArray()
	$null = Convert-SqlIdentifierPrefix $characters $sourcePrefix $ExpectedPrefix

	[IO.File]::WriteAllBytes($Path, $encoding.GetBytes((New-Object string (, $characters))))
	Assert-SqlDumpTablePrefix $Path $ExpectedPrefix
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
		@('EXPECTED_DB_TABLE_PREFIX', $Configuration.ExpectedDbTablePrefix),
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
		'ExpectedRemoteDbName',
		'ExpectedDbTablePrefix'
	)
	$optionalKeys = @('LocalDbPassword', 'SshKeyPath')
	$otherRequiredKeys = @('SshPort', 'KeepBackups', 'ExpectedDbTableCount', 'MinimumLocalFreeSpaceMB', 'MinimumRemoteFreeSpaceMB', 'SyncPaths')
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
	if ($Configuration.ExpectedDbTablePrefix -notmatch '^[A-Za-z0-9_]+$') {
		Add-ValidationError $errors 'ExpectedDbTablePrefix contains unsupported characters.'
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
	if ($Configuration.ExpectedDbTableCount -isnot [int] -or $Configuration.ExpectedDbTableCount -lt 1) {
		Add-ValidationError $errors 'ExpectedDbTableCount must be an integer greater than or equal to 1.'
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

Export-ModuleMember -Function Get-DeployConfigurationErrors, Assert-DeployConfiguration, Assert-DeployModeAllowed, ConvertTo-ShSingleQuotedString, New-RemoteDeployCommand, Invoke-CheckedCommand, Invoke-CommandOutput, Get-DirectoryContentSizeBytes, Assert-AvailableDiskSpace, Assert-SqlDumpFile, Assert-SqlDumpTablePrefix, Normalize-SqlDumpTablePrefix, Assert-ZipArchiveFile
