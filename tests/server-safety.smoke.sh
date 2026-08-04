#!/usr/bin/env sh
set -eu

repo_dir="$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)"
fixture_dir="${TMPDIR:-/tmp}/wordpress-ssh-deploy-server-test-$$"
target_root='/tmp/wordpress-ssh-deploy-fixture'
mkdir -p "$fixture_dir"
trap 'rm -rf "$fixture_dir" "$target_root"' 0 1 2 15

cp "$repo_dir/server-deploy.sh" "$fixture_dir/server-deploy.sh"
cp "$repo_dir/tests/fixtures/server.config.production.sh" "$fixture_dir/server.config.sh"

run_server() {
	ENVIRONMENT="$1" \
	REMOTE_URL='https://example.com' \
	WP_DIR='/tmp/wordpress-ssh-deploy-fixture/wp' \
	REPO_DIR='/tmp/wordpress-ssh-deploy-fixture/repo' \
	BACKUP_DIR='/tmp/wordpress-ssh-deploy-fixture/backups' \
	EXPECTED_WP_DIR='/tmp/wordpress-ssh-deploy-fixture/wp' \
	EXPECTED_DB_NAME='wordpress_production' \
	EXPECTED_REMOTE_DOMAIN='example.com' \
	SYNC_PATHS='wp-content/themes/example-theme' \
	GIT_SSH_KEY='/tmp/wordpress-ssh-deploy-fixture/id_ed25519' \
	PHP_BIN='/tmp/wordpress-ssh-deploy-fixture/bin/php' \
	WP_CLI_BIN='/tmp/wordpress-ssh-deploy-fixture/bin/wp' \
	KEEP_BACKUPS='10' \
	MIN_REMOTE_FREE_SPACE_MB='1' \
	DEPLOY_MODE="$2" \
	sh "$fixture_dir/server-deploy.sh" 2>&1
}

output="$(run_server production db || true)"
case "$output" in
	*'Database and uploads deployment is forbidden for production'*) ;;
	*) echo "Production DB mode was not rejected correctly" >&2; exit 1 ;;
esac

output="$(run_server staging code || true)"
case "$output" in
	*'Environment does not match server policy'*) ;;
	*) echo "Server environment mismatch was not rejected correctly" >&2; exit 1 ;;
esac

mkdir -p "$target_root/wp/wp-content" "$target_root/repo/.git" "$target_root/tmp" "$target_root/backups" "$target_root/bin"
: > "$target_root/wp/wp-config.php"
: > "$target_root/id_ed25519"
cp "$repo_dir/tests/fixtures/fake-php.sh" "$target_root/bin/php"
: > "$target_root/bin/wp"

run_server production code >/dev/null 2>&1 || true
[ ! -d "$target_root/lock/deploy.lock" ] || {
	echo 'Lock directory remained after a failed operation' >&2
	exit 1
}

echo 'Remote production policy: OK'
echo 'Remote lock cleanup: OK'
