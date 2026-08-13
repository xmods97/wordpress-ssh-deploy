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
	LOCAL_URL="${4-http://local.example.test}" \
	REMOTE_URL='https://example.com' \
	WP_DIR='/tmp/wordpress-ssh-deploy-fixture/wp' \
	REPO_DIR='/tmp/wordpress-ssh-deploy-fixture/repo' \
	BACKUP_DIR='/tmp/wordpress-ssh-deploy-fixture/backups' \
	EXPECTED_WP_DIR='/tmp/wordpress-ssh-deploy-fixture/wp' \
	EXPECTED_DB_NAME='wordpress_production' \
	EXPECTED_DB_TABLE_PREFIX="${5-wp_}" \
	EXPECTED_REMOTE_DOMAIN='example.com' \
	SYNC_PATHS='wp-content/themes/example-theme' \
	GIT_SSH_KEY='/tmp/wordpress-ssh-deploy-fixture/id_ed25519' \
	PHP_BIN='/tmp/wordpress-ssh-deploy-fixture/bin/php' \
	WP_CLI_BIN='/tmp/wordpress-ssh-deploy-fixture/bin/wp' \
	KEEP_BACKUPS='10' \
	MIN_REMOTE_FREE_SPACE_MB='1' \
	SQL_FILE="${3:-}" \
	DEPLOY_MODE="$2" \
	sh "$fixture_dir/server-deploy.sh" 2>&1
}

check_local_url_rejection() {
	value="$1"
	expected="$2"
	output="$(run_server production code '' "$value" || true)"
	case "$output" in
		*"$expected"*) ;;
		*) echo "LOCAL_URL validation failed for: $value" >&2; exit 1 ;;
	esac
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

output="$(run_server production code '' 'http://local.example.test' 'other_' || true)"
case "$output" in
	*'Expected table prefix does not match server policy'*) ;;
	*) echo 'Client table-prefix mismatch was not rejected correctly' >&2; exit 1 ;;
esac

check_local_url_rejection '' 'LOCAL_URL is required'
check_local_url_rejection 'ftp://example.test' 'must be an absolute HTTP or HTTPS URL'
check_local_url_rejection 'http://exa mple.test' 'must not contain whitespace'
check_local_url_rejection 'http://exa;mple.test' 'host contains unsafe characters'

mkdir -p "$target_root/wp/wp-content" "$target_root/repo/.git" "$target_root/tmp" "$target_root/backups" "$target_root/bin"
: > "$target_root/wp/wp-config.php"
: > "$target_root/id_ed25519"
cp "$repo_dir/tests/fixtures/fake-php.sh" "$target_root/bin/php"
: > "$target_root/bin/wp"

output="$(FIXTURE_TABLE_PREFIX='other_' run_server production code || true)"
case "$output" in
	*'WordPress table prefix does not match server policy'*) ;;
	*) echo 'WordPress table-prefix mismatch was not rejected correctly' >&2; exit 1 ;;
esac

canary="$target_root/outside-canary"
printf '%s\n' 'must-survive' > "$canary"
run_server production bogus "$target_root/tmp/../outside-canary" >/dev/null 2>&1 || true
[ -f "$canary" ] || {
	echo 'Cleanup removed a temporary-file canary outside the server temporary directory' >&2
	exit 1
}

run_server production code >/dev/null 2>&1 || true
[ ! -d "$target_root/lock/deploy.lock" ] || {
	echo 'Lock directory remained after a failed operation' >&2
	exit 1
}

echo 'Remote production policy: OK'
echo 'Remote lock cleanup: OK'

# Review regression probes: exercise policy and protected-path checks before any
# repository or database work can happen. The fake git command makes code mode
# reach copy_code without contacting a remote.
review_root="$target_root/review"
mkdir -p "$review_root/bin"
cp "$repo_dir/server-deploy.sh" "$review_root/server-deploy.sh"
sed -e "s/^SERVER_ENVIRONMENT=.*/SERVER_ENVIRONMENT='staging'/" \
	-e "s/^SERVER_SYNC_PATHS=.*/SERVER_SYNC_PATHS='wp-config.php'/" \
	-e "s#^SERVER_GIT_SSH_KEY=.*#SERVER_GIT_SSH_KEY='$target_root/id_ed25519'#" \
	"$repo_dir/tests/fixtures/server.config.production.sh" > "$review_root/server.config.sh"
printf '%s\n' "SERVER_PROTECTED_PATHS='wp-config.php'" >> "$review_root/server.config.sh"
# Reuse an executable fixture that exits successfully; no network operation is
# needed because the policy mismatch is rejected before repository work.
cp "$repo_dir/tests/fixtures/fake-df.sh" "$review_root/bin/git"
cp "$repo_dir/tests/fixtures/fake-df.sh" "$review_root/bin/du"
cp "$repo_dir/tests/fixtures/fake-df.sh" "$review_root/bin/df"
: > "$target_root/repo/wp-config.php"

review_run() {
	SYNC_PATHS="$1" \
	FULL_SYNC_PATHS="$2" \
	PROTECTED_PATHS="${5-}" \
	REPLACE_PROTECTED="$3" \
	DEPLOY_MODE="$4" \
	ENVIRONMENT='staging' \
	LOCAL_URL='http://local.example.test' \
	REMOTE_URL='https://example.com' \
	WP_DIR="$target_root/wp" \
	REPO_DIR="$target_root/repo" \
	BACKUP_DIR="$target_root/backups" \
	EXPECTED_WP_DIR="$target_root/wp" \
	EXPECTED_DB_NAME='wordpress_production' \
	EXPECTED_DB_TABLE_PREFIX='wp_' \
	EXPECTED_REMOTE_DOMAIN='example.com' \
	GIT_SSH_KEY="$target_root/id_ed25519" \
	PHP_BIN="$target_root/bin/php" \
	WP_CLI_BIN="$target_root/bin/wp" \
	KEEP_BACKUPS='10' \
	MIN_REMOTE_FREE_SPACE_MB='1' \
	PATH="$review_root/bin:/usr/bin:/bin" \
	FIXTURE_ENVIRONMENT='staging' \
	sh "$review_root/server-deploy.sh" 2>&1
}

output="$(review_run 'wrong-path' 'wp-config.php' 0 full || true)"
case "$output" in
	*'Sync paths do not match server policy'*) ;;
	*) echo 'Full deploy did not validate ordinary sync paths' >&2; exit 1 ;;
esac

output="$(review_run 'wp-config.php' 'wp-config.php' 0 preflight || true)"
case "$output" in
	*'WordPress deployment completed (preflight)'*) ;;
	*) echo 'Ordinary preflight was blocked by declared protected paths' >&2; exit 1 ;;
esac

output="$(review_run 'wp-config.php' 'wp-config.php' 1 code 'wp-config.php' || true)"
case "$output" in
	*'Protected path is not allowed in ordinary sync paths'*) ;;
	*) echo 'Protected path escaped ordinary code sync' >&2; exit 1 ;;
esac

echo 'Server full-policy and protected-path guards: OK'
