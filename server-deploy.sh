#!/usr/bin/env sh
set -eu

fail() { echo "ERROR: $1" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Required command is not available"; }

SCRIPT_DIR="$(CDPATH= cd -P "$(dirname "$0")" && pwd)"
SERVER_CONFIG="$SCRIPT_DIR/server.config.sh"
[ -f "$SERVER_CONFIG" ] || fail "Private server.config.sh is missing beside server-deploy.sh"

# This file is private, server-owned policy. Values received from the client
# must match it; the client cannot redefine the server policy.
. "$SERVER_CONFIG"

: "${SERVER_ENVIRONMENT:?SERVER_ENVIRONMENT is required in server.config.sh}"
: "${SERVER_EXPECTED_URL:?SERVER_EXPECTED_URL is required in server.config.sh}"
: "${SERVER_EXPECTED_WP_DIR:?SERVER_EXPECTED_WP_DIR is required in server.config.sh}"
: "${SERVER_EXPECTED_REPO_DIR:?SERVER_EXPECTED_REPO_DIR is required in server.config.sh}"
: "${SERVER_EXPECTED_TMP_DIR:?SERVER_EXPECTED_TMP_DIR is required in server.config.sh}"
: "${SERVER_EXPECTED_BACKUP_DIR:?SERVER_EXPECTED_BACKUP_DIR is required in server.config.sh}"
: "${SERVER_EXPECTED_DB_NAME:?SERVER_EXPECTED_DB_NAME is required in server.config.sh}"
: "${SERVER_GIT_SSH_KEY:?SERVER_GIT_SSH_KEY is required in server.config.sh}"
: "${SERVER_PHP_BIN:?SERVER_PHP_BIN is required in server.config.sh}"
: "${SERVER_WP_CLI_BIN:?SERVER_WP_CLI_BIN is required in server.config.sh}"
: "${SERVER_SYNC_PATHS:?SERVER_SYNC_PATHS is required in server.config.sh}"
: "${SERVER_KEEP_BACKUPS:?SERVER_KEEP_BACKUPS is required in server.config.sh}"
: "${SERVER_MIN_FREE_SPACE_MB:?SERVER_MIN_FREE_SPACE_MB is required in server.config.sh}"
: "${SERVER_LOCK_DIR:?SERVER_LOCK_DIR is required in server.config.sh}"

: "${ENVIRONMENT:?ENVIRONMENT is required}"
: "${REMOTE_URL:?REMOTE_URL is required}"
: "${WP_DIR:?WP_DIR is required}"
: "${REPO_DIR:?REPO_DIR is required}"
: "${BACKUP_DIR:?BACKUP_DIR is required}"
: "${EXPECTED_WP_DIR:?EXPECTED_WP_DIR is required}"
: "${EXPECTED_DB_NAME:?EXPECTED_DB_NAME is required}"
: "${EXPECTED_REMOTE_DOMAIN:?EXPECTED_REMOTE_DOMAIN is required}"
: "${SYNC_PATHS:?SYNC_PATHS is required}"
: "${GIT_SSH_KEY:?GIT_SSH_KEY is required}"
: "${MIN_REMOTE_FREE_SPACE_MB:?MIN_REMOTE_FREE_SPACE_MB is required}"

DEPLOY_MODE="${DEPLOY_MODE:-code}"
KEEP_BACKUPS="${KEEP_BACKUPS:-10}"
SQL_FILE="${SQL_FILE:-}"
UPLOADS_ZIP="${UPLOADS_ZIP:-}"
PHP_BIN="${PHP_BIN:-php}"
WP_CLI_BIN="${WP_CLI_BIN:-wp}"
timestamp="$(date +%Y%m%d-%H%M%S)"
lock_acquired=0
ARCHIVE_LISTING=''
BACKUP_FILE=''
TRANSIENT_NEW=''
TRANSIENT_OLD=''
TRANSIENT_TARGET=''
MANUAL_RECOVERY_DIR=''
MANUAL_RECOVERY_BACKUP=''
MANUAL_RECOVERY_MARKER=''
MANUAL_RECOVERY_BACKUP_HARDENED=0
MANUAL_RECOVERY_BACKUP_VALID=0

normalize_url() {
	value="$1"
	while [ "${value%/}" != "$value" ]; do value="${value%/}"; done
	printf '%s\n' "$value"
}

url_host() {
	value="${1#*://}"
	value="${value%%/*}"
	value="${value%%:*}"
	printf '%s\n' "$value"
}

assert_remote_path() {
	value="$1"
	label="$2"
	case "$value" in
		/|'') fail "$label must not be empty or root" ;;
		/*) ;;
		*) fail "$label must be an absolute POSIX path" ;;
	esac
	case "$value" in
		*/../*|*/..|*/./*|*/.) fail "$label contains an unsafe dot segment" ;;
	esac
}

