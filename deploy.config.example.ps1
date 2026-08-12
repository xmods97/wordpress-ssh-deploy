# Copy to deploy.config.ps1 and replace every example value.
# deploy.config.ps1 is ignored by Git and must never be committed.

$DeployConfig = @{
	# Required: development, staging, or production.
	# Production permits only code deployment.
	Environment = 'staging'

	LocalWpPath      = 'C:\Sites\example.test'
	LocalUrl         = 'http://example.test'
	LocalUploadsPath = 'C:\Sites\example.test\wp-content\uploads'

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

	KeepBackups = 10

	# Exact number of tables the local database export must contain.
	# Integer >= 1. A stock WordPress install has 12; add one per extra plugin table.
	ExpectedDbTableCount = 12

	MinimumLocalFreeSpaceMB  = 1024
	MinimumRemoteFreeSpaceMB = 1024
}

