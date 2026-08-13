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
: "${SERVER_EXPECTED_DB_TABLE_PREFIX:?SERVER_EXPECTED_DB_TABLE_PREFIX is required in server.config.sh}"
: "${SERVER_GIT_SSH_KEY:?SERVER_GIT_SSH_KEY is required in server.config.sh}"
: "${SERVER_PHP_BIN:?SERVER_PHP_BIN is required in server.config.sh}"
: "${SERVER_WP_CLI_BIN:?SERVER_WP_CLI_BIN is required in server.config.sh}"
: "${SERVER_SYNC_PATHS:?SERVER_SYNC_PATHS is required in server.config.sh}"
: "${SERVER_FULL_SYNC_PATHS:=${SERVER_SYNC_PATHS}}"
: "${SERVER_PROTECTED_PATHS:=}"
: "${SERVER_ALLOW_PRODUCTION_PULL:=0}"
: "${SERVER_KEEP_BACKUPS:?SERVER_KEEP_BACKUPS is required in server.config.sh}"
: "${SERVER_MIN_FREE_SPACE_MB:?SERVER_MIN_FREE_SPACE_MB is required in server.config.sh}"
: "${SERVER_LOCK_DIR:?SERVER_LOCK_DIR is required in server.config.sh}"

: "${ENVIRONMENT:?ENVIRONMENT is required}"
: "${LOCAL_URL:?LOCAL_URL is required}"
: "${REMOTE_URL:?REMOTE_URL is required}"
: "${WP_DIR:?WP_DIR is required}"
: "${REPO_DIR:?REPO_DIR is required}"
: "${BACKUP_DIR:?BACKUP_DIR is required}"
: "${EXPECTED_WP_DIR:?EXPECTED_WP_DIR is required}"
: "${EXPECTED_DB_NAME:?EXPECTED_DB_NAME is required}"
: "${EXPECTED_DB_TABLE_PREFIX:?EXPECTED_DB_TABLE_PREFIX is required}"
: "${EXPECTED_REMOTE_DOMAIN:?EXPECTED_REMOTE_DOMAIN is required}"
: "${SYNC_PATHS:?SYNC_PATHS is required}"
: "${FULL_SYNC_PATHS:=${SYNC_PATHS}}"
: "${GIT_SSH_KEY:?GIT_SSH_KEY is required}"
: "${MIN_REMOTE_FREE_SPACE_MB:?MIN_REMOTE_FREE_SPACE_MB is required}"

DEPLOY_MODE="${DEPLOY_MODE:-code}"
KEEP_BACKUPS="${KEEP_BACKUPS:-10}"
SQL_FILE="${SQL_FILE:-}"
UPLOADS_ZIP="${UPLOADS_ZIP:-}"
PULL_ARTIFACT="${PULL_ARTIFACT:-}"
PULL_PATHS="${PULL_PATHS:-}"
PROTECTED_PATHS="${PROTECTED_PATHS:-}"
REPLACE_PROTECTED="${REPLACE_PROTECTED:-0}"
PROTECTED_ARCHIVE="${PROTECTED_ARCHIVE:-}"
ALLOW_PRODUCTION_PULL="${ALLOW_PRODUCTION_PULL:-0}"
PHP_BIN="${PHP_BIN:-php}"
WP_CLI_BIN="${WP_CLI_BIN:-wp}"
timestamp="$(date +%Y%m%d-%H%M%S)"
lock_acquired=0
ARCHIVE_LISTING=''
BACKUP_FILE=''
TRANSIENT_NEW=''
TRANSIENT_OLD=''
TRANSIENT_TARGET=''
PROTECTED_STAGE=''
protected_backup=''

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

