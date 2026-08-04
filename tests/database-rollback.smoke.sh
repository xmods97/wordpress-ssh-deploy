#!/usr/bin/env sh
set -eu

repo_dir="$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)"
fixture_dir="${TMPDIR:-/tmp}/wordpress-ssh-deploy-rollback-test-$$"
target_root='/tmp/wordpress-ssh-deploy-staging-fixture'
mkdir -p "$fixture_dir"
trap 'rm -rf "$fixture_dir" "$target_root"' 0 1 2 15

cp "$repo_dir/server-deploy.sh" "$fixture_dir/server-deploy.sh"
cp "$repo_dir/tests/fixtures/server.config.staging.sh" "$fixture_dir/server.config.sh"
mkdir -p "$target_root/wp/wp-content" "$target_root/repo/.git" "$target_root/tmp" "$target_root/backups" "$target_root/bin"
: > "$target_root/wp/wp-config.php"
: > "$target_root/id_ed25519"
: > "$target_root/bin/wp"
cp "$repo_dir/tests/fixtures/fake-php.sh" "$target_root/bin/php"
cp "$repo_dir/tests/fixtures/fake-mysqldump.sh" "$target_root/bin/mysqldump"
cp "$repo_dir/tests/fixtures/fake-mysql.sh" "$target_root/bin/mysql"
cp "$repo_dir/tests/fixtures/fake-df.sh" "$target_root/bin/df"

incoming="$target_root/tmp/local-db-fixture.sql"
cat > "$incoming" <<'SQL'
-- MySQL dump 10.13  Distrib fixture
--
-- Table structure for table `wp_options`
CREATE TABLE `wp_options` (`option_id` bigint NOT NULL);
INSERT INTO `wp_options` VALUES (2);
-- INCOMING_FAIL
SQL

output="$(
	PATH="$target_root/bin:/usr/bin:/bin" \
	FIXTURE_ROOT="$target_root" \
	FIXTURE_ENVIRONMENT='staging' \
	FIXTURE_URL='https://staging.example.com' \
	FIXTURE_DB_NAME='wordpress_staging' \
	ENVIRONMENT='staging' \
	LOCAL_URL='http://example.test' \
	REMOTE_URL='https://staging.example.com' \
	WP_DIR="$target_root/wp" \
	REPO_DIR="$target_root/repo" \
	BACKUP_DIR="$target_root/backups" \
	EXPECTED_WP_DIR="$target_root/wp" \
	EXPECTED_DB_NAME='wordpress_staging' \
	EXPECTED_REMOTE_DOMAIN='staging.example.com' \
	SYNC_PATHS='wp-content/themes/example-theme' \
	GIT_SSH_KEY="$target_root/id_ed25519" \
	PHP_BIN="$target_root/bin/php" \
	WP_CLI_BIN="$target_root/bin/wp" \
	KEEP_BACKUPS='10' \
	MIN_REMOTE_FREE_SPACE_MB='1' \
	DEPLOY_MODE='db' \
	SQL_FILE="$incoming" \
	UPLOADS_ZIP='' \
	sh "$fixture_dir/server-deploy.sh" 2>&1 || true
)"

case "$output" in
	*'Database import failed; rollback completed'*) ;;
	*) echo "Rollback confirmation was not returned" >&2; echo "$output" >&2; exit 1 ;;
esac

[ "$(wc -l < "$target_root/mysql-calls.log")" -eq 2 ] || { echo 'Expected import and rollback calls' >&2; exit 1; }
[ ! -e "$incoming" ] || { echo 'Incoming SQL was not cleaned' >&2; exit 1; }
[ ! -d "$target_root/lock/deploy.lock" ] || { echo 'Lock was not cleaned' >&2; exit 1; }
find "$target_root/backups" -type f -name 'db-*.sql' -size +0c | grep -q . || { echo 'Validated rollback backup was not preserved' >&2; exit 1; }

echo 'Database rollback after failed import: OK'