assert_temp_file() {
	value="$1"
	label="$2"
	[ -z "$value" ] && return
	case "$value" in
		"$SERVER_EXPECTED_TMP_DIR"/*) ;;
		*) fail "$label is outside the server temporary directory" ;;
	esac
}

wp_cli() { "$PHP_BIN" "$WP_CLI_BIN" --path="$WP_DIR" "$@"; }
wp_config_value() { wp_cli config get "$1" --type=constant; }

assert_mode() {
	case "$DEPLOY_MODE" in preflight|code|db|full) ;; *) fail "Unknown DEPLOY_MODE" ;; esac
	if [ "$SERVER_ENVIRONMENT" = production ] && [ "$DEPLOY_MODE" != code ] && [ "$DEPLOY_MODE" != preflight ]; then
		fail "Database and uploads deployment is forbidden for production"
	fi
}

assert_server_policy() {
	case "$SERVER_ENVIRONMENT" in development|staging|production) ;; *) fail "Invalid server environment policy" ;; esac
	[ "$ENVIRONMENT" = "$SERVER_ENVIRONMENT" ] || fail "Environment does not match server policy"
	[ "$WP_DIR" = "$SERVER_EXPECTED_WP_DIR" ] || fail "WP_DIR does not match server policy"
	[ "$EXPECTED_WP_DIR" = "$SERVER_EXPECTED_WP_DIR" ] || fail "Expected WP path does not match server policy"
	[ "$REPO_DIR" = "$SERVER_EXPECTED_REPO_DIR" ] || fail "Repository path does not match server policy"
	[ "$BACKUP_DIR" = "$SERVER_EXPECTED_BACKUP_DIR" ] || fail "Backup path does not match server policy"
	[ "$EXPECTED_DB_NAME" = "$SERVER_EXPECTED_DB_NAME" ] || fail "Expected DB name does not match server policy"
	[ "$GIT_SSH_KEY" = "$SERVER_GIT_SSH_KEY" ] || fail "Git SSH key path does not match server policy"
	[ "$PHP_BIN" = "$SERVER_PHP_BIN" ] || fail "PHP path does not match server policy"
	[ "$WP_CLI_BIN" = "$SERVER_WP_CLI_BIN" ] || fail "WP-CLI path does not match server policy"
	[ "$SYNC_PATHS" = "$SERVER_SYNC_PATHS" ] || fail "Sync paths do not match server policy"
	[ "$KEEP_BACKUPS" = "$SERVER_KEEP_BACKUPS" ] || fail "Backup retention does not match server policy"
	[ "$MIN_REMOTE_FREE_SPACE_MB" = "$SERVER_MIN_FREE_SPACE_MB" ] || fail "Free-space policy does not match server policy"
	case "$SERVER_GIT_SSH_KEY" in *[!A-Za-z0-9_./-]*) fail "Server Git SSH key path contains unsafe characters" ;; esac
	case "$KEEP_BACKUPS" in ''|*[!0-9]*) fail "Backup retention must be an integer" ;; esac
	[ "$KEEP_BACKUPS" -ge 1 ] && [ "$KEEP_BACKUPS" -le 1000 ] || fail "Backup retention is outside the allowed range"
	case "$MIN_REMOTE_FREE_SPACE_MB" in ''|*[!0-9]*) fail "Minimum free space must be an integer" ;; esac
	[ "$MIN_REMOTE_FREE_SPACE_MB" -ge 1 ] && [ "$MIN_REMOTE_FREE_SPACE_MB" -le 1048576 ] || fail "Minimum free space is outside the allowed range"
	[ "$(normalize_url "$REMOTE_URL")" = "$(normalize_url "$SERVER_EXPECTED_URL")" ] || fail "Remote URL does not match server policy"
	[ "$EXPECTED_REMOTE_DOMAIN" = "$(url_host "$SERVER_EXPECTED_URL")" ] || fail "Expected domain does not match server policy"
	assert_remote_path "$WP_DIR" WP_DIR
	assert_remote_path "$REPO_DIR" REPO_DIR
	assert_remote_path "$SERVER_EXPECTED_TMP_DIR" SERVER_EXPECTED_TMP_DIR
	assert_remote_path "$BACKUP_DIR" BACKUP_DIR
	assert_remote_path "$SERVER_LOCK_DIR" SERVER_LOCK_DIR
	assert_remote_path "$PHP_BIN" PHP_BIN
	assert_remote_path "$WP_CLI_BIN" WP_CLI_BIN
	assert_temp_file "$SQL_FILE" SQL_FILE
	assert_temp_file "$UPLOADS_ZIP" UPLOADS_ZIP
}

assert_wordpress_target() {
	[ -f "$WP_DIR/wp-config.php" ] || fail "WordPress configuration was not found"
	[ -d "$WP_DIR/wp-content" ] || fail "WordPress content directory was not found"
	[ -d "$REPO_DIR/.git" ] || fail "Deployment Git repository was not found"
	[ ! -L "$WP_DIR" ] || fail "WordPress directory must not be a symbolic link"
	[ ! -L "$WP_DIR/wp-content" ] || fail "WordPress content directory must not be a symbolic link"

	actual_environment="$(wp_cli eval 'echo wp_get_environment_type();')"
	[ "$actual_environment" = "$SERVER_ENVIRONMENT" ] || fail "WordPress environment does not match server policy"

	actual_home="$(normalize_url "$(wp_cli option get home)")"
	actual_siteurl="$(normalize_url "$(wp_cli option get siteurl)")"
	expected_url="$(normalize_url "$SERVER_EXPECTED_URL")"
	[ "$actual_home" = "$expected_url" ] || fail "WordPress home URL does not match server policy"
	[ "$actual_siteurl" = "$expected_url" ] || fail "WordPress siteurl does not match server policy"

	actual_database="$(wp_config_value DB_NAME)"
	[ "$actual_database" = "$SERVER_EXPECTED_DB_NAME" ] || fail "WordPress DB name does not match server policy"
}

cleanup_exit() {
	status=$?
	trap - 0 1 2 15
	if [ -n "$SQL_FILE" ]; then
		case "$SQL_FILE" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -f "$SQL_FILE" ;; esac
	fi
	if [ -n "$UPLOADS_ZIP" ]; then
		case "$UPLOADS_ZIP" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -f "$UPLOADS_ZIP" ;; esac
	fi
	if [ -n "$ARCHIVE_LISTING" ]; then
		case "$ARCHIVE_LISTING" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -f "$ARCHIVE_LISTING" ;; esac
	fi
	if [ -n "$TRANSIENT_NEW" ]; then
		case "$TRANSIENT_NEW" in "$WP_DIR"/*) rm -rf "$TRANSIENT_NEW" ;; esac
	fi
	if [ -n "$TRANSIENT_OLD" ] && [ -n "$TRANSIENT_TARGET" ]; then
		case "$TRANSIENT_OLD:$TRANSIENT_TARGET" in
			"$WP_DIR"/*:"$WP_DIR"/*)
				if [ ! -e "$TRANSIENT_TARGET" ] && [ -e "$TRANSIENT_OLD" ]; then mv "$TRANSIENT_OLD" "$TRANSIENT_TARGET" 2>/dev/null || true
				elif [ -e "$TRANSIENT_OLD" ]; then rm -rf "$TRANSIENT_OLD"
				fi
				;;
		esac
	fi
	if [ "$lock_acquired" -eq 1 ]; then
		rm -f "$SERVER_LOCK_DIR/pid"
		rmdir "$SERVER_LOCK_DIR" 2>/dev/null || true
	fi
	exit "$status"
}
trap cleanup_exit 0 1 2 15

acquire_lock() {
	mkdir -p "$(dirname "$SERVER_LOCK_DIR")"
	if ! mkdir "$SERVER_LOCK_DIR" 2>/dev/null; then
		fail "Another deployment operation is already running"
	fi
	lock_acquired=1
	printf '%s\n' "$$" > "$SERVER_LOCK_DIR/pid"
}

cleanup_stale_temp_files() {
	mkdir -p "$SERVER_EXPECTED_TMP_DIR"
	find "$SERVER_EXPECTED_TMP_DIR" -type f \( -name 'local-db-*.sql' -o -name 'uploads-*.zip' -o -name 'uploads-*.list' \) -mtime +0 -exec rm -f {} \;
}

assert_free_space_kb() {
	require_cmd df
	require_cmd awk
	path="$1"
	extra_kb="$2"
	label="$3"
	available_kb="$(df -Pk "$path" | awk 'NR==2 { print $4 }')"
	case "$available_kb" in ''|*[!0-9]*) fail "$label free-space check failed" ;; esac
	required_kb=$((MIN_REMOTE_FREE_SPACE_MB * 1024 + extra_kb))
	[ "$available_kb" -ge "$required_kb" ] || fail "$label does not have enough free space"
}

assert_sql_dump() {
	require_cmd grep
	file="$1"
	[ -s "$file" ] || fail "SQL dump is empty or missing"
	grep -Eq '^-- (MySQL|MariaDB) dump' "$file" || fail "SQL dump header is invalid"
	grep -Eq '^(CREATE TABLE|INSERT INTO|-- Table structure for table)' "$file" || fail "SQL dump contains no table structure"
}

manual_recovery_backup_is_valid() {
	file="$1"
	[ -s "$file" ] || return 1
	grep -Eq '^-- (MySQL|MariaDB) dump' "$file" || return 1
	grep -Eq '^(CREATE TABLE|INSERT INTO|-- Table structure for table)' "$file" || return 1
}

update_repository() {
	require_cmd git
	[ -f "$SERVER_GIT_SSH_KEY" ] || fail "Server Git SSH key was not found"
	(
		cd "$REPO_DIR"
		GIT_SSH_COMMAND="ssh -i $SERVER_GIT_SSH_KEY -o IdentitiesOnly=yes" git pull --ff-only origin main
	)
}

database_connection() {
	database_host="$1"
	case "$database_host" in
		*:*)
			DB_HOST_VALUE="${database_host%%:*}"
			DB_PORT_VALUE="${database_host##*:}"
			;;
		*)
			DB_HOST_VALUE="$database_host"
			DB_PORT_VALUE=''
			;;
	esac
}

assert_sync_path() {
	relative="$1"
	case "$relative" in
		''|.|/*|*\\*|*:*) fail "Unsafe sync path" ;;
		../*|*/../*|*/..|./*|*/./*|*/.|.git|.git/*|.deploy|.deploy/*|wp-config.php) fail "Unsafe sync path" ;;
	esac
}

assert_no_symlink_components() {
	base="$1"
	relative_path="$2"
	current="$base"
	old_ifs="$IFS"
	IFS='/'
	for segment in $relative_path; do
		IFS="$old_ifs"
		current="$current/$segment"
		[ ! -L "$current" ] || fail "Sync path must not contain symbolic links"
		IFS='/'
	done
	IFS="$old_ifs"
}

copy_code() {
	require_cmd du
	canonical_wp="$(CDPATH= cd -P "$WP_DIR" && pwd)"
	old_ifs="$IFS"
	IFS=','
	for relative in $SYNC_PATHS; do
		IFS="$old_ifs"
		assert_sync_path "$relative"
		source_path="$REPO_DIR/$relative"
		target_path="$canonical_wp/$relative"
		[ -d "$source_path" ] || fail "Configured sync source was not found"
		assert_no_symlink_components "$canonical_wp" "$relative"
		case "$target_path" in "$canonical_wp"/*) ;; *) fail "Sync target escaped WordPress directory" ;; esac
		mkdir -p "$(dirname "$target_path")"
		source_kb="$(du -sk "$source_path" | awk 'NR==1 { print $1 }')"
		case "$source_kb" in ''|*[!0-9]*) fail "Code size check failed" ;; esac
		assert_free_space_kb "$WP_DIR" "$source_kb" "WordPress filesystem"
		TRANSIENT_TARGET="$target_path"
		TRANSIENT_NEW="$target_path.__new__.$timestamp"
		TRANSIENT_OLD="$target_path.__old__.$timestamp"
		rm -rf "$TRANSIENT_NEW" "$TRANSIENT_OLD"
		mkdir -p "$TRANSIENT_NEW"
		if command -v rsync >/dev/null 2>&1; then
			rsync -a "$source_path/" "$TRANSIENT_NEW/"
		else
			cp -R "$source_path/." "$TRANSIENT_NEW/"
		fi
		[ ! -e "$target_path" ] || mv "$target_path" "$TRANSIENT_OLD"
		if ! mv "$TRANSIENT_NEW" "$target_path"; then
			[ ! -e "$TRANSIENT_OLD" ] || mv "$TRANSIENT_OLD" "$target_path"
			fail "Atomic code replacement failed"
		fi
		rm -rf "$TRANSIENT_OLD"
		TRANSIENT_NEW=''; TRANSIENT_OLD=''; TRANSIENT_TARGET=''
		IFS=','
	done
	IFS="$old_ifs"
}

backup_database() {
	require_cmd mysqldump
	name="$(wp_config_value DB_NAME)"
	user="$(wp_config_value DB_USER)"
	pass="$(wp_config_value DB_PASSWORD)"
	database_connection "$(wp_config_value DB_HOST)"
	mkdir -p "$BACKUP_DIR"
	BACKUP_FILE="$BACKUP_DIR/db-$timestamp.sql"
	if [ -n "$DB_PORT_VALUE" ]; then
		MYSQL_PWD="$pass" mysqldump --host="$DB_HOST_VALUE" --port="$DB_PORT_VALUE" --user="$user" --single-transaction --quick --no-tablespaces --default-character-set=utf8mb4 "$name" > "$BACKUP_FILE"
	else
		MYSQL_PWD="$pass" mysqldump --host="$DB_HOST_VALUE" --user="$user" --single-transaction --quick --no-tablespaces --default-character-set=utf8mb4 "$name" > "$BACKUP_FILE"
	fi
	assert_sql_dump "$BACKUP_FILE"
}

mysql_import_file() {
	import_file="$1"
	if [ -n "$DB_PORT_VALUE" ]; then
		MYSQL_PWD="$pass" mysql --host="$DB_HOST_VALUE" --port="$DB_PORT_VALUE" --user="$user" "$name" < "$import_file"
	else
		MYSQL_PWD="$pass" mysql --host="$DB_HOST_VALUE" --user="$user" "$name" < "$import_file"
	fi
}

preserve_manual_recovery() {
	MANUAL_RECOVERY_MARKER=''
	MANUAL_RECOVERY_BACKUP='none'
	MANUAL_RECOVERY_BACKUP_HARDENED=0
	MANUAL_RECOVERY_BACKUP_VALID=0
	if [ -z "$BACKUP_FILE" ] || [ ! -s "$BACKUP_FILE" ]; then
		printf '%s\n' 'MANUAL_RECOVERY_BACKUP_UNAVAILABLE' >&2
		printf '%s\n' 'MANUAL_RECOVERY_REQUIRED' >&2
		printf 'RECOVERY_BACKUP=%s\n' "$MANUAL_RECOVERY_BACKUP" >&2
		return 0
	fi

	MANUAL_RECOVERY_DIR="$BACKUP_DIR/protected-manual-recovery-$timestamp"
	MANUAL_RECOVERY_BACKUP="$MANUAL_RECOVERY_DIR/db-$timestamp.sql"
	marker_path="$MANUAL_RECOVERY_DIR/RECOVERY.txt"

	if mkdir -p "$MANUAL_RECOVERY_DIR" 2>/dev/null && chmod 700 "$MANUAL_RECOVERY_DIR" 2>/dev/null && mv "$BACKUP_FILE" "$MANUAL_RECOVERY_BACKUP" 2>/dev/null; then
		BACKUP_FILE="$MANUAL_RECOVERY_BACKUP"
		if chmod 600 "$MANUAL_RECOVERY_BACKUP" 2>/dev/null; then
			MANUAL_RECOVERY_BACKUP_HARDENED=1
			if manual_recovery_backup_is_valid "$MANUAL_RECOVERY_BACKUP"; then
				MANUAL_RECOVERY_BACKUP_VALID=1
				if {
					printf '%s\n' 'status=manual-recovery-required'
					printf 'created_at=%s\n' "$timestamp"
					printf 'wp_dir=%s\n' "$WP_DIR"
					printf 'db_name=%s\n' "$name"
					printf "restore_command=%s %s --path='%s' db import '%s'\n" "$PHP_BIN" "$WP_CLI_BIN" "$WP_DIR" "$MANUAL_RECOVERY_BACKUP"
					printf "verify_command=%s %s --path='%s' core is-installed\n" "$PHP_BIN" "$WP_CLI_BIN" "$WP_DIR"
					printf '%s\n' 'Do not delete this directory until the database and site have been verified.'
				} > "$marker_path" 2>/dev/null; then
					if chmod 600 "$marker_path" 2>/dev/null; then
						MANUAL_RECOVERY_MARKER="$marker_path"
					else
						rm -f "$marker_path" 2>/dev/null || true
						printf '%s\n' 'MANUAL_RECOVERY_MARKER_PERMISSIONS_FAILED' >&2
					fi
				else
					rm -f "$marker_path" 2>/dev/null || true
					printf '%s\n' 'MANUAL_RECOVERY_MARKER_WRITE_FAILED' >&2
				fi
			else
				MANUAL_RECOVERY_MARKER=''
				MANUAL_RECOVERY_BACKUP_VALID=0
				printf '%s\n' 'MANUAL_RECOVERY_BACKUP_REVALIDATION_FAILED' >&2
			fi
		else
			printf '%s\n' 'MANUAL_RECOVERY_BACKUP_PERMISSIONS_FAILED' >&2
		fi
	else
		MANUAL_RECOVERY_BACKUP="$BACKUP_FILE"
		MANUAL_RECOVERY_MARKER=''
		rmdir "$MANUAL_RECOVERY_DIR" 2>/dev/null || true
		if chmod 600 "$BACKUP_FILE" 2>/dev/null; then
			MANUAL_RECOVERY_BACKUP_HARDENED=1
		else
			printf '%s\n' 'MANUAL_RECOVERY_BACKUP_PERMISSIONS_FAILED' >&2
		fi
		if manual_recovery_backup_is_valid "$BACKUP_FILE"; then
			MANUAL_RECOVERY_BACKUP_VALID=1
		else
			printf '%s\n' 'MANUAL_RECOVERY_BACKUP_REVALIDATION_FAILED' >&2
		fi
		printf '%s\n' 'MANUAL_RECOVERY_PROTECTED_DIR_FAILED' >&2
	fi

	printf '%s\n' 'MANUAL_RECOVERY_REQUIRED' >&2
	printf 'RECOVERY_BACKUP=%s\n' "$MANUAL_RECOVERY_BACKUP" >&2
	[ -z "$MANUAL_RECOVERY_MARKER" ] || printf 'RECOVERY_MARKER=%s\n' "$MANUAL_RECOVERY_MARKER" >&2
	if [ "$MANUAL_RECOVERY_BACKUP_HARDENED" -eq 1 ] && [ "$MANUAL_RECOVERY_BACKUP_VALID" -eq 1 ] && [ -z "$MANUAL_RECOVERY_MARKER" ] && [ "$MANUAL_RECOVERY_BACKUP" != none ] && [ -s "$MANUAL_RECOVERY_BACKUP" ]; then
		printf "RECOVERY_COMMAND=%s %s --path='%s' db import '%s'\n" "$PHP_BIN" "$WP_CLI_BIN" "$WP_DIR" "$MANUAL_RECOVERY_BACKUP" >&2
	fi
}

import_database() {
	require_cmd mysql
	assert_sql_dump "$SQL_FILE"
	name="$(wp_config_value DB_NAME)"
	user="$(wp_config_value DB_USER)"
	pass="$(wp_config_value DB_PASSWORD)"
	database_connection "$(wp_config_value DB_HOST)"
	if ! mysql_import_file "$SQL_FILE"; then
		if mysql_import_file "$BACKUP_FILE"; then
			cleanup_backups || true
			fail "Database import failed; rollback completed"
		else
			preserve_manual_recovery
			fail "Database import failed and rollback failed; manual recovery is required"
		fi
	fi
	if command -v gzip >/dev/null 2>&1; then
		gzip -f "$BACKUP_FILE"
		gzip -t "$BACKUP_FILE.gz" || fail "Compressed database backup is invalid"
	fi
}

sync_uploads() {
	[ -f "$UPLOADS_ZIP" ] || fail "Uploads archive was not found"
	require_cmd unzip
	new="$WP_DIR/wp-content/uploads.__new__"
	old="$WP_DIR/wp-content/uploads.__old__"
	current="$WP_DIR/wp-content/uploads"
	ARCHIVE_LISTING="$SERVER_EXPECTED_TMP_DIR/uploads-$timestamp.list"
	[ ! -L "$new" ] && [ ! -L "$old" ] && [ ! -L "$current" ] || fail "Uploads paths must not be symbolic links"
	unzip -tq "$UPLOADS_ZIP" >/dev/null || fail "Uploads archive integrity check failed"
	unzip -Z1 "$UPLOADS_ZIP" > "$ARCHIVE_LISTING"
	while IFS= read -r entry; do
		case "$entry" in ''|/*|../*|*/../*|*/..) fail "Uploads archive contains an unsafe path" ;; esac
	done < "$ARCHIVE_LISTING"
	rm -f "$ARCHIVE_LISTING"
	ARCHIVE_LISTING=''
	uncompressed_kb="$(unzip -l "$UPLOADS_ZIP" | awk 'END { print int(($1 + 1023) / 1024) }')"
	case "$uncompressed_kb" in ''|*[!0-9]*) fail "Uploads size check failed" ;; esac
	assert_free_space_kb "$WP_DIR" "$uncompressed_kb" "WordPress filesystem"
	rm -rf "$new" "$old"
	TRANSIENT_TARGET="$current"; TRANSIENT_NEW="$new"; TRANSIENT_OLD="$old"
	mkdir -p "$new"
	unzip -q "$UPLOADS_ZIP" -d "$new"
	find "$new" -type f -print | grep -q . || fail "Uploads archive contains no files"
	[ ! -d "$current" ] || mv "$current" "$old"
	if ! mv "$new" "$current"; then
		[ ! -d "$old" ] || mv "$old" "$current"
		fail "Atomic uploads replacement failed"
	fi
	rm -rf "$old"
	TRANSIENT_NEW=''; TRANSIENT_OLD=''; TRANSIENT_TARGET=''
}

