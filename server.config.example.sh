# Copy this file to server.config.sh beside server-deploy.sh on the remote host.
# Keep server.config.sh untracked and writable only by the server administrator.

SERVER_ENVIRONMENT='staging'
SERVER_EXPECTED_URL='https://staging.example.com'
SERVER_EXPECTED_WP_DIR='/var/www/staging.example.com'
SERVER_EXPECTED_REPO_DIR='/srv/repos/example-site'
SERVER_EXPECTED_TMP_DIR='/srv/tmp/example-deploy'
SERVER_EXPECTED_BACKUP_DIR='/srv/backups/example-site'
SERVER_EXPECTED_DB_NAME='wordpress_staging'
SERVER_GIT_SSH_KEY='/home/deploy/.ssh/id_ed25519'
SERVER_PHP_BIN='/usr/bin/php'
SERVER_WP_CLI_BIN='/usr/local/bin/wp'
SERVER_SYNC_PATHS='wp-content/themes/example-theme,wp-content/plugins/example-plugin'
SERVER_KEEP_BACKUPS='10'
SERVER_MIN_FREE_SPACE_MB='1024'
SERVER_LOCK_DIR='/srv/locks/example-site-deploy.lock'
