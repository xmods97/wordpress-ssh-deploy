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

cp "$repo_dir/server-deploy.sh" "$fixture_dir/server-deploy.sh"
cp "$repo_dir/tests/fixtures/server.config.production.sh" "$fixture_dir/server.config.sh"

run_server() {
	PATH="$target_root/bin:/usr/bin:/bin:/mingw64/bin" \
	FIXTURE_ROOT="$target_root" \
	ENVIRONMENT="$1" \
	REMOTE_URL='https://example.com' \
	WP_DIR='/tmp/wordpress-ssh-deploy-fixture/wp' \
	REPO_DIR='/tmp/wordpress-ssh-deploy-fixture/repo' \
	BACKUP_DIR='/tmp/wordpress-ssh-deploy-fixture/backups' \
	EXPECTED_WP_DIR='/tmp/wordpress-ssh-deploy-fixture/wp' \
	EXPECTED_DB_NAME='wordpress_production' \
	EXPECTED_REMOTE_DOMAIN='example.com' \
	SYNC_PATHS='wp-content/themes/example-theme' \
	PLUGIN_SYNC_PATHS='' \
	MU_PLUGIN_SYNC_PATHS='' \
	ALLOWED_DEPLOY_MODES="${FIXTURE_ALLOWED_DEPLOY_MODES:-preflight,code,full}" \
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
	*'Deploy mode is not enabled by profile policy'*) ;;
	*) echo "Production DB mode was not rejected by profile policy" >&2; exit 1 ;;
esac

cp "$fixture_dir/server.config.sh" "$fixture_dir/server.config.explicit.sh"
grep -v '^SERVER_ALLOWED_DEPLOY_MODES=' "$fixture_dir/server.config.explicit.sh" > "$fixture_dir/server.config.sh"
output="$(FIXTURE_ALLOWED_DEPLOY_MODES='preflight,code,db' run_server production db || true)"
case "$output" in
	*'Deploy mode is not enabled by server policy'*) ;;
	*) echo "Legacy production server policy did not fail closed for DB mode" >&2; exit 1 ;;
esac
mv "$fixture_dir/server.config.explicit.sh" "$fixture_dir/server.config.sh"

output="$(FIXTURE_ALLOWED_DEPLOY_MODES='preflight,code,db,code-db,uploads,plugins,full' run_server production db || true)"
case "$output" in
	*'WordPress configuration was not found'*) ;;
	*) echo "Explicit production DB capability did not pass mode policy" >&2; exit 1 ;;
esac

output="$(FIXTURE_ALLOWED_DEPLOY_MODES='preflight,code,db,code-db,uploads,plugins,full' run_server production plugins || true)"
case "$output" in
	*'Plugins mode requires configured plugin sync paths'*) ;;
	*) echo "Plugins mode did not reject an empty plugin allowlist" >&2; exit 1 ;
esac

output="$(FIXTURE_ALLOWED_DEPLOY_MODES='preflight,code,db,code-db,uploads,plugins,mu-plugins,full' run_server production mu-plugins || true)"
case "$output" in
	*'Mu-plugins mode requires configured mu-plugin sync paths'*) ;;
	*) echo "MU-plugins mode did not reject an empty MU-plugin allowlist" >&2; exit 1 ;;
esac

output="$(FIXTURE_ALLOWED_DEPLOY_MODES='preflight,code,unknown' run_server production code || true)"
case "$output" in
	*'Invalid profile deploy mode policy'*) ;;
	*) echo "Unknown profile mode was not rejected" >&2; exit 1 ;;
esac

output="$(run_server production full || true)"
case "$output" in
	*'Production full mode requires an explicit client profile opt-in'*) ;;
	*) echo "Production full mode was not rejected without client opt-in" >&2; exit 1 ;;
esac

output="$(PRODUCTION_FULL_OPT_IN=1 run_server production full || true)"
case "$output" in
	*'Production full mode is disabled by server policy'*) ;;
	*) echo "Production full mode was not rejected without server opt-in" >&2; exit 1 ;;
esac

output="$(run_server staging code || true)"
case "$output" in
	*'Environment does not match server policy'*) ;;
	*) echo "Server environment mismatch was not rejected correctly" >&2; exit 1 ;;
esac