cleanup_wordpress() {
	wp_cli search-replace "$LOCAL_URL" "$REMOTE_URL" --all-tables --precise --recurse-objects --skip-columns=guid
	wp_cli option update home "$REMOTE_URL"
	wp_cli option update siteurl "$REMOTE_URL"
	wp_cli cache flush || true
	wp_cli transient delete --all || true
	wp_cli rewrite flush --hard || true
}

cleanup_backups() {
	find "$BACKUP_DIR" -type f -name 'db-*.sql*' |
	while IFS= read -r backup_file; do
		case "$backup_file" in
			"$BACKUP_DIR"/db-*.sql|"$BACKUP_DIR"/db-*.sql.gz) printf '%s\n' "$backup_file" ;;
		esac
	done |
	sort -r | awk "NR>$KEEP_BACKUPS" | while IFS= read -r backup_file; do
		[ -z "$backup_file" ] || rm -f "$backup_file"
	done
}

assert_mode
assert_server_policy
assert_wordpress_target
acquire_lock
cleanup_stale_temp_files
mkdir -p "$BACKUP_DIR"
assert_free_space_kb "$WP_DIR" 0 "WordPress filesystem"
assert_free_space_kb "$BACKUP_DIR" 0 "Backup filesystem"

case "$DEPLOY_MODE" in
	preflight)
		require_cmd git
		[ -f "$SERVER_GIT_SSH_KEY" ] || fail "Server Git SSH key was not found"
		wp_cli --info
		;;
	code)
		update_repository
		copy_code
		;;
	db|full)
		require_cmd wc
		assert_sql_dump "$SQL_FILE"
		incoming_kb="$(wc -c < "$SQL_FILE" | awk '{ print int(($1 + 1023) / 1024) }')"
		case "$incoming_kb" in ''|*[!0-9]*) fail "Incoming SQL size check failed" ;; esac
		assert_free_space_kb "$BACKUP_DIR" "$incoming_kb" "Backup filesystem"
		if [ "$DEPLOY_MODE" = full ]; then
			update_repository
			copy_code
		fi
		backup_database
		import_database
		[ -z "$UPLOADS_ZIP" ] || sync_uploads
		cleanup_wordpress
		cleanup_backups || true
		;;
esac

echo "WordPress deployment completed ($DEPLOY_MODE)"
