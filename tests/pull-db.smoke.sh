#!/usr/bin/env sh
set -eu

repo_dir="$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)"
fixture_dir="${TMPDIR:-/tmp}/wordpress-ssh-deploy-pull-db-test-$$"
target_root="/tmp/wordpress-ssh-deploy-pull-db-fixture"
mkdir -p "$fixture_dir" "$target_root/wp/wp-content" "$target_root/repo/.git" "$target_root/tmp" "$target_root/backups" "$target_root/bin"
trap 'rm -rf "$fixture_dir" "$target_root"' 0 1 2 15

cp "$repo_dir/server-deploy.sh" "$fixture_dir/server-deploy.sh"
sed "s#/tmp/wordpress-ssh-deploy-fixture#$target_root#g" \
	"$repo_dir/tests/fixtures/server.config.production.sh" > "$fixture_dir/server.config.sh"
cp "$repo_dir/tests/fixtures/fake-php.sh" "$target_root/bin/php"
: > "$target_root/bin/wp"
: > "$target_root/id_ed25519"
: > "$target_root/wp/wp-config.php"

output="$({
	SERVER_ALLOW_PRODUCTION_PULL='1' \
	ALLOW_PRODUCTION_PULL='1' \
	ENVIRONMENT='production' \
	LOCAL_URL='http://local.example.test' \
	REMOTE_URL='https://example.com' \
	WP_DIR="$target_root/wp" \
	REPO_DIR="$target_root/repo" \
	BACKUP_DIR="$target_root/backups" \
	EXPECTED_WP_DIR="$target_root/wp" \
	EXPECTED_DB_NAME='wordpress_production' \
	EXPECTED_DB_TABLE_PREFIX='wp_' \
	EXPECTED_REMOTE_DOMAIN='example.com' \
	SYNC_PATHS='wp-content/themes/example-theme' \
	GIT_SSH_KEY="$target_root/id_ed25519" \
	PHP_BIN="$target_root/bin/php" \
	WP_CLI_BIN="$target_root/bin/wp" \
	KEEP_BACKUPS='10' \
	MIN_REMOTE_FREE_SPACE_MB='1' \
	PULL_ARTIFACT="$target_root/tmp/pull-db.sql.gz" \
	DEPLOY_MODE='pull-db' \
	PATH="$target_root/bin:/usr/bin:/bin" \
	sh "$fixture_dir/server-deploy.sh"
} 2>&1)"

case "$output" in
	*'WordPress pull export completed (pull-db)'*) ;;
	*) echo "Pull DB export did not complete: $output" >&2; exit 1 ;;
esac

[ -s "$target_root/tmp/pull-db.sql.gz" ] || {
	echo 'Pull DB artifact was not created' >&2
	exit 1
}
gzip -t "$target_root/tmp/pull-db.sql.gz"
gzip -dc "$target_root/tmp/pull-db.sql.gz" | grep -q '^CREATE TABLE `wp_options`' || {
	echo 'WP-CLI pull export did not contain the expected active table' >&2
	exit 1
}
gzip -dc "$target_root/tmp/pull-db.sql.gz" | grep -q '^CREATE TABLE `wp_posts`' || {
	echo 'WP-CLI pull export did not contain the second active table' >&2
	exit 1
}

echo 'Pull DB export through WP-CLI: OK'
