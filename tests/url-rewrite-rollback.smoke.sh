#!/usr/bin/env sh
set -eu

repo_dir="$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)"
fixture_dir="${TMPDIR:-/tmp}/wordpress-ssh-deploy-url-rewrite-test-$$"
target_root="${TMPDIR:-/tmp}/wordpress-ssh-deploy-staging-fixture-$$"
mkdir -p "$fixture_dir"
cleanup_fixture() { status=$?; trap - 0 1 2 15; rm -rf "$fixture_dir" "$target_root"; exit "$status"; }
trap cleanup_fixture 0 1 2 15

setup_fixture() {
	rm -rf "$target_root"
	cp "$repo_dir/server-deploy.sh" "$fixture_dir/server-deploy.sh"
	sed "s|/tmp/wordpress-ssh-deploy-staging-fixture|$target_root|g" "$repo_dir/tests/fixtures/server.config.staging.sh" > "$fixture_dir/server.config.sh"
	mkdir -p "$target_root/wp/wp-content/themes/example-theme" "$target_root/repo/.git" "$target_root/tmp" "$target_root/backups" "$target_root/bin"
	: > "$target_root/wp/wp-config.php"
	: > "$target_root/id_ed25519"
	: > "$target_root/bin/wp"
	cp "$repo_dir/tests/fixtures/fake-php.sh" "$target_root/bin/php"
	cp "$repo_dir/tests/fixtures/fake-id.sh" "$target_root/bin/id"
	cp "$repo_dir/tests/fixtures/fake-stat.sh" "$target_root/bin/stat"
	cp "$repo_dir/tests/fixtures/fake-chown.sh" "$target_root/bin/chown"
	cp "$repo_dir/tests/fixtures/fake-mysqldump.sh" "$target_root/bin/mysqldump"
	cp "$repo_dir/tests/fixtures/fake-mysql.sh" "$target_root/bin/mysql"
	cp "$repo_dir/tests/fixtures/fake-df.sh" "$target_root/bin/df"
	cp "$repo_dir/tests/fixtures/fake-du.sh" "$target_root/bin/du"
	cat > "$target_root/tmp/local-db-fixture.sql" <<'SQL'
-- MySQL dump 10.13  Distrib fixture
-- Table structure for table `wp_options`
CREATE TABLE `wp_options` (`option_id` bigint NOT NULL);
INSERT INTO `wp_options` VALUES (2);
SQL
}

run_deploy() {
	PATH="$target_root/bin:/usr/bin:/bin" FIXTURE_ROOT="$target_root" FIXTURE_ENVIRONMENT='staging' \
	FIXTURE_URL='https://staging.example.com' FIXTURE_DB_NAME='wordpress_staging' FIXTURE_EFFECTIVE_UID='1000' \
	FIXTURE_FAIL_URL_REWRITE="${FIXTURE_FAIL_URL_REWRITE:-0}" FIXTURE_REWRITE_DRY_RUN_REMAINING="${FIXTURE_REWRITE_DRY_RUN_REMAINING:-0}" \
	ENVIRONMENT='staging' LOCAL_URL='http://example.test' REMOTE_URL='https://staging.example.com' \
	WP_DIR="$target_root/wp" REPO_DIR="$target_root/repo" BACKUP_DIR="$target_root/backups" EXPECTED_WP_DIR="$target_root/wp" \
	EXPECTED_DB_NAME='wordpress_staging' EXPECTED_REMOTE_DOMAIN='staging.example.com' SYNC_PATHS='wp-content/themes/example-theme' \
	PLUGIN_SYNC_PATHS='' GIT_SSH_KEY="$target_root/id_ed25519" PHP_BIN="$target_root/bin/php" WP_CLI_BIN="$target_root/bin/wp" \
	KEEP_BACKUPS='10' MIN_REMOTE_FREE_SPACE_MB='1' ALLOWED_DEPLOY_MODES='preflight,code,db,code-db,uploads,plugins,full' \
	DEPLOY_MODE='db' SQL_FILE="$target_root/tmp/local-db-fixture.sql" UPLOADS_ZIP='' sh "$fixture_dir/server-deploy.sh" 2>&1 || true
}

assert_common_rollback() {
	[ "$(wc -l < "$target_root/mysql-calls.log")" -eq 2 ] || { echo 'Expected import and rollback calls' >&2; exit 1; }
	find "$target_root/backups" -maxdepth 1 -type f -name 'db-*.sql' -size +0c | grep -q . || { echo 'Rollback backup was not preserved' >&2; exit 1; }
	[ ! -e "$target_root/tmp/local-db-fixture.sql" ] || { echo 'Incoming SQL was not cleaned' >&2; exit 1; }
	[ ! -d "$target_root/lock/deploy.lock" ] || { echo 'Lock was not cleaned' >&2; exit 1; }
}

setup_fixture; FIXTURE_FAIL_URL_REWRITE=1; export FIXTURE_FAIL_URL_REWRITE
output="$(run_deploy)"; case "$output" in *'URL rewrite failed; rollback completed'*) ;; *) echo "$output" >&2; exit 1 ;; esac; assert_common_rollback

setup_fixture; unset FIXTURE_FAIL_URL_REWRITE; FIXTURE_REWRITE_DRY_RUN_REMAINING=1; export FIXTURE_REWRITE_DRY_RUN_REMAINING
output="$(run_deploy)"; case "$output" in *'URL rewrite verification failed; rollback completed'*) ;; *) echo "$output" >&2; exit 1 ;; esac; assert_common_rollback

setup_fixture; unset FIXTURE_REWRITE_DRY_RUN_REMAINING
output="$(run_deploy)"; case "$output" in *'WordPress deployment completed (db)'*) ;; *) echo "$output" >&2; exit 1 ;; esac
[ "$(wc -l < "$target_root/mysql-calls.log")" -eq 1 ] || { echo 'Successful rewrite unexpectedly rolled back' >&2; exit 1; }
grep -F -- '--all-tables-with-prefix' "$target_root/php-calls.log" >/dev/null
grep -F -- '--skip-columns=guid' "$target_root/php-calls.log" >/dev/null
grep -F -- '--dry-run --format=count' "$target_root/php-calls.log" >/dev/null

printf '%s\n' 'URL rewrite rollback: OK'
