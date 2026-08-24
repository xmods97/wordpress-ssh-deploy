#!/usr/bin/env sh
set -eu

repo_dir="$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)"
fixture_dir="${TMPDIR:-/tmp}/wordpress-ssh-deploy-server-test-$$"
target_root='/tmp/wordpress-ssh-deploy-fixture'
mkdir -p "$fixture_dir"
cleanup_fixture() {
	status=$?
	trap - 0 1 2 15
	rm -rf "$fixture_dir" "$target_root"
	exit "$status"
}
trap cleanup_fixture 0 1 2 15

if [ "${FIXTURE_FORCE_SMOKE_FAILURE:-0}" = 1 ]; then
	echo 'Forced smoke failure' >&2
	exit 1
fi

cp "$repo_dir/server-deploy.sh" "$fixture_dir/server-deploy.sh"
cp "$repo_dir/tests/fixtures/server.config.production.sh" "$fixture_dir/server.config.sh"

run_server() {
	PATH="$target_root/bin:/usr/bin:/bin:/mingw64/bin" \
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
	SQL_FILE="${FIXTURE_SQL_FILE:-}" \
	UPLOADS_ZIP="${FIXTURE_UPLOADS_ZIP:-}" \
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

mkdir -p "$target_root/wp/wp-content" "$target_root/repo/.git" "$target_root/tmp" "$target_root/bin"
: > "$target_root/wp/wp-config.php"
: > "$target_root/id_ed25519"
: > "$target_root/tmp/local-db-stale.sql"
touch -t 202001010000 "$target_root/tmp/local-db-stale.sql"
: > "$target_root/tmp/preflight-input.sql"
cp "$repo_dir/tests/fixtures/fake-php.sh" "$target_root/bin/php"
cp "$repo_dir/tests/fixtures/fake-id.sh" "$target_root/bin/id"
: > "$target_root/bin/wp"

output="$(FIXTURE_EFFECTIVE_UID=0 FIXTURE_EXPECT_ALLOW_ROOT=1 FIXTURE_SQL_FILE="$target_root/tmp/preflight-input.sql" run_server production preflight)"
case "$output" in
	*'WordPress deployment completed (preflight)'*) ;;
	*) echo 'Preflight did not complete correctly' >&2; exit 1 ;;
esac
[ -f "$target_root/tmp/local-db-stale.sql" ] || {
	echo 'Preflight removed a stale temporary artifact' >&2
	exit 1
}
[ -f "$target_root/tmp/preflight-input.sql" ] || {
	echo 'Preflight exit cleanup removed an input artifact' >&2
	exit 1
}
[ ! -e "$target_root/lock" ] || {
	echo 'Preflight created a lock directory' >&2
	exit 1
}
[ ! -e "$target_root/backups" ] || {
	echo 'Preflight created a backup directory' >&2
	exit 1
}

output="$(FIXTURE_EFFECTIVE_UID=1000 FIXTURE_EXPECT_ALLOW_ROOT=0 run_server production preflight)"
case "$output" in
	*'WordPress deployment completed (preflight)'*) ;;
	*) echo 'Non-root preflight did not complete correctly' >&2; exit 1 ;;
esac

run_server production code >/dev/null 2>&1 || true
[ ! -d "$target_root/lock/deploy.lock" ] || {
	echo 'Lock directory remained after a failed operation' >&2
	exit 1
}

echo 'Remote production policy: OK'
echo 'Remote lock cleanup: OK'
echo 'Remote preflight purity: OK'
echo 'Remote WP-CLI root guard: OK'