assert_http_url() {
	value="$1"
	label="$2"
	case "$value" in
		http://*|https://*) ;;
		*) fail "$label must be an absolute HTTP or HTTPS URL" ;;
	esac
	case "$value" in
		*[[:space:]]*) fail "$label must not contain whitespace" ;;
	esac
	host="$(url_host "$value")"
	[ -n "$host" ] || fail "$label must contain a host"
	case "$host" in
		*[!A-Za-z0-9.-]*) fail "$label host contains unsafe characters" ;;
	esac
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
	assert_remote_path "$value" "$label"
	case "$value" in
		"$SERVER_EXPECTED_TMP_DIR"/*) ;;
		*) fail "$label is outside the server temporary directory" ;;
	esac
}

wp_cli() { "$PHP_BIN" "$WP_CLI_BIN" --path="$WP_DIR" "$@"; }
wp_config_value() { wp_cli config get "$1" --type=constant; }
wp_config_variable() { wp_cli config get "$1" --type=variable; }

assert_table_prefix() {
	value="$1"
	label="$2"
	case "$value" in ''|*[!A-Za-z0-9_]*) fail "$label contains unsupported characters" ;; esac
}

assert_mode() {
	case "$DEPLOY_MODE" in preflight|code|db|full|pull-db|pull-files) ;; *) fail "Unknown DEPLOY_MODE" ;; esac
	if [ "$SERVER_ENVIRONMENT" = production ]; then
		case "$DEPLOY_MODE" in
			pull-db|pull-files) [ "$ALLOW_PRODUCTION_PULL" = 1 ] || fail "Production pull requires explicit read-only opt-in" ;;
		esac
	fi
	if [ "$SERVER_ENVIRONMENT" = production ] && [ "$DEPLOY_MODE" != code ] && [ "$DEPLOY_MODE" != preflight ] && [ "$DEPLOY_MODE" != pull-db ] && [ "$DEPLOY_MODE" != pull-files ]; then
		fail "Database and uploads deployment is forbidden for production"
	fi
}

# Pull paths are WordPress-relative and must stay inside WP_DIR. The client applies the
# same rules, so a mismatch here means the request did not come from this tool.
assert_pull_path() {
	value="$1"
	case "$value" in
		''|/*) fail "Pull path must be a non-empty relative path" ;;
		*../*|*/..|../*|..) fail "Pull path contains an unsafe dot segment" ;;
		./*|*/./*) fail "Pull path contains an unsafe dot segment" ;;
		*\\*|*:*) fail "Pull path contains unsupported characters" ;;
		*[[:space:]]*) fail "Pull path must not contain whitespace" ;;
		wp-config*|.git|.git/*|.env|.env/*|.ssh|.ssh/*) fail "Pull path is permanently excluded" ;;
		*/.git|*/.git/*|*/.ssh|*/.ssh/*|*/.env|*/.env/*) fail "Pull path is permanently excluded" ;;
		*.pem|*.key|*id_rsa|*id_ed25519) fail "Pull path is permanently excluded" ;;
		wp-content/cache|wp-content/cache/*|wp-content/upgrade|wp-content/upgrade/*) fail "Pull path is permanently excluded" ;;
		wp-content/backup|wp-content/backup/*|wp-content/backups|wp-content/backups/*) fail "Pull path is permanently excluded" ;;
	esac
}

assert_server_policy() {
	case "$SERVER_ENVIRONMENT" in development|staging|production) ;; *) fail "Invalid server environment policy" ;; esac
	[ "$ENVIRONMENT" = "$SERVER_ENVIRONMENT" ] || fail "Environment does not match server policy"
	[ "$WP_DIR" = "$SERVER_EXPECTED_WP_DIR" ] || fail "WP_DIR does not match server policy"
	[ "$EXPECTED_WP_DIR" = "$SERVER_EXPECTED_WP_DIR" ] || fail "Expected WP path does not match server policy"
	[ "$REPO_DIR" = "$SERVER_EXPECTED_REPO_DIR" ] || fail "Repository path does not match server policy"
	[ "$BACKUP_DIR" = "$SERVER_EXPECTED_BACKUP_DIR" ] || fail "Backup path does not match server policy"
	[ "$EXPECTED_DB_NAME" = "$SERVER_EXPECTED_DB_NAME" ] || fail "Expected DB name does not match server policy"
	[ "$EXPECTED_DB_TABLE_PREFIX" = "$SERVER_EXPECTED_DB_TABLE_PREFIX" ] || fail "Expected table prefix does not match server policy"
	[ "$GIT_SSH_KEY" = "$SERVER_GIT_SSH_KEY" ] || fail "Git SSH key path does not match server policy"
	[ "$PHP_BIN" = "$SERVER_PHP_BIN" ] || fail "PHP path does not match server policy"
	[ "$WP_CLI_BIN" = "$SERVER_WP_CLI_BIN" ] || fail "WP-CLI path does not match server policy"
	[ "$SYNC_PATHS" = "$SERVER_SYNC_PATHS" ] || fail "Sync paths do not match server policy"
	[ "$FULL_SYNC_PATHS" = "$SERVER_FULL_SYNC_PATHS" ] || fail "Full sync paths do not match server policy"
	case "$ALLOW_PRODUCTION_PULL" in 0|1) ;; *) fail "ALLOW_PRODUCTION_PULL must be 0 or 1" ;; esac
	if [ "$DEPLOY_MODE" = pull-db ] || [ "$DEPLOY_MODE" = pull-files ]; then
		[ "$ALLOW_PRODUCTION_PULL" = "$SERVER_ALLOW_PRODUCTION_PULL" ] || fail "Production pull permission does not match server policy"
	fi
	if [ "$DEPLOY_MODE" = full ]; then ACTIVE_SYNC_PATHS="$FULL_SYNC_PATHS"; else ACTIVE_SYNC_PATHS="$SYNC_PATHS"; fi
	server_protected_paths="$SERVER_PROTECTED_PATHS"
	if [ "$REPLACE_PROTECTED" = 1 ]; then
		[ "$PROTECTED_PATHS" = "$server_protected_paths" ] || fail "Protected paths do not match server policy"
	else
		[ -z "$PROTECTED_PATHS" ] || fail "Protected paths require explicit replacement confirmation"
	fi
	[ "$KEEP_BACKUPS" = "$SERVER_KEEP_BACKUPS" ] || fail "Backup retention does not match server policy"
	[ "$MIN_REMOTE_FREE_SPACE_MB" = "$SERVER_MIN_FREE_SPACE_MB" ] || fail "Free-space policy does not match server policy"
	case "$SERVER_GIT_SSH_KEY" in *[!A-Za-z0-9_./-]*) fail "Server Git SSH key path contains unsafe characters" ;; esac
	case "$KEEP_BACKUPS" in ''|*[!0-9]*) fail "Backup retention must be an integer" ;; esac
	[ "$KEEP_BACKUPS" -ge 1 ] && [ "$KEEP_BACKUPS" -le 1000 ] || fail "Backup retention is outside the allowed range"
	case "$MIN_REMOTE_FREE_SPACE_MB" in ''|*[!0-9]*) fail "Minimum free space must be an integer" ;; esac
	[ "$MIN_REMOTE_FREE_SPACE_MB" -ge 1 ] && [ "$MIN_REMOTE_FREE_SPACE_MB" -le 1048576 ] || fail "Minimum free space is outside the allowed range"
	[ "$(normalize_url "$REMOTE_URL")" = "$(normalize_url "$SERVER_EXPECTED_URL")" ] || fail "Remote URL does not match server policy"
	assert_http_url "$LOCAL_URL" LOCAL_URL
	assert_table_prefix "$SERVER_EXPECTED_DB_TABLE_PREFIX" SERVER_EXPECTED_DB_TABLE_PREFIX
	assert_table_prefix "$EXPECTED_DB_TABLE_PREFIX" EXPECTED_DB_TABLE_PREFIX
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
	assert_temp_file "$PROTECTED_ARCHIVE" PROTECTED_ARCHIVE
	assert_temp_file "$PULL_ARTIFACT" PULL_ARTIFACT
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
	actual_table_prefix="$(wp_config_variable table_prefix)"
	[ "$actual_table_prefix" = "$SERVER_EXPECTED_DB_TABLE_PREFIX" ] || fail "WordPress table prefix does not match server policy"
}

cleanup_exit() {
	status=$?
	trap - 0 1 2 15
	if [ -n "$SQL_FILE" ]; then
		assert_temp_file "$SQL_FILE" SQL_FILE
		rm -f "$SQL_FILE"
	fi
	if [ -n "$UPLOADS_ZIP" ]; then
		assert_temp_file "$UPLOADS_ZIP" UPLOADS_ZIP
		rm -f "$UPLOADS_ZIP"
	fi
	if [ -n "$PROTECTED_ARCHIVE" ]; then
		assert_temp_file "$PROTECTED_ARCHIVE" PROTECTED_ARCHIVE
		rm -f "$PROTECTED_ARCHIVE"
	fi
	if [ -n "$ARCHIVE_LISTING" ]; then
		assert_temp_file "$ARCHIVE_LISTING" ARCHIVE_LISTING
		rm -f "$ARCHIVE_LISTING"
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
	if [ -n "$PROTECTED_STAGE" ]; then
		case "$PROTECTED_STAGE" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -rf "$PROTECTED_STAGE" ;; esac
	fi
	if [ "$lock_acquired" -eq 1 ]; then
		rm -f "$SERVER_LOCK_DIR/pid"
		rmdir "$SERVER_LOCK_DIR" 2>/dev/null || true
	fi
	exit "$status"
}

assert_temp_file "$SQL_FILE" SQL_FILE
assert_temp_file "$UPLOADS_ZIP" UPLOADS_ZIP
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
	find "$SERVER_EXPECTED_TMP_DIR" -type f \( -name 'local-db-*.sql' -o -name 'uploads-*.zip' -o -name 'uploads-*.list' -o -name 'protected-*.zip' -o -name 'protected-*.list' -o -name 'pull-db-*.sql.gz' -o -name 'pull-files-*.tar.gz' \) -mtime +0 -exec rm -f {} \;
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

assert_sql_dump_table_prefix() {
	file="$1"
	prefix="$2"
	awk -v prefix="$prefix" '
		/^CREATE TABLE( IF NOT EXISTS)? `/ {
			found=1
			table=$0
			sub(/^CREATE TABLE( IF NOT EXISTS)? `/, "", table)
			sub(/`.*/, "", table)
			if (index(table, prefix) != 1) invalid=1
		}
		END { exit (!found || invalid) }
	' "$file" || fail "SQL dump table prefix does not match server policy"
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
	case ",$SERVER_PROTECTED_PATHS," in *",$relative,"*) fail "Protected path is not allowed in ordinary sync paths" ;; esac
	case "$relative" in
		''|.|/*|*\\*|*:*) fail "Unsafe sync path" ;;
		../*|*/../*|*/..|./*|*/./*|*/.|.git|.git/*|.deploy|.deploy/*) fail "Unsafe sync path" ;;
		wp-config.php|.env|*.pem|*.key|*id_rsa|*id_ed25519)
			fail "Protected path is not allowed in ordinary sync paths"
			;;
	esac
}

assert_protected_path() {
	value="$1"
	case "$value" in
		''|/*|*../*|*/..|../*|./*|*/./*|*\\*|*:*) fail "Unsafe protected path" ;;
	esac
	case ",$SERVER_PROTECTED_PATHS," in *",$value,"*) ;; *) fail "Protected path was not declared by policy" ;; esac
	[ "$REPLACE_PROTECTED" = 1 ] || fail "Protected replacement requires explicit confirmation"
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
	for relative in $ACTIVE_SYNC_PATHS; do
		IFS="$old_ifs"
		assert_sync_path "$relative"
		source_path="$REPO_DIR/$relative"
		target_path="$canonical_wp/$relative"
		[ -e "$source_path" ] || fail "Configured sync source was not found: $relative"
		[ ! -L "$source_path" ] || fail "Configured sync source must not be a symbolic link: $relative"
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
		if [ -d "$source_path" ]; then
			mkdir -p "$TRANSIENT_NEW"
			if command -v rsync >/dev/null 2>&1; then
				rsync -a "$source_path/" "$TRANSIENT_NEW/"
			else
				cp -R "$source_path/." "$TRANSIENT_NEW/"
			fi
		else
			cp -p "$source_path" "$TRANSIENT_NEW"
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

stage_protected_files() {
	[ "$REPLACE_PROTECTED" = 1 ] || return 0
	[ "$DEPLOY_MODE" = full ] || fail "Protected replacement is allowed only for full deploy"
	[ -n "$PROTECTED_ARCHIVE" ] || fail "Protected archive is required for protected replacement"
	require_cmd unzip
	unzip -tq "$PROTECTED_ARCHIVE" >/dev/null || fail "Protected archive integrity check failed"
	PROTECTED_STAGE="$SERVER_EXPECTED_TMP_DIR/protected-$timestamp"
	rm -rf "$PROTECTED_STAGE"
	mkdir -p "$PROTECTED_STAGE"
	ARCHIVE_LISTING="$SERVER_EXPECTED_TMP_DIR/protected-$timestamp.list"
	unzip -Z1 "$PROTECTED_ARCHIVE" > "$ARCHIVE_LISTING"
	entry_count=0
	while IFS= read -r entry; do
		case "$entry" in
			'') continue ;;
			*/) continue ;;
		esac
		assert_protected_path "$entry"
		entry_count=$((entry_count + 1))
	done < "$ARCHIVE_LISTING"
	[ "$entry_count" -gt 0 ] || fail "Protected archive contains no files"
	unzip -q "$PROTECTED_ARCHIVE" -d "$PROTECTED_STAGE" || fail "Protected archive extraction failed"
	if [ -n "$(find "$PROTECTED_STAGE" -type l -print)" ]; then
		fail "Protected archive contains a symbolic link"
	fi
	old_ifs="$IFS"
	IFS=','
	for relative in $PROTECTED_PATHS; do
		IFS="$old_ifs"
		[ -f "$PROTECTED_STAGE/$relative" ] || fail "Protected archive is missing declared file: $relative"
		IFS=','
	done
	IFS="$old_ifs"
	rm -f "$ARCHIVE_LISTING"
	ARCHIVE_LISTING=''
}

