# Copy to deploy.config.ps1 and replace every example value.
# deploy.config.ps1 is ignored by Git and must never be committed.

$DeployConfig = @{
	# Required: development, staging, or production.
	# Production permits only code deployment.
	Environment = 'staging'
	SiteId      = 'example-site'
	DisplayName = 'Example site'

	# The deploy tool lives in its own repository. Site code and runtime artifacts are
	# isolated per profile and never stored in this repository.
	CodeRepositoryPath = 'D:\wordpress-sites\example-site-code'
	WorkRoot           = 'D:\wordpress-ssh-deploy\sites\example-site'
	GitRemoteName      = 'origin'
	GitBranch          = 'main'

	LocalWpPath      = 'D:\laragon\www\example.test'
	LocalUrl         = 'http://example.test'
	LocalUploadsPath = 'D:\laragon\www\example.test\wp-content\uploads'

	LocalDbName     = 'wordpress'
	LocalDbUser     = 'root'
	LocalDbPassword = ''
	LocalDbHost     = 'localhost'

	MysqldumpPath = 'C:\path\to\mysqldump.exe'
	GitPath       = 'C:\path\to\git.exe'

	SshUser    = 'deploy'
	SshHost    = 'server.example.com'
	SshPort    = 22
	SshKeyPath = 'C:\Users\you\.ssh\id_ed25519'
	# Set true only for a server-side forced-command wrapper that permits legacy SCP.
	UseLegacyScp = $false

	RemoteUrl       = 'https://staging.example.com'
	RemoteWpPath    = '/var/www/staging.example.com'
	RemoteRepoPath  = '/srv/repos/example-site'
	RemoteRunnerPath = '/usr/local/libexec/wordpress-ssh-deploy/example-site/server-deploy.sh'
	RemoteTmpPath   = '/srv/tmp/example-deploy'
	RemoteBackups   = '/srv/backups/example-site'
	RemoteGitSshKey = '/home/deploy/.ssh/id_ed25519'
	RemotePhpPath   = '/usr/bin/php'
	RemoteWpCliPath = '/usr/local/bin/wp'

	# Safety locks. Deployment stops if the actual target does not match.
	ExpectedRemoteDomain = 'staging.example.com'
	ExpectedRemoteWpPath = '/var/www/staging.example.com'
	ExpectedRemoteDbName = 'wordpress_staging'
	ExpectedDbTablePrefix = 'wp_'

	# Paths are relative to the repository and copied into WordPress.
	SyncPaths = @(
		'wp-content/themes/example-theme',
		'wp-content/plugins/example-plugin'
	)

	# Full deploy paths. Use this only for explicit -Mode full; code mode remains scoped
	# to SyncPaths. Protected paths require -ReplaceProtected -ConfirmProtected.
	FullSyncPaths = @(
		'wp-content/themes/example-theme',
		'wp-content/plugins/example-plugin'
	)
	ProtectedSyncPaths = @(
		'wp-config.php'
	)

	KeepBackups = 10

	# Exact number of tables the local database export must contain.
	# Integer >= 1. A stock WordPress install has 12; add one per extra plugin table.
	ExpectedDbTableCount = 12

	MinimumLocalFreeSpaceMB  = 1024
	MinimumRemoteFreeSpaceMB = 1024

	# --- Pull: staging -> local. Optional; omit every key below to stay push-only. ---

	# Master switch. While false, every pull mode is refused and the keys below are not
	# validated. Pull is never allowed when Environment is 'production'.
	PullEnabled = $false

# Pull downloads to a workspace first. A separately confirmed apply backs up and
# replaces this profile's one working local database (LocalDbName) and paths.
# Local backups must be outside LocalWpPath.
	LocalBackupDirectory = 'D:\wordpress-ssh-deploy\sites\example-site\backups'

	# WordPress-relative paths that pull-files may bring down. Everything else is refused.
	AllowedPullPaths = @(
		'wp-content/uploads'
	)

# Full pull is composed from explicit classes. Core files are never downloaded
# or replaced: the existing local WordPress installation remains the test copy.
	PullContentPaths = @(
		'wp-content/themes',
		'wp-content/plugins',
		'wp-content/mu-plugins'
	)
	PullMediaPaths = @('wp-content/uploads')
CorePolicy = 'preserve-local-core'
	ExpectedWordPressCoreVersion = ''

	# Extra exclusions on top of the permanent deny list (wp-config*, .git, .ssh, .env,
	# key material, caches, backups). Configuration can extend that list, never shorten it.
	ExcludedPullPaths = @(
		'wp-content/uploads/private'
	)

	# Keep true. When true, pull-db and pull-full refuse to run without -Confirm.
	RequirePullConfirmation = $true
	# Exact number of active tables expected from the remote pull.
	ExpectedPullDbTableCount = 12
	KeepLocalBackups = 5
	KeepBackupDays = 30
	MaxBackupSizeMB = 10240

	# Reserved for mirror pull, which deletes local files the remote no longer has.
	# Mirror is part of the contract but refuses to run in this version.
	AllowDestructiveLocalReplace = $false

	# Local tools used to verify and import a pulled database.
	LocalPhpPath   = 'C:\path\to\php.exe'
	LocalWpCliPath = 'D:\wordpress-ssh-deploy\tools\wp-cli.phar'
	MysqlPath      = 'C:\path\to\mysql.exe'
}

