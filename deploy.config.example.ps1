# Copy to deploy.config.ps1 and replace every example value.
# deploy.config.ps1 is ignored by Git and must never be committed.

$DeployConfig = @{
	# Required: development, staging, or production.
	# Explicit per-profile component capability. Existing profiles without this key retain their legacy policy until migrated.
	AllowedDeployModes = @('preflight', 'code', 'db', 'code-db', 'uploads', 'plugins', 'mu-plugins', 'full')
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

	# Code, ordinary plugins and mu-plugins are separate components. Keep wp-config.php and Divi out unless a separate profile policy allows them.
	SyncPaths = @(
		'wp-content/themes/example-theme'
	)
	PluginSyncPaths = @('wp-content/plugins/example-plugin')
	MuPluginSyncPaths = @('wp-content/mu-plugins/example-loader')

	KeepBackups = 10
	MinimumLocalFreeSpaceMB  = 1024
	MinimumRemoteFreeSpaceMB = 1024
}

