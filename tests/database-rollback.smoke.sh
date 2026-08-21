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
cp "$repo_dir/tests/fixtures/fake-mysql.sh" "$target_root/bin/chmod"
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

if [ "${FIXTURE_EXPECT_ROLLBACK_RETENTION:-0}" = 1 ]; then
	old_backup=1
	while [ "$old_backup" -le 11 ]; do
		printf '%s\n' 'old backup' > "$target_root/backups/db-20000101-0000${old_backup}.sql"
		old_backup=$((old_backup + 1))
	done
fi

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

if [ "${FIXTURE_FAIL_ALL_IMPORTS:-0}" = 1 ]; then
	if [ "${FIXTURE_CHMOD_FAIL:-0}" = 1 ]; then
		case "$output" in
			*'MANUAL_RECOVERY_PROTECTED_DIR_FAILED'*) ;;
			*) echo 'chmod failure diagnostic was not returned' >&2; echo "$output" >&2; exit 1 ;;
		esac
		case "$output" in *'MANUAL_RECOVERY_REQUIRED'*) ;; *) echo 'Recovery required token was not returned' >&2; exit 1 ;; esac
		recovery_backup="$(printf '%s\n' "$output" | sed -n 's/^RECOVERY_BACKUP=//p')"
		[ -n "$recovery_backup" ] && [ "$recovery_backup" != none ] && [ -s "$recovery_backup" ] || { echo 'Fallback recovery backup path was not preserved' >&2; exit 1; }
		case "$output" in *'RECOVERY_MARKER='*) echo 'Marker path must not be printed after chmod failure' >&2; exit 1 ;; esac
		case "$output" in *'RECOVERY_COMMAND='*) echo 'Fallback command must not be printed when SQL hardening fails' >&2; exit 1 ;; esac
		printf '%s\n' 'Degraded chmod recovery output: OK'
	elif [ "${FIXTURE_CHMOD_FAIL_MARKER:-0}" = 1 ]; then
		case "$output" in
			*'MANUAL_RECOVERY_MARKER_PERMISSIONS_FAILED'*) ;;
			*) echo 'Marker chmod failure diagnostic was not returned' >&2; echo "$output" >&2; exit 1 ;;
		esac
		recovery_backup="$(printf '%s\n' "$output" | sed -n 's/^RECOVERY_BACKUP=//p')"
		[ -n "$recovery_backup" ] && [ -s "$recovery_backup" ] || { echo 'Fallback recovery backup path was not preserved' >&2; exit 1; }
		case "$output" in *'RECOVERY_MARKER='*) echo 'Marker path must not be printed after marker chmod failure' >&2; exit 1 ;; esac
		case "$output" in *'RECOVERY_COMMAND='*) ;; *) echo 'Fallback recovery command was not printed' >&2; exit 1 ;; esac
		printf '%s\n' 'Degraded marker fallback: OK'
	elif [ "${FIXTURE_CORRUPT_BACKUP_ON_FIRST_IMPORT:-0}" = 1 ] && [ "${FIXTURE_CHMOD_FAIL_DIR:-0}" = 1 ]; then
		case "$output" in *'MANUAL_RECOVERY_PROTECTED_DIR_FAILED'*) ;; *) echo 'Protected-directory failure diagnostic was not returned' >&2; echo "$output" >&2; exit 1 ;; esac
		case "$output" in *'MANUAL_RECOVERY_BACKUP_REVALIDATION_FAILED'*) ;; *) echo 'Revalidation failure diagnostic was not returned on degraded path' >&2; echo "$output" >&2; exit 1 ;; esac
		recovery_backup="$(printf '%s\n' "$output" | sed -n 's/^RECOVERY_BACKUP=//p')"
		[ -n "$recovery_backup" ] && [ -s "$recovery_backup" ] || { echo 'Corrupted degraded recovery backup path was not preserved' >&2; exit 1; }
		case "$output" in *'RECOVERY_MARKER='*) echo 'Marker path must not be printed after degraded revalidation failure' >&2; exit 1 ;; esac
		case "$output" in *'RECOVERY_COMMAND='*) echo 'Fallback command must not be printed for corrupted degraded backup' >&2; exit 1 ;; esac
		printf '%s\n' 'Corrupted degraded backup recovery output: OK'
	elif [ "${FIXTURE_CORRUPT_BACKUP_ON_FIRST_IMPORT:-0}" = 1 ]; then
		case "$output" in
			*'MANUAL_RECOVERY_BACKUP_REVALIDATION_FAILED'*) ;;
			*) echo 'Revalidation failure diagnostic was not returned' >&2; echo "$output" >&2; exit 1 ;;
		esac
		recovery_backup="$(printf '%s\n' "$output" | sed -n 's/^RECOVERY_BACKUP=//p')"
		[ -n "$recovery_backup" ] && [ -s "$recovery_backup" ] || { echo 'Corrupted recovery backup path was not preserved' >&2; exit 1; }
		case "$output" in *'RECOVERY_MARKER='*) echo 'Marker path must not be printed after revalidation failure' >&2; exit 1 ;; esac
		case "$output" in *'RECOVERY_COMMAND='*) echo 'Fallback command must not be printed for corrupted backup' >&2; exit 1 ;; esac
		printf '%s\n' 'Corrupted backup recovery output: OK'
	elif [ "${FIXTURE_DELETE_BACKUP_ON_FIRST_IMPORT:-0}" = 1 ]; then
		case "$output" in *'MANUAL_RECOVERY_BACKUP_UNAVAILABLE'*) ;; *) echo 'Missing-backup diagnostic was not returned' >&2; echo "$output" >&2; exit 1 ;; esac
		case "$output" in *'RECOVERY_BACKUP=none'*) ;; *) echo 'RECOVERY_BACKUP=none was not returned' >&2; echo "$output" >&2; exit 1 ;; esac
		case "$output" in *'RECOVERY_MARKER='*) echo 'Marker path must not be printed without backup' >&2; exit 1 ;; esac
		printf '%s\n' 'Degraded missing-backup output: OK'
	else
	case "$output" in
		*'Database import failed and rollback failed; manual recovery is required'*) ;;
		*) echo "Double-failure confirmation was not returned" >&2; echo "$output" >&2; exit 1 ;;
	esac
	recovery_backup="$(printf '%s\n' "$output" | sed -n 's/^RECOVERY_BACKUP=//p')"
	recovery_marker="$(printf '%s\n' "$output" | sed -n 's/^RECOVERY_MARKER=//p')"
	[ -n "$recovery_backup" ] && [ -s "$recovery_backup" ] || { echo 'Manual recovery backup was not preserved' >&2; exit 1; }
	[ -n "$recovery_marker" ] && [ -s "$recovery_marker" ] || { echo 'Manual recovery marker was not written' >&2; exit 1; }
	case "$output" in *fixture_password*) echo 'Database password leaked in output' >&2; exit 1 ;; esac
	grep -Fq 'fixture_password' "$recovery_marker" && { echo 'Database password leaked in marker' >&2; exit 1; } || true
	grep -Fq "restore_command=$target_root/bin/php $target_root/bin/wp --path='$target_root/wp' db import '$recovery_backup'" "$recovery_marker" || { echo 'Recovery command does not use PHP and WP-CLI' >&2; exit 1; }
	grep -Fq "verify_command=$target_root/bin/php $target_root/bin/wp --path='$target_root/wp' core is-installed" "$recovery_marker" || { echo 'Recovery verification command is incomplete' >&2; exit 1; }
	grep -Fq "600 $recovery_backup" "$target_root/chmod-calls.log" || { echo 'Recovery SQL permissions were not hardened to 600' >&2; exit 1; }
	grep -Fq "600 $recovery_marker" "$target_root/chmod-calls.log" || { echo 'Recovery marker permissions were not hardened to 600' >&2; exit 1; }
	[ "$(wc -l < "$target_root/mysql-calls.log")" -eq 2 ] || { echo 'Expected import and rollback calls' >&2; exit 1; }
	printf '%s\n' 'Database double-failure manual recovery: OK'
	protected_sentinel="$target_root/backups/protected-manual-recovery-existing/db-protected.sql"
	mkdir -p "$(dirname "$protected_sentinel")"
	printf '%s\n' 'protected' > "$protected_sentinel"
	i=1
	while [ "$i" -le 12 ]; do
		printf '%s\n' 'old backup' > "$target_root/backups/db-old-$i.sql"
		i=$((i + 1))
	done
	retention_incoming="$target_root/tmp/retention-db-fixture.sql"
	cat > "$retention_incoming" <<'SQL'
