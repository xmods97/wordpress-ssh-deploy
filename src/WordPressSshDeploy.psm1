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

function Test-DeployProfileLiteralAst {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[System.Management.Automation.Language.Ast] $Ast
	)

	$allowedTypes = @(
		'ArrayExpressionAst', 'ArrayLiteralAst', 'CommandExpressionAst',
		'ConstantExpressionAst', 'PipelineAst', 'StatementBlockAst',
		'StringConstantExpressionAst', 'VariableExpressionAst'
	)
	foreach ($node in @($Ast.FindAll({ param($candidate) $true }, $true))) {
		if ($node.GetType().Name -notin $allowedTypes) {
			return $false
		}
		if ($node -is [System.Management.Automation.Language.VariableExpressionAst] -and
			$node.VariablePath.UserPath -notin @('true', 'false', 'null')) {
			return $false
		}
	}
	return $true
}

function Test-DeployProfileLiteralValue {
	[CmdletBinding()]
	param(
		[AllowNull()]
		[object] $Value
	)

	if ($null -eq $Value) { return $true }
	if ($Value -is [string] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
		return $true
	}
	if ($Value -is [Array]) {
		foreach ($item in @($Value)) {
			if (-not (Test-DeployProfileLiteralValue -Value $item)) { return $false }
		}
		return $true
	}
	return $false
}

function Import-DeployProfileData {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string] $Path
	)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		throw "Deploy profile not found: $Path"
	}
	$fullPath = [IO.Path]::GetFullPath($Path)
	$tokens = $null
	$parseErrors = $null
	$ast = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref] $tokens, [ref] $parseErrors)
	if (@($parseErrors).Count -gt 0) {
		throw "Deploy profile has PowerShell parse errors: $fullPath"
	}

	$statements = @($ast.EndBlock.Statements)
	if ($statements.Count -ne 1 -or $statements[0] -isnot [System.Management.Automation.Language.AssignmentStatementAst]) {
		throw 'Deploy profile must contain only one $DeployConfig assignment.'
	}
	$assignment = $statements[0]
	if ($null -ne $ast.ParamBlock -and @($ast.ParamBlock.Parameters).Count -gt 0) {
		throw 'Deploy profile must not contain a param block.'
	}
	foreach ($blockName in @('BeginBlock', 'ProcessBlock', 'DynamicParamBlock', 'CleanBlock')) {
		if (-not ($ast.PSObject.Properties.Name -contains $blockName)) { continue }
		$block = $ast.$blockName
		if ($null -ne $block -and @($block.Statements).Count -gt 0) {
			throw "Deploy profile must not contain a $blockName block."
		}
	}
	if ($assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
		$assignment.Left.VariablePath.UserPath -cne 'DeployConfig') {
		throw 'Deploy profile must assign only $DeployConfig.'
	}
	$profileValueAst = $assignment.Right
	if ($profileValueAst -is [System.Management.Automation.Language.CommandExpressionAst]) {
		$profileValueAst = $profileValueAst.Expression
	}
	if ($profileValueAst -is [System.Management.Automation.Language.PipelineAst] -and $profileValueAst.PipelineElements.Count -eq 1 -and
		$profileValueAst.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
		$profileValueAst = $profileValueAst.PipelineElements[0].Expression
	}
	if ($profileValueAst -isnot [System.Management.Automation.Language.HashtableAst]) {
		throw '$DeployConfig must be a literal hashtable.'
	}

	$configuration = @{}
	foreach ($pair in $profileValueAst.KeyValuePairs) {
		$keyAst = $pair.Item1
		$valueAst = $pair.Item2
		if ($keyAst -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
			throw 'Deploy profile keys must be literal strings.'
		}
		$key = [string] $keyAst.Value
		if ([string]::IsNullOrWhiteSpace($key) -or $configuration.ContainsKey($key)) {
			throw "Deploy profile contains an invalid or duplicate key: $key"
		}
		if (-not (Test-DeployProfileLiteralAst -Ast $valueAst)) {
			throw "Deploy profile value is not a safe literal: $key"
		}
		try {
			$value = $valueAst.SafeGetValue()
		} catch {
			throw "Deploy profile value could not be evaluated safely: $key"
		}
		if (-not (Test-DeployProfileLiteralValue -Value $value)) {
			throw "Deploy profile value has an unsupported type: $key"
		}
		$configuration[$key] = $value
	}
	return $configuration
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