backup_protected_files() {
	[ "$REPLACE_PROTECTED" = 1 ] || return 0
	[ "$DEPLOY_MODE" = full ] || fail "Protected replacement is allowed only for full deploy"
	[ -n "$PROTECTED_PATHS" ] || fail "Protected replacement requires protected paths"
	protected_backup="$BACKUP_DIR/protected-$timestamp"
	mkdir -p "$protected_backup"
	old_ifs="$IFS"
	IFS=','
	for relative in $PROTECTED_PATHS; do
		IFS="$old_ifs"
		assert_protected_path "$relative"
		source_path="$PROTECTED_STAGE/$relative"
		target_path="$WP_DIR/$relative"
		[ -f "$source_path" ] || fail "Protected source file was not found in archive: $relative"
		[ -f "$target_path" ] || fail "Protected target file was not found on server: $relative"
		assert_no_symlink_components "$WP_DIR" "$relative"
		[ ! -L "$target_path" ] || fail "Protected target file must not be a symbolic link: $relative"
		mkdir -p "$protected_backup/$(dirname "$relative")"
		cp -p "$target_path" "$protected_backup/$relative" || fail "Protected backup failed: $relative"
		IFS=','
	done
	IFS="$old_ifs"
	printf 'PROTECTED_BACKUP_READY %s\n' "$protected_backup"
}