-- MySQL dump 10.13  Distrib fixture
-- Table structure for table `wp_options`
CREATE TABLE `wp_options` (`option_id` bigint NOT NULL);
INSERT INTO `wp_options` VALUES (3);
SQL
	retention_output="$(
		PATH="$target_root/bin:/usr/bin:/bin" \
		FIXTURE_ROOT="$target_root" \
		FIXTURE_FAIL_ALL_IMPORTS='0' \
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
		SQL_FILE="$retention_incoming" \
		UPLOADS_ZIP='' \
		sh "$fixture_dir/server-deploy.sh" 2>&1
	)"
	case "$retention_output" in
		*'WordPress deployment completed (db)'*) ;;
		*) echo 'Retention fixture deployment did not complete' >&2; echo "$retention_output" >&2; exit 1 ;;
	esac
	[ -s "$protected_sentinel" ] || { echo 'Protected recovery backup was removed by retention' >&2; exit 1; }
	ordinary_backup_count="$(find "$target_root/backups" -type f -name 'db-*.sql*' | while IFS= read -r backup_file; do case "$backup_file" in "$target_root/backups"/db-*.sql|"$target_root/backups"/db-*.sql.gz) printf '%s\n' "$backup_file" ;; esac; done | wc -l | tr -d ' ')"
	[ "$ordinary_backup_count" -eq 10 ] || { echo "Expected 10 ordinary backups after retention, got $ordinary_backup_count" >&2; exit 1; }
	printf '%s\n' 'Protected recovery retention: OK'
	fi
else
	case "$output" in
		*'Database import failed; rollback completed'*) ;;
		*) echo "Rollback confirmation was not returned" >&2; echo "$output" >&2; exit 1 ;;
	esac
	[ "$(wc -l < "$target_root/mysql-calls.log")" -eq 2 ] || { echo 'Expected import and rollback calls' >&2; exit 1; }
	find "$target_root/backups" -type f -name 'db-*.sql' -size +0c | grep -q . || { echo 'Validated rollback backup was not preserved' >&2; exit 1; }
	if [ "${FIXTURE_EXPECT_ROLLBACK_RETENTION:-0}" = 1 ]; then
		ordinary_backup_count="$(find "$target_root/backups" -maxdepth 1 -type f -name 'db-*.sql*' | wc -l | tr -d ' ')"
		[ "$ordinary_backup_count" -eq 10 ] || { echo "Expected 10 ordinary backups after rollback retention, got $ordinary_backup_count" >&2; exit 1; }
		printf '%s\n' 'Rollback retention: OK'
	fi
	printf '%s\n' 'Database rollback after failed import: OK'
fi

[ ! -e "$incoming" ] || { echo 'Incoming SQL was not cleaned' >&2; exit 1; }
[ ! -d "$target_root/lock/deploy.lock" ] || { echo 'Lock was not cleaned' >&2; exit 1; }