function Assert-ReleasePackage {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $Path,
		[Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Configuration,
		[bool] $RequireUploads = $true
	)

	if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Release package not found: $Path" }
	$sql = Join-Path $Path 'database.sql'
	$manifestPath = Join-Path $Path 'release-manifest.json'
	if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Release package manifest is missing.' }
	Assert-SqlDumpFile $sql
	try { $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json } catch { throw 'Release package manifest is invalid JSON.' }
	if ($null -eq $manifest) { throw 'Release package manifest is invalid JSON.' }
	if ($Configuration.Contains('ExpectedDbTablePrefix') -xor $Configuration.Contains('ExpectedDbTableCount')) {
		throw 'ExpectedDbTablePrefix and ExpectedDbTableCount must be configured together.'
	}
	$sourceProperty = @($manifest.PSObject.Properties | Where-Object { $_.Name -eq 'source' })
	$databaseProperty = @($manifest.PSObject.Properties | Where-Object { $_.Name -eq 'database' })
	if ($sourceProperty.Count -ne 1 -or $databaseProperty.Count -ne 1) { throw 'Release package manifest is missing source or database metadata.' }
	$source = $sourceProperty[0].Value
	$database = $databaseProperty[0].Value
	if ($null -eq $source -or $null -eq $database) { throw 'Release package manifest is missing source or database metadata.' }
	$canonicalProperty = @($source.PSObject.Properties | Where-Object { $_.Name -eq 'canonicalSource' })
	if ($canonicalProperty.Count -ne 1 -or $canonicalProperty[0].Value -ne $true) { throw 'Release package is not marked as canonical local source.' }
	$rawDumpShaProperty = @($database.PSObject.Properties | Where-Object { $_.Name -eq 'rawDumpSha256' })
	if ($rawDumpShaProperty.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$rawDumpShaProperty[0].Value)) { throw 'Release package database SHA is missing.' }
	$rawDumpSha = [string]$rawDumpShaProperty[0].Value
	$actualSqlSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $sql).Hash.ToUpperInvariant()
	if ($actualSqlSha -ne $rawDumpSha.ToUpperInvariant()) { throw 'Release package database SHA does not match its manifest.' }
	if ($RequireUploads) {
		$uploads = Join-Path $Path 'uploads.zip'
		$artifactHashesPath = Join-Path $Path 'artifact-hashes.json'
		Assert-ZipArchiveFile $uploads
		if (-not (Test-Path -LiteralPath $artifactHashesPath -PathType Leaf)) { throw 'Release package artifact hashes are missing.' }
		try {
			$parsedArtifactHashes = Get-Content -Raw -LiteralPath $artifactHashesPath | ConvertFrom-Json
			if ($null -eq $parsedArtifactHashes) { $artifactHashes = @() }
			elseif ($parsedArtifactHashes -is [Array]) { $artifactHashes = [object[]]$parsedArtifactHashes }
			else { $artifactHashes = @($parsedArtifactHashes) }
		} catch { throw 'Release package artifact hashes are invalid JSON.' }
		$uploadHashEntries = @($artifactHashes | Where-Object {
			$pathProperty = @($_.PSObject.Properties | Where-Object { $_.Name -eq 'path' })
			$pathProperty.Count -eq 1 -and $pathProperty[0].Value -eq 'uploads.zip'
		})
		$uploadShaProperty = @(
			if ($uploadHashEntries.Count -eq 1) { @($uploadHashEntries[0].PSObject.Properties | Where-Object { $_.Name -eq 'sha256' }) }
			else { @() }
		)
		if ($uploadShaProperty.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$uploadShaProperty[0].Value)) { throw 'Release package uploads SHA is missing.' }
		$uploadSha = [string]$uploadShaProperty[0].Value
		$actualUploadsSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $uploads).Hash.ToUpperInvariant()
		if ($actualUploadsSha -ne $uploadSha.ToUpperInvariant()) { throw 'Release package uploads SHA does not match artifact hashes.' }
	}
	$tablePrefixProperty = @($database.PSObject.Properties | Where-Object { $_.Name -eq 'tablePrefix' })
	$tableCountProperty = @($database.PSObject.Properties | Where-Object { $_.Name -eq 'exactTableCount' })
	if ($Configuration.Contains('ExpectedDbTablePrefix') -and ($tablePrefixProperty.Count -ne 1 -or [string]$tablePrefixProperty[0].Value -ne [string]$Configuration.ExpectedDbTablePrefix)) {
		throw 'Release package database prefix does not match the profile.'
	}
	if ($Configuration.Contains('ExpectedDbTableCount') -and ($tableCountProperty.Count -ne 1 -or [int]$tableCountProperty[0].Value -ne [int]$Configuration.ExpectedDbTableCount)) {
		throw 'Release package database table count does not match the profile.'
	}
	$dumpText = [IO.File]::ReadAllText($sql)
	if ($Configuration.Contains('ExpectedDbTablePrefix') -and $Configuration.Contains('ExpectedDbTableCount')) {
		$allTableCount = [regex]::Matches($dumpText, '(?m)^CREATE TABLE `[^`]+`').Count
		if ($allTableCount -ne [int]$Configuration.ExpectedDbTableCount) { throw 'Release package SQL total table count does not match the profile.' }
		$prefix = [regex]::Escape([string]$Configuration.ExpectedDbTablePrefix)
		$tablePattern = '(?m)^CREATE TABLE `' + $prefix + '[^`]+`'
		$actualPrefixCount = [regex]::Matches($dumpText, $tablePattern).Count
		if ($actualPrefixCount -ne [int]$Configuration.ExpectedDbTableCount) { throw 'Release package SQL table count does not match the profile.' }
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
	if ($DeployMode -eq 'full') {
		$productionFullOptIn = if ($Configuration.Contains('AllowProductionFull') -and $Configuration.AllowProductionFull -is [bool] -and $Configuration.AllowProductionFull) { '1' } else { '0' }
		$assignments += ,@('PRODUCTION_FULL_OPT_IN', $productionFullOptIn)
	}

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
	if ($Value -match '[\x00-\x1F\\:*?"<>|]' -or [IO.Path]::IsPathRooted($Value)) {
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

function Test-RelativeProfilePath {
	param([string] $Value)

	if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq '.') {
		return $false
	}
	if ($Value -match '[\x00-\x1F\\:*?"<>|]' -or [IO.Path]::IsPathRooted($Value)) {
		return $false
	}
	if ($Value -match '(^|/)\.\.?(/|$)' -or $Value.EndsWith('/')) {
		return $false
	}

	return $true
}

function Test-ProtectedProfilePath {
	param([string] $Value)

	if (-not (Test-RelativeProfilePath $Value)) {
		return $false
	}
	if ($Value -match '(?i)^(\.git|\.deploy)(/|$)') {
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
	$optionalStringKeys = @(
		'SiteId', 'DisplayName', 'GitRemoteName', 'GitBranch',
		'ExpectedDbTablePrefix', 'ExpectedWordPressCoreVersion', 'CorePolicy'
	)
	$optionalLocalPathKeys = @(
		'CodeRepositoryPath', 'WorkRoot', 'MysqlPath', 'LocalPhpPath',
		'LocalWpCliPath', 'LocalBackupDirectory'
	)
	$optionalBooleanKeys = @('UseLegacyScp', 'AllowProductionFull')
	$optionalProfileBooleanKeys = @('PullEnabled', 'AllowProductionPull', 'RequirePullConfirmation', 'AllowDestructiveLocalReplace')
	$optionalIntegerKeys = @('ExpectedDbTableCount', 'ExpectedPullDbTableCount', 'MinimumPullDbTableCount', 'KeepLocalBackups', 'KeepBackupDays', 'MaxBackupSizeMB')
	$optionalArrayKeys = @('FullSyncPaths', 'ProtectedSyncPaths', 'AllowedPullPaths', 'FullPullPaths', 'ExcludedPullPaths')
	$otherRequiredKeys = @('SshPort', 'KeepBackups', 'MinimumLocalFreeSpaceMB', 'MinimumRemoteFreeSpaceMB', 'SyncPaths')
	$allowedKeys = $requiredStringKeys + $optionalKeys + $optionalStringKeys + $optionalLocalPathKeys + $optionalBooleanKeys + $optionalProfileBooleanKeys + $optionalIntegerKeys + $optionalArrayKeys + $otherRequiredKeys

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
	foreach ($key in ($optionalStringKeys + $optionalLocalPathKeys)) {
		if ($Configuration.Contains($key) -and ($Configuration[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($Configuration[$key]))) {
			Add-ValidationError $errors "$key must be a non-empty string when configured."
		}
	}
	foreach ($key in ($optionalBooleanKeys + $optionalProfileBooleanKeys)) {
		if ($Configuration.Contains($key) -and $Configuration[$key] -isnot [bool]) {
			Add-ValidationError $errors "$key must be a Boolean when configured."
		}
	}
	foreach ($key in $optionalIntegerKeys) {
		if ($Configuration.Contains($key) -and ($Configuration[$key] -isnot [int] -or $Configuration[$key] -lt 1)) {
			Add-ValidationError $errors "$key must be a positive integer when configured."
		}
	}
	foreach ($key in $optionalArrayKeys) {
		if (-not $Configuration.Contains($key)) { continue }
		if ($Configuration[$key] -isnot [Array]) {
			Add-ValidationError $errors "$key must be an array of repository-relative paths."
			continue
		}
		$seen = @{}
		foreach ($path in @($Configuration[$key])) {
			$pathIsSafe = if ($key -eq 'ProtectedSyncPaths') {
				$path -is [string] -and (Test-ProtectedProfilePath $path)
			} else {
				$path -is [string] -and (Test-SyncPath $path)
			}
			if (-not $pathIsSafe) {
				Add-ValidationError $errors "Unsafe $key value: $path"
				continue
			}
			$normalizedPath = $path.ToLowerInvariant()
			if ($seen.ContainsKey($normalizedPath)) {
				Add-ValidationError $errors "Duplicate $key value: $path"
			}
			$seen[$normalizedPath] = $true
		}
	}
	if ($Configuration.Contains('ExpectedDbTablePrefix') -xor $Configuration.Contains('ExpectedDbTableCount')) {
		Add-ValidationError $errors 'ExpectedDbTablePrefix and ExpectedDbTableCount must be configured together.'
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
	if ($Configuration.Contains('SiteId') -and $Configuration.SiteId -notmatch '^[A-Za-z0-9._-]+$') {
		Add-ValidationError $errors 'SiteId contains unsupported characters.'
	}
	if ($Configuration.Contains('ExpectedDbTablePrefix') -and $Configuration.ExpectedDbTablePrefix -notmatch '^[A-Za-z0-9_]+$') {
		Add-ValidationError $errors 'ExpectedDbTablePrefix contains unsupported characters.'
	}
	if ($Configuration.Contains('CorePolicy') -and $Configuration.CorePolicy -notmatch '^[A-Za-z0-9._-]+$') {
		Add-ValidationError $errors 'CorePolicy contains unsupported characters.'
	}
	if ($Configuration.Contains('GitRemoteName') -and $Configuration.GitRemoteName -notmatch '^[A-Za-z0-9_][A-Za-z0-9._-]*$') {
		Add-ValidationError $errors 'GitRemoteName contains unsupported characters.'
	}
	if ($Configuration.Contains('GitBranch') -and ($Configuration.GitBranch -notmatch '^[A-Za-z0-9_][A-Za-z0-9._/-]*$' -or $Configuration.GitBranch -match '(^|/)\.\.?(/|$)')) {
		Add-ValidationError $errors 'GitBranch contains unsupported characters.'
	}
	if ($Configuration.Contains('ExpectedWordPressCoreVersion') -and $Configuration.ExpectedWordPressCoreVersion -notmatch '^[0-9]+(\.[0-9]+){1,3}$') {
		Add-ValidationError $errors 'ExpectedWordPressCoreVersion contains unsupported characters.'
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
	foreach ($key in $optionalLocalPathKeys) {
		if ($Configuration.Contains($key) -and -not [IO.Path]::IsPathRooted($Configuration[$key])) {
			Add-ValidationError $errors "$key must be an absolute local path when configured."
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
		[string] $Mode,

		[object] $AllowProductionFull = $false
	)

	if ($AllowProductionFull -isnot [bool]) {
		throw 'AllowProductionFull must be a Boolean.'
	}

	if ($Environment -eq 'production') {
		if ($Mode -eq 'db') {
			throw "Mode '$Mode' is forbidden for production. Use code mode or an explicitly enabled full mode."
		}
		if ($Mode -eq 'full' -and -not $AllowProductionFull) {
			throw "Mode '$Mode' is forbidden for production until AllowProductionFull is explicitly enabled."
		}
	}
}

Export-ModuleMember -Function Import-DeployProfileData, Get-DeployConfigurationErrors, Assert-DeployConfiguration, Assert-DeployModeAllowed, ConvertTo-ShSingleQuotedString, New-RemoteDeployCommand, Invoke-CheckedCommand, Invoke-CommandOutput, Get-DirectoryContentSizeBytes, Assert-AvailableDiskSpace, Assert-SqlDumpFile, Assert-ZipArchiveFile, Assert-ReleasePackage