copy_protected_files() {
	[ "$REPLACE_PROTECTED" = 1 ] || return 0
	old_ifs="$IFS"
	IFS=','
	for relative in $PROTECTED_PATHS; do
		IFS="$old_ifs"
		assert_protected_path "$relative"
		source_path="$PROTECTED_STAGE/$relative"
		target_path="$WP_DIR/$relative"
		new_path="$target_path.__new__.$timestamp"
		old_path="$target_path.__old__.$timestamp"
		mkdir -p "$(dirname "$target_path")"
		TRANSIENT_TARGET="$target_path"
		TRANSIENT_NEW="$new_path"
		TRANSIENT_OLD="$old_path"
		cp -p "$source_path" "$new_path" || fail "Protected file staging failed: $relative"
		mv "$target_path" "$old_path" || { restore_protected_files; fail "Protected file backup swap failed: $relative"; }
		if ! mv "$new_path" "$target_path"; then
			restore_protected_files
			fail "Protected file replacement failed: $relative"
		fi
		rm -f "$old_path"
		TRANSIENT_NEW=''; TRANSIENT_OLD=''; TRANSIENT_TARGET=''
		IFS=','
	done
	IFS="$old_ifs"
}

restore_protected_files() {
	[ -n "${protected_backup:-}" ] || return 0
	old_ifs="$IFS"
	IFS=','
	for relative in $PROTECTED_PATHS; do
		IFS="$old_ifs"
		[ -f "$protected_backup/$relative" ] || continue
		mkdir -p "$(dirname "$WP_DIR/$relative")"
		cp -p "$protected_backup/$relative" "$WP_DIR/$relative" || true
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

backup_database_for_pull() {
	require_cmd mysqldump
	require_cmd awk
	name="$(wp_config_value DB_NAME)"
	user="$(wp_config_value DB_USER)"
	pass="$(wp_config_value DB_PASSWORD)"
	database_connection "$(wp_config_value DB_HOST)"
	active_tables_raw="$(wp_cli db tables --all-tables-with-prefix --format=csv)" || fail "Could not determine active WordPress tables"
	active_tables="$(printf '%s\n' "$active_tables_raw" | awk -F',' '{ for (i = 1; i <= NF; i++) { gsub(/\r/, "", $i); if ($i != "" && $i != "table" && $i != "name" && $i != "table_name") print $i } }')"
	[ -n "$active_tables" ] || fail "Active WordPress table list is empty"
	old_ifs="$IFS"
	IFS='
'
	set -- $active_tables
	IFS="$old_ifs"
	[ "$#" -gt 0 ] || fail "Active WordPress table list is empty"
	for table in "$@"; do
		case "$table" in
			''|*[!A-Za-z0-9_]*) fail "Active table list contains an unsafe identifier" ;;
		esac
		case "$table" in
			"$SERVER_EXPECTED_DB_TABLE_PREFIX"*) ;;
			*) fail "Active table list contains a table outside server policy" ;;
		esac
	done
	mkdir -p "$BACKUP_DIR"
	BACKUP_FILE="$BACKUP_DIR/db-$timestamp.sql"
	if [ -n "$DB_PORT_VALUE" ]; then
		MYSQL_PWD="$pass" mysqldump --host="$DB_HOST_VALUE" --port="$DB_PORT_VALUE" --user="$user" --single-transaction --quick --no-tablespaces --default-character-set=utf8mb4 "$name" "$@" > "$BACKUP_FILE"
	else
		MYSQL_PWD="$pass" mysqldump --host="$DB_HOST_VALUE" --user="$user" --single-transaction --quick --no-tablespaces --default-character-set=utf8mb4 "$name" "$@" > "$BACKUP_FILE"
	fi
	assert_sql_dump "$BACKUP_FILE"
}