mkdir -p "$target_root/wp/wp-content/themes/example-theme" "$target_root/repo/.git" "$target_root/tmp" "$target_root/bin"
: > "$target_root/wp/wp-config.php"
: > "$target_root/id_ed25519"
: > "$target_root/tmp/local-db-stale.sql"
touch -t 202001010000 "$target_root/tmp/local-db-stale.sql"
: > "$target_root/tmp/preflight-input.sql"
cp "$repo_dir/tests/fixtures/fake-php.sh" "$target_root/bin/php"
cp "$repo_dir/tests/fixtures/fake-id.sh" "$target_root/bin/id"
cp "$repo_dir/tests/fixtures/fake-stat.sh" "$target_root/bin/stat"
cp "$repo_dir/tests/fixtures/fake-chown.sh" "$target_root/bin/chown"
cp "$repo_dir/tests/fixtures/fake-chmod.sh" "$target_root/bin/chmod"
cp "$repo_dir/tests/fixtures/fake-runuser.sh" "$target_root/bin/runuser"
cp "$repo_dir/tests/fixtures/fake-df.sh" "$target_root/bin/df"
cp "$repo_dir/tests/fixtures/fake-du.sh" "$target_root/bin/du"
cp "$repo_dir/tests/fixtures/fake-git.sh" "$target_root/bin/git"
cp "$repo_dir/tests/fixtures/fake-find.sh" "$target_root/bin/find"
: > "$target_root/bin/wp"

output="$(FIXTURE_EFFECTIVE_UID=1000 FIXTURE_SQL_FILE="$target_root/tmp/preflight-input.sql" run_server production preflight)"
case "$output" in
	*'WordPress deployment completed (preflight)'*) ;;
	*) echo 'Preflight did not complete correctly' >&2; exit 1 ;;
esac
[ -f "$target_root/tmp/local-db-stale.sql" ] || { echo 'Preflight removed a stale temporary artifact' >&2; exit 1; }
[ -f "$target_root/tmp/preflight-input.sql" ] || { echo 'Preflight exit cleanup removed an input artifact' >&2; exit 1; }
[ ! -e "$target_root/lock" ] || { echo 'Preflight created a lock directory' >&2; exit 1; }
[ ! -e "$target_root/backups" ] || { echo 'Preflight created a backup directory' >&2; exit 1; }

mkdir -p "$target_root/repo/wp-content/themes/example-theme"
printf '%s\n' 'managed source' > "$target_root/repo/wp-content/themes/example-theme/style.css"
printf '%s\n' 'production-only' > "$target_root/wp/wp-content/themes/example-theme/production-only.txt"
output="$(FIXTURE_EFFECTIVE_UID=1000 run_server production code || true)"
case "$output" in
	*'PRODUCTION_EXTRA_FILES component=code'*'PRODUCTION_EXTRA_FILE=production-only.txt'*) ;;
	*) echo 'Production-only code file did not fail closed with an exact warning' >&2; exit 1 ;;
esac
[ -f "$target_root/wp/wp-content/themes/example-theme/production-only.txt" ] || { echo 'Production-only file was removed during warning' >&2; exit 1; }

output="$(FIXTURE_EFFECTIVE_UID=1000 FIXTURE_FIND_FAIL=1 FIXTURE_FIND_FAIL_DIR="$target_root/wp/wp-content/themes/example-theme" run_server production code || true)"
case "$output" in
	*'production manifest failed'*) ;;
	*) echo 'find failure did not fail closed before replacement' >&2; exit 1 ;;
esac
[ -f "$target_root/wp/wp-content/themes/example-theme/production-only.txt" ] || { echo 'Production-only file was removed after find failure' >&2; exit 1; }

output="$(FIXTURE_EFFECTIVE_UID=1000 run_server production preflight)"
case "$output" in
	*'WordPress deployment completed (preflight)'*) ;;
	*) echo 'Non-root preflight did not complete correctly' >&2; exit 1 ;;
esac

FIXTURE_EFFECTIVE_UID=1000 run_server production code >/dev/null 2>&1 || true
[ ! -d "$target_root/lock/deploy.lock" ] || { echo 'Lock directory remained after a failed operation' >&2; exit 1; }

echo 'Remote production policy: OK'
echo 'Remote lock cleanup: OK'
echo 'Remote preflight purity: OK'
echo 'Remote WP-CLI root guard: OK'