# Pull export: read-only with respect to WordPress. It creates a backup and a compressed
# copy for transfer, and never imports or touches the site.
export_database_for_pull() {
	require_cmd gzip
	require_cmd wc
	[ -n "$PULL_ARTIFACT" ] || fail "PULL_ARTIFACT is required for pull-db"
	backup_database_for_pull
	assert_sql_dump_table_prefix "$BACKUP_FILE" "$SERVER_EXPECTED_DB_TABLE_PREFIX"
	gzip -c "$BACKUP_FILE" > "$PULL_ARTIFACT" || fail "Pull artifact could not be compressed"
	gzip -t "$PULL_ARTIFACT" || fail "Pull artifact failed its gzip integrity check"
	[ -s "$PULL_ARTIFACT" ] || fail "Pull artifact is empty"
	cleanup_backups
	printf 'PULL_ARTIFACT_READY %s %s\n' "$PULL_ARTIFACT" "$(wc -c < "$PULL_ARTIFACT" | tr -d ' ')"
}

export_files_for_pull() {
	require_cmd tar
	require_cmd gzip
	require_cmd wc
	[ -n "$PULL_ARTIFACT" ] || fail "PULL_ARTIFACT is required for pull-files"
	[ -n "$PULL_PATHS" ] || fail "PULL_PATHS is required for pull-files"
	old_ifs="$IFS"
	IFS=','
	# shellcheck disable=SC2086
	set -- $PULL_PATHS
	IFS="$old_ifs"
	[ "$#" -gt 0 ] || fail "PULL_PATHS is required for pull-files"
	for pull_path in "$@"; do
		assert_pull_path "$pull_path"
		[ -e "$WP_DIR/$pull_path" ] || fail "Pull path does not exist on the server"
		assert_no_symlink_components "$WP_DIR" "$pull_path"
	done
	tar -czf "$PULL_ARTIFACT" -C "$WP_DIR" \
		--exclude='.git' --exclude='.env' --exclude='.ssh' \
		--exclude='wp-config*' --exclude='*.pem' --exclude='*.key' \
		--exclude='id_rsa*' --exclude='id_ed25519*' \
		-- "$@" || fail "Pull archive could not be created"
	gzip -t "$PULL_ARTIFACT" || fail "Pull artifact failed its gzip integrity check"
	[ -s "$PULL_ARTIFACT" ] || fail "Pull artifact is empty"
	printf 'PULL_ARTIFACT_READY %s %s\n' "$PULL_ARTIFACT" "$(wc -c < "$PULL_ARTIFACT" | tr -d ' ')"
}

mysql_import_file() {
	import_file="$1"
	if [ -n "$DB_PORT_VALUE" ]; then
		MYSQL_PWD="$pass" mysql --host="$DB_HOST_VALUE" --port="$DB_PORT_VALUE" --user="$user" "$name" < "$import_file"
	else
		MYSQL_PWD="$pass" mysql --host="$DB_HOST_VALUE" --user="$user" "$name" < "$import_file"
	fi
}

import_database() {
	require_cmd mysql
	assert_sql_dump "$SQL_FILE"
	assert_sql_dump_table_prefix "$SQL_FILE" "$SERVER_EXPECTED_DB_TABLE_PREFIX"
	name="$(wp_config_value DB_NAME)"
	user="$(wp_config_value DB_USER)"
	pass="$(wp_config_value DB_PASSWORD)"
	database_connection "$(wp_config_value DB_HOST)"
	if ! mysql_import_file "$SQL_FILE"; then
		if mysql_import_file "$BACKUP_FILE"; then fail "Database import failed; rollback completed"
		else fail "Database import failed and rollback failed"
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
	find "$BACKUP_DIR" -maxdepth 1 -type f -name 'db-*.sql*' | sort -r | awk "NR>$KEEP_BACKUPS" | while IFS= read -r backup_file; do
		[ -z "$backup_file" ] || rm -f -- "$backup_file"
	done
	find "$BACKUP_DIR" -maxdepth 1 -type d -name 'protected-*' | sort -r | awk "NR>$KEEP_BACKUPS" | while IFS= read -r backup_dir; do
		[ -z "$backup_dir" ] || rm -rf -- "$backup_dir"
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
		assert_sql_dump_table_prefix "$SQL_FILE" "$SERVER_EXPECTED_DB_TABLE_PREFIX"
		incoming_kb="$(wc -c < "$SQL_FILE" | awk '{ print int(($1 + 1023) / 1024) }')"
		case "$incoming_kb" in ''|*[!0-9]*) fail "Incoming SQL size check failed" ;; esac
		assert_free_space_kb "$BACKUP_DIR" "$incoming_kb" "Backup filesystem"
		if [ "$DEPLOY_MODE" = full ]; then
			update_repository
			stage_protected_files
			backup_protected_files
			copy_code
		fi
		backup_database
		import_database
		[ -z "$UPLOADS_ZIP" ] || sync_uploads
		cleanup_wordpress
		[ "$DEPLOY_MODE" = full ] && copy_protected_files
		cleanup_backups
		;;
	pull-db)
		export_database_for_pull
		;;
	pull-files)
		export_files_for_pull
		;;
esac

case "$DEPLOY_MODE" in
	pull-db|pull-files) echo "WordPress pull export completed ($DEPLOY_MODE)" ;;
	*) echo "WordPress deployment completed ($DEPLOY_MODE)" ;;
esac
