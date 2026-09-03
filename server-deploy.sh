#!/usr/bin/env sh
set -eu

# The forced root wrapper intentionally starts commands with this exact
# minimal PATH. Extend only that trusted value with standard system admin
# directories so root-owned utilities such as runuser remain available.
case "${PATH:-}" in
	/usr/bin:/bin) PATH=/usr/bin:/bin:/usr/sbin:/sbin ;;
esac
export PATH

fail() { echo "ERROR: $1" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"; }

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
: "${SERVER_PLUGIN_SYNC_PATHS:=}"
: "${SERVER_MU_PLUGIN_SYNC_PATHS:=}"
if [ -z "${SERVER_ALLOWED_DEPLOY_MODES+x}" ]; then
	case "$SERVER_ENVIRONMENT" in
		production) SERVER_ALLOWED_DEPLOY_MODES='preflight,code,full' ;;
		development|staging) SERVER_ALLOWED_DEPLOY_MODES='preflight,code,db,full' ;;
		*) SERVER_ALLOWED_DEPLOY_MODES='' ;;
	esac
fi
[ -n "$SERVER_ALLOWED_DEPLOY_MODES" ] || fail "SERVER_ALLOWED_DEPLOY_MODES must not be empty"
: "${SERVER_KEEP_BACKUPS:?SERVER_KEEP_BACKUPS is required in server.config.sh}"
: "${SERVER_MIN_FREE_SPACE_MB:?SERVER_MIN_FREE_SPACE_MB is required in server.config.sh}"
: "${SERVER_LOCK_DIR:?SERVER_LOCK_DIR is required in server.config.sh}"

# Git source policy is private server configuration, never client input.
SERVER_GIT_REMOTE="${SERVER_GIT_REMOTE:-origin}"
SERVER_GIT_BRANCH="${SERVER_GIT_BRANCH:-main}"
SERVER_GIT_SSH_PORT="${SERVER_GIT_SSH_PORT:-22}"

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
PLUGIN_SYNC_PATHS="${PLUGIN_SYNC_PATHS:-}"
MU_PLUGIN_SYNC_PATHS="${MU_PLUGIN_SYNC_PATHS:-}"
ALLOWED_DEPLOY_MODES="${ALLOWED_DEPLOY_MODES:-}"
PRODUCTION_FULL_OPT_IN="${PRODUCTION_FULL_OPT_IN:-0}"
KEEP_BACKUPS="${KEEP_BACKUPS:-10}"
SQL_FILE="${SQL_FILE:-}"
UPLOADS_ZIP="${UPLOADS_ZIP:-}"
UPLOADS_DELTA_ZIP="${UPLOADS_DELTA_ZIP:-}"
UPLOADS_MANIFEST_FILE="${UPLOADS_MANIFEST_FILE:-}"
UPLOADS_MANIFEST_PATH="$BACKUP_DIR/uploads-manifest.tsv"
UPLOADS_TRANSACTION_LOG="$BACKUP_DIR/uploads-transactions.log"
PHP_BIN="${PHP_BIN:-php}"
WP_CLI_BIN="${WP_CLI_BIN:-wp}"
timestamp="$(date +%Y%m%d-%H%M%S)"
lock_acquired=0
cleanup_artifacts=0
database_mutation_active=0
ARCHIVE_LISTING=''
BACKUP_FILE=''
TRANSIENT_NEW=''
TRANSIENT_OLD=''
TRANSIENT_TARGET=''
TRANSIENT_REPLACED=0
TRANSIENT_COMMITTED=0
CANONICAL_WP_DIR="$WP_DIR"
SITE_OWNER=''
SITE_GROUP=''
SITE_UID=''
GIT_SSH_WRAPPER=''
MYSQL_DEFAULTS_FILE=''
MANUAL_RECOVERY_DIR=''
MANUAL_RECOVERY_BACKUP=''
MANUAL_RECOVERY_MARKER=''
MANUAL_RECOVERY_BACKUP_HARDENED=0
MANUAL_RECOVERY_BACKUP_VALID=0
UPLOADS_DELTA_STAGE=''
UPLOADS_MANIFEST_NEW=''
UPLOADS_MANIFEST_OLD=''
UPLOADS_MANIFEST_REPLACED=0
UPLOADS_TRANSACTION_LOG_NEW=''
UPLOADS_TRANSACTION_LOG_OLD=''
UPLOADS_TRANSACTION_LOG_REPLACED=0
UPLOADS_TRANSACTION_KIND='full'
COMPONENT_SOURCE_MANIFEST=''
COMPONENT_TARGET_MANIFEST=''
COMPONENT_EXTRAS_MANIFEST=''
COMPONENT_SOURCE_RAW=''
COMPONENT_TARGET_RAW=''

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

wp_cli() {
	case "$(id -u)" in
		0) "$PHP_BIN" "$WP_CLI_BIN" --allow-root --path="$WP_DIR" "$@" ;;
		*) "$PHP_BIN" "$WP_CLI_BIN" --path="$WP_DIR" "$@" ;;
	esac
}

is_safe_owner_component() {
	value="$1"
	[ -n "$value" ] || return 1
	case "$value" in
		root|-*|*[!A-Za-z0-9_.@+-]*) return 1 ;;
	esac
}

discover_site_owner() {
	SITE_OWNER="$(stat -c '%U' "$WP_DIR/wp-content")" || { printf '%s\n' 'ERROR: Could not determine WordPress content owner' >&2; return 1; }
	SITE_GROUP="$(stat -c '%G' "$WP_DIR/wp-content")" || { printf '%s\n' 'ERROR: Could not determine WordPress content group' >&2; return 1; }
	SITE_UID="$(stat -c '%u' "$WP_DIR/wp-content")" || { printf '%s\n' 'ERROR: Could not determine WordPress content owner UID' >&2; return 1; }
	is_safe_owner_component "$SITE_OWNER" || { printf '%s\n' 'ERROR: WordPress content owner is unsafe' >&2; return 1; }
	is_safe_owner_component "$SITE_GROUP" || { printf '%s\n' 'ERROR: WordPress content group is unsafe' >&2; return 1; }
	case "$SITE_UID" in ''|*[!0-9]*) printf '%s\n' 'ERROR: WordPress content owner UID is invalid' >&2; return 1 ;; esac
	[ "$SITE_UID" -ne 0 ] || { printf '%s\n' 'ERROR: WordPress content owner must not be root' >&2; return 1; }
}

assert_runtime_cache_ownership_prerequisites() {
	case "$(id -u)" in
		0)
			require_cmd stat
			require_cmd chown
			require_cmd runuser
			discover_site_owner || fail "Runtime cache ownership prerequisites failed"
			;;
	esac
}

normalize_divi_runtime_cache_ownership() {
	case "$(id -u)" in
		0) ;;
		*) return 0 ;;
	esac

	discover_site_owner || return 1
	runtime_cache_dir="$WP_DIR/wp-content/et-cache"
	[ ! -L "$runtime_cache_dir" ] || { printf '%s\n' 'ERROR: Divi runtime cache directory must not be a symbolic link' >&2; return 1; }
	[ -e "$runtime_cache_dir" ] || return 0
	[ -d "$runtime_cache_dir" ] || { printf '%s\n' 'ERROR: Divi runtime cache path is not a directory' >&2; return 1; }
	chown -R -- "$SITE_OWNER:$SITE_GROUP" "$runtime_cache_dir" || { printf '%s\n' 'ERROR: Divi runtime cache ownership normalization failed' >&2; return 1; }
}

wp_cli_as_site_owner() {
	case "$(id -u)" in
		0)
			discover_site_owner || return 1
			runuser -u "$SITE_OWNER" -g "$SITE_GROUP" -- "$PHP_BIN" "$WP_CLI_BIN" --path="$WP_DIR" "$@"
			;;
		*) wp_cli "$@" ;;
	esac
}

wp_cli_manual_prefix() {
	case "$(id -u)" in
		0) printf "%s %s --allow-root --path='%s'" "$PHP_BIN" "$WP_CLI_BIN" "$WP_DIR" ;;
		*) printf "%s %s --path='%s'" "$PHP_BIN" "$WP_CLI_BIN" "$WP_DIR" ;;
	esac
}

wp_config_value() { wp_cli config get "$1" --type=constant; }

assert_mode() {
	case "$DEPLOY_MODE" in preflight|code|db|code-db|uploads|plugins|mu-plugins|full) ;; *) fail "Unknown DEPLOY_MODE" ;; esac
	case ",$ALLOWED_DEPLOY_MODES," in *,$DEPLOY_MODE,*) ;; *) fail "Deploy mode is not enabled by profile policy" ;; esac
	case ",$SERVER_ALLOWED_DEPLOY_MODES," in *,$DEPLOY_MODE,*) ;; *) fail "Deploy mode is not enabled by server policy" ;; esac
	case "$PRODUCTION_FULL_OPT_IN" in 0|1) ;; *) fail "Invalid production full-mode client opt-in" ;; esac
	case "${SERVER_ALLOW_PRODUCTION_FULL:-0}" in 0|1) ;; *) fail "Invalid server production full-mode policy" ;; esac
	if [ "$SERVER_ENVIRONMENT" = production ]; then
		case "$DEPLOY_MODE" in
			preflight|code|db|code-db|uploads|plugins|mu-plugins) ;;
			full)
				[ "$PRODUCTION_FULL_OPT_IN" = 1 ] || fail "Production full mode requires an explicit client profile opt-in"
				[ "${SERVER_ALLOW_PRODUCTION_FULL:-0}" = 1 ] || fail "Production full mode is disabled by server policy"
				;;
		esac
	fi
	if [ "$DEPLOY_MODE" = plugins ] && [ -z "$PLUGIN_SYNC_PATHS" ]; then
		fail "Plugins mode requires configured plugin sync paths"
	fi
	if [ "$DEPLOY_MODE" = mu-plugins ] && [ -z "$MU_PLUGIN_SYNC_PATHS" ]; then
		fail "Mu-plugins mode requires configured mu-plugin sync paths"
	fi
}

assert_allowed_modes_subset() {
	requested="$1"
	allowed="$2"
	old_ifs="$IFS"
	IFS=','
	for mode in $requested; do
		IFS="$old_ifs"
		case "$mode" in preflight|code|db|code-db|uploads|plugins|mu-plugins|full) ;; *) fail "Invalid profile deploy mode policy" ;; esac
		case ",$allowed," in *,$mode,*) ;; *) fail "Profile deploy mode is outside server policy" ;; esac
		IFS=','
	done
	IFS="$old_ifs"
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
	[ "$PLUGIN_SYNC_PATHS" = "$SERVER_PLUGIN_SYNC_PATHS" ] || fail "Plugin sync paths do not match server policy"
	[ "$MU_PLUGIN_SYNC_PATHS" = "$SERVER_MU_PLUGIN_SYNC_PATHS" ] || fail "Mu-plugin sync paths do not match server policy"
	assert_allowed_modes_subset "$ALLOWED_DEPLOY_MODES" "$SERVER_ALLOWED_DEPLOY_MODES"
	[ "$KEEP_BACKUPS" = "$SERVER_KEEP_BACKUPS" ] || fail "Backup retention does not match server policy"
	[ "$MIN_REMOTE_FREE_SPACE_MB" = "$SERVER_MIN_FREE_SPACE_MB" ] || fail "Free-space policy does not match server policy"
	case "$SERVER_GIT_SSH_KEY" in *[!A-Za-z0-9_./-]*) fail "Server Git SSH key path contains unsafe characters" ;; esac
	case "$SERVER_GIT_REMOTE" in ''|*[!A-Za-z0-9._-]*) fail "Server Git remote contains unsafe characters" ;; esac
	case "$SERVER_GIT_BRANCH" in ''|/*|*..*|*//*|*[!A-Za-z0-9._/-]*) fail "Server Git branch contains unsafe characters" ;; esac
	case "$SERVER_GIT_SSH_PORT" in ''|*[!0-9]*) fail "Server Git SSH port must be an integer" ;; esac
	[ "$SERVER_GIT_SSH_PORT" -ge 1 ] && [ "$SERVER_GIT_SSH_PORT" -le 65535 ] || fail "Server Git SSH port is outside the allowed range"
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
	assert_temp_file "$UPLOADS_DELTA_ZIP" UPLOADS_DELTA_ZIP
	assert_temp_file "$UPLOADS_MANIFEST_FILE" UPLOADS_MANIFEST_FILE
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
	if [ "$status" -ne 0 ] && [ "$database_mutation_active" -eq 1 ] && [ -n "$BACKUP_FILE" ] && [ -s "$BACKUP_FILE" ]; then
		if rollback_database_or_require_manual_recovery; then
			printf '%s\n' 'AUTOMATIC_DATABASE_ROLLBACK=completed' >&2
		else
			printf '%s\n' 'AUTOMATIC_DATABASE_ROLLBACK=failed; manual recovery is required' >&2
		fi
		database_mutation_active=0
	fi
	if [ "$cleanup_artifacts" -eq 1 ]; then
		if [ -n "$SQL_FILE" ]; then
			case "$SQL_FILE" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -f "$SQL_FILE" 2>/dev/null || true ;; esac
		fi
		if [ -n "$UPLOADS_ZIP" ]; then
			case "$UPLOADS_ZIP" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -f "$UPLOADS_ZIP" 2>/dev/null || true ;; esac
		fi
		if [ -n "$UPLOADS_DELTA_ZIP" ]; then
			case "$UPLOADS_DELTA_ZIP" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -f "$UPLOADS_DELTA_ZIP" 2>/dev/null || true ;; esac
		fi
		if [ -n "$UPLOADS_MANIFEST_FILE" ]; then
			case "$UPLOADS_MANIFEST_FILE" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -f "$UPLOADS_MANIFEST_FILE" 2>/dev/null || true ;; esac
		fi
		if [ -n "$UPLOADS_DELTA_STAGE" ]; then
			case "$UPLOADS_DELTA_STAGE" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -rf "$UPLOADS_DELTA_STAGE" 2>/dev/null || true ;; esac
		fi
		if [ -n "$UPLOADS_MANIFEST_NEW" ]; then
			case "$UPLOADS_MANIFEST_NEW" in "$BACKUP_DIR"/*) rm -f "$UPLOADS_MANIFEST_NEW" 2>/dev/null || true ;; esac
		fi
		if [ "$UPLOADS_MANIFEST_REPLACED" -eq 1 ] && [ "$TRANSIENT_COMMITTED" -eq 0 ]; then
			if [ -n "$UPLOADS_MANIFEST_OLD" ] && [ -e "$UPLOADS_MANIFEST_OLD" ]; then
				mv -f "$UPLOADS_MANIFEST_OLD" "$UPLOADS_MANIFEST_PATH" 2>/dev/null || true
			else
				rm -f "$UPLOADS_MANIFEST_PATH" 2>/dev/null || true
			fi
			UPLOADS_MANIFEST_OLD=''
			UPLOADS_MANIFEST_REPLACED=0
		fi
		if [ -n "$UPLOADS_MANIFEST_OLD" ]; then
			case "$UPLOADS_MANIFEST_OLD" in "$BACKUP_DIR"/*) rm -f "$UPLOADS_MANIFEST_OLD" 2>/dev/null || true ;; esac
		fi
		if [ -n "$UPLOADS_TRANSACTION_LOG_NEW" ]; then
			case "$UPLOADS_TRANSACTION_LOG_NEW" in "$BACKUP_DIR"/*) rm -f "$UPLOADS_TRANSACTION_LOG_NEW" 2>/dev/null || true ;; esac
		fi
		if [ "$UPLOADS_TRANSACTION_LOG_REPLACED" -eq 1 ] && [ "$TRANSIENT_COMMITTED" -eq 0 ]; then
			if [ -n "$UPLOADS_TRANSACTION_LOG_OLD" ] && [ -e "$UPLOADS_TRANSACTION_LOG_OLD" ]; then
				mv -f "$UPLOADS_TRANSACTION_LOG_OLD" "$UPLOADS_TRANSACTION_LOG" 2>/dev/null || true
			else
				rm -f "$UPLOADS_TRANSACTION_LOG" 2>/dev/null || true
			fi
			UPLOADS_TRANSACTION_LOG_OLD=''
			UPLOADS_TRANSACTION_LOG_REPLACED=0
		fi
		if [ -n "$UPLOADS_TRANSACTION_LOG_OLD" ]; then
			case "$UPLOADS_TRANSACTION_LOG_OLD" in "$BACKUP_DIR"/*) rm -f "$UPLOADS_TRANSACTION_LOG_OLD" 2>/dev/null || true ;; esac
		fi
		if [ -n "$ARCHIVE_LISTING" ]; then
			case "$ARCHIVE_LISTING" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -f "$ARCHIVE_LISTING" 2>/dev/null || true ;; esac
		fi
		if [ -n "$GIT_SSH_WRAPPER" ]; then
			case "$GIT_SSH_WRAPPER" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -f "$GIT_SSH_WRAPPER" 2>/dev/null || true ;; esac
		fi
		if [ -n "$COMPONENT_SOURCE_MANIFEST" ]; then
			case "$COMPONENT_SOURCE_MANIFEST" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -f "$COMPONENT_SOURCE_MANIFEST" 2>/dev/null || true ;; esac
		fi
		if [ -n "$COMPONENT_TARGET_MANIFEST" ]; then
			case "$COMPONENT_TARGET_MANIFEST" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -f "$COMPONENT_TARGET_MANIFEST" 2>/dev/null || true ;; esac
		fi
		if [ -n "$COMPONENT_EXTRAS_MANIFEST" ]; then
			case "$COMPONENT_EXTRAS_MANIFEST" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -f "$COMPONENT_EXTRAS_MANIFEST" 2>/dev/null || true ;; esac
		fi
		if [ -n "$COMPONENT_SOURCE_RAW" ]; then
			case "$COMPONENT_SOURCE_RAW" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -f "$COMPONENT_SOURCE_RAW" 2>/dev/null || true ;; esac
		fi
		if [ -n "$COMPONENT_TARGET_RAW" ]; then
			case "$COMPONENT_TARGET_RAW" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -f "$COMPONENT_TARGET_RAW" 2>/dev/null || true ;; esac
		fi
		if [ -n "$MYSQL_DEFAULTS_FILE" ]; then
			case "$MYSQL_DEFAULTS_FILE" in "$SERVER_EXPECTED_TMP_DIR"/*) rm -f "$MYSQL_DEFAULTS_FILE" 2>/dev/null || true ;; esac
		fi
		if [ -n "$TRANSIENT_NEW" ]; then
			case "$TRANSIENT_NEW" in "$WP_DIR"/*|"$CANONICAL_WP_DIR"/*) rm -rf "$TRANSIENT_NEW" 2>/dev/null || true ;; esac
		fi
		if [ -n "$TRANSIENT_TARGET" ]; then
			case "$TRANSIENT_TARGET" in
				"$WP_DIR"/*|"$CANONICAL_WP_DIR"/*)
					if [ "$TRANSIENT_REPLACED" -eq 1 ] && [ "$TRANSIENT_COMMITTED" -eq 0 ]; then
						if restore_transient_target; then
							printf '%s\n' 'AUTOMATIC_CODE_ROLLBACK=completed' >&2
						else
							printf '%s\n' 'AUTOMATIC_CODE_ROLLBACK=failed; manual recovery is required' >&2
						fi
					elif [ "$TRANSIENT_REPLACED" -eq 0 ] && [ -n "$TRANSIENT_OLD" ] && [ -e "$TRANSIENT_OLD" ]; then
						if [ ! -e "$TRANSIENT_TARGET" ]; then mv "$TRANSIENT_OLD" "$TRANSIENT_TARGET" 2>/dev/null || true
						else rm -rf "$TRANSIENT_OLD" 2>/dev/null || true
						fi
					fi
					;;
			esac
		fi
		if [ "$lock_acquired" -eq 1 ]; then
			rm -f "$SERVER_LOCK_DIR/pid" 2>/dev/null || true
			rmdir "$SERVER_LOCK_DIR" 2>/dev/null || true
		fi
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
	find "$SERVER_EXPECTED_TMP_DIR" -type f \( -name 'local-db-*.sql' -o -name 'uploads-*.zip' -o -name 'uploads-delta-*.zip' -o -name 'uploads-manifest-*.tsv' -o -name 'uploads-*.list' \) -mtime +0 -exec rm -f {} \;
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
	[ -d "$SERVER_EXPECTED_TMP_DIR" ] || fail "Server temporary directory was not found"
	GIT_SSH_WRAPPER="$SERVER_EXPECTED_TMP_DIR/.git-ssh-wrapper.$$"
	[ ! -e "$GIT_SSH_WRAPPER" ] || fail "Temporary Git SSH wrapper path already exists"
	(
		umask 077
		printf '%s\n' '#!/bin/sh' "exec /usr/bin/ssh -p '$SERVER_GIT_SSH_PORT' -i '$SERVER_GIT_SSH_KEY' -o IdentitiesOnly=yes \"\$@\"" > "$GIT_SSH_WRAPPER"
	)
	chmod 700 "$GIT_SSH_WRAPPER"
	(
		cd "$REPO_DIR"
		[ -z "$(git status --porcelain)" ] || fail "Deployment Git repository has local changes"
		GIT_SSH="$GIT_SSH_WRAPPER" git fetch "$SERVER_GIT_REMOTE" "$SERVER_GIT_BRANCH"
		if git show-ref --verify --quiet "refs/heads/$SERVER_GIT_BRANCH"; then
			GIT_SSH="$GIT_SSH_WRAPPER" git checkout "$SERVER_GIT_BRANCH"
		else
			GIT_SSH="$GIT_SSH_WRAPPER" git checkout -b "$SERVER_GIT_BRANCH" FETCH_HEAD
		fi
		GIT_SSH="$GIT_SSH_WRAPPER" git pull --ff-only "$SERVER_GIT_REMOTE" "$SERVER_GIT_BRANCH"
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

create_mysql_defaults_file() {
	[ -n "$MYSQL_DEFAULTS_FILE" ] && return 0
	MYSQL_DEFAULTS_FILE="$SERVER_EXPECTED_TMP_DIR/.mysql-client.$$.cnf"
	[ ! -e "$MYSQL_DEFAULTS_FILE" ] || fail "Temporary MySQL credentials path already exists"
	require_cmd sed
	escaped_pass="$(printf '%s' "$pass" | sed 's/[\\"]/\\&/g')"
	(
		umask 077
		printf '%s\n' '[client]' "user=$user" "password=\"$escaped_pass\"" "host=$DB_HOST_VALUE" > "$MYSQL_DEFAULTS_FILE"
		if [ -n "$DB_PORT_VALUE" ]; then
			printf '%s\n' "port=$DB_PORT_VALUE" >> "$MYSQL_DEFAULTS_FILE"
		elif [ "$DB_HOST_VALUE" = 'localhost' ]; then
			printf '%s\n' 'protocol=socket' >> "$MYSQL_DEFAULTS_FILE"
		fi
	)
	escaped_pass=''
}

assert_sync_path() {
	relative="$1"
	component="$2"
	case "$relative" in
		''|.|*/|/*|*\\*|*:*) fail "Unsafe sync path" ;;
		../*|*/../*|*/..|./*|*/./*|*/.|.git|.git/*|.deploy|.deploy/*|wp-config.php) fail "Unsafe sync path" ;;
	esac
	case "$component" in
		code)
			case "$relative" in
				wp-content/themes/Divi|wp-content/themes/Divi/*) fail "Divi requires a separate site-specific policy" ;;
				wp-content/themes/*) ;;
				*) fail "Code sync path must be inside wp-content/themes" ;;
			esac
			;;
		plugins)
			case "$relative" in wp-content/plugins/*) ;; *) fail "Plugin sync path must be inside wp-content/plugins" ;; esac
			;;
		mu-plugins)
			case "$relative" in wp-content/mu-plugins/*) ;; *) fail "Mu-plugin sync path must be inside wp-content/mu-plugins" ;; esac
			;;
		*) fail "Unknown sync component" ;;
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

# Stop before a managed directory replacement can delete regular files that
# exist only on production. The exact list is printed for explicit review.
assert_no_production_extra_files() {
	source_path="$1"
	target_path="$2"
	component_label="$3"
	[ -d "$source_path" ] || return 0
	[ -e "$target_path" ] || return 0
	[ -d "$target_path" ] || fail "$component_label production target is not a directory"
	require_cmd find
	require_cmd sort
	require_cmd comm
	COMPONENT_SOURCE_MANIFEST="$SERVER_EXPECTED_TMP_DIR/.component-source.$$.manifest"
	COMPONENT_TARGET_MANIFEST="$SERVER_EXPECTED_TMP_DIR/.component-target.$$.manifest"
	COMPONENT_EXTRAS_MANIFEST="$SERVER_EXPECTED_TMP_DIR/.component-extra.$$.manifest"
	COMPONENT_SOURCE_RAW="$SERVER_EXPECTED_TMP_DIR/.component-source.$$.raw"
	COMPONENT_TARGET_RAW="$SERVER_EXPECTED_TMP_DIR/.component-target.$$.raw"
	(
		cd "$source_path" || exit 1
		find . -type f -print > "$COMPONENT_SOURCE_RAW"
		LC_ALL=C sed 's#^\./##' "$COMPONENT_SOURCE_RAW" | LC_ALL=C sort > "$COMPONENT_SOURCE_MANIFEST"
	) || fail "$component_label source manifest failed"
	(
		cd "$target_path" || exit 1
		find . -type f -print > "$COMPONENT_TARGET_RAW"
		LC_ALL=C sed 's#^\./##' "$COMPONENT_TARGET_RAW" | LC_ALL=C sort > "$COMPONENT_TARGET_MANIFEST"
	) || fail "$component_label production manifest failed"
	LC_ALL=C comm -23 "$COMPONENT_TARGET_MANIFEST" "$COMPONENT_SOURCE_MANIFEST" > "$COMPONENT_EXTRAS_MANIFEST" || fail "$component_label production manifest comparison failed"
	if [ -s "$COMPONENT_EXTRAS_MANIFEST" ]; then
		printf '%s\n' "PRODUCTION_EXTRA_FILES component=$component_label target=$target_path" >&2
		LC_ALL=C sed 's#^#PRODUCTION_EXTRA_FILE=#' "$COMPONENT_EXTRAS_MANIFEST" >&2
		fail "$component_label production contains files absent from deployment source; deployment is blocked pending a separately approved deletion-confirmation flow"
	fi
	rm -f "$COMPONENT_SOURCE_MANIFEST" "$COMPONENT_TARGET_MANIFEST" "$COMPONENT_EXTRAS_MANIFEST" "$COMPONENT_SOURCE_RAW" "$COMPONENT_TARGET_RAW"
	COMPONENT_SOURCE_MANIFEST=''
	COMPONENT_TARGET_MANIFEST=''
	COMPONENT_EXTRAS_MANIFEST=''
	COMPONENT_SOURCE_RAW=''
	COMPONENT_TARGET_RAW=''
}

assert_theme_ownership_prerequisites() {
	require_cmd stat
	require_cmd chown
	discover_site_owner || fail "Theme ownership prerequisites failed"
}

normalize_theme_ownership() {
	target_path="$1"
	discover_site_owner || return 1
	canonical_wp_for_ownership="$(CDPATH= cd -P "$WP_DIR" && pwd)" || fail "Could not determine canonical WordPress path"
	themes_dir="$canonical_wp_for_ownership/wp-content/themes"
	case "$target_path" in
		"$themes_dir"|"$themes_dir"/*) ;;
		*) printf '%s\n' "Theme ownership normalization skipped for non-theme path: $target_path"; return 0 ;;
	esac
	[ -d "$themes_dir" ] || fail "WordPress themes directory was not found"
	chown -- "$SITE_OWNER:$SITE_GROUP" "$themes_dir" || fail "Theme directory ownership normalization failed"
	[ -e "$target_path" ] || fail "Synchronized theme target was not found"
	chown -R -- "$SITE_OWNER:$SITE_GROUP" "$target_path" || fail "Synchronized theme ownership normalization failed"
	printf '%s\n' "Theme ownership normalized to $SITE_OWNER:$SITE_GROUP"
}

normalize_plugin_ownership() {
	target_path="$1"
	discover_site_owner || return 1
	canonical_wp_for_ownership="$(CDPATH= cd -P "$WP_DIR" && pwd)" || fail "Could not determine canonical WordPress path"
	plugins_dir="$canonical_wp_for_ownership/wp-content/plugins"
	case "$target_path" in
		"$plugins_dir"|"$plugins_dir"/*) ;;
		*) fail "Synchronized plugin target escaped plugins directory" ;;
	esac
	[ -d "$plugins_dir" ] || fail "WordPress plugins directory was not found"
	chown -- "$SITE_OWNER:$SITE_GROUP" "$plugins_dir" || fail "Plugin directory ownership normalization failed"
	[ -e "$target_path" ] || fail "Synchronized plugin target was not found"
	chown -R -- "$SITE_OWNER:$SITE_GROUP" "$target_path" || fail "Synchronized plugin ownership normalization failed"
	printf '%s\n' "Plugin ownership normalized to $SITE_OWNER:$SITE_GROUP"
}

normalize_mu_plugin_ownership() {
	target_path="$1"
	case "$(id -u)" in
		0) ;;
		*) return 0 ;;
	esac
	discover_site_owner || return 1
	canonical_wp_for_ownership="$(CDPATH= cd -P "$WP_DIR" && pwd)" || fail "Could not determine canonical WordPress path"
	mu_plugins_dir="$canonical_wp_for_ownership/wp-content/mu-plugins"
	case "$target_path" in
		"$mu_plugins_dir"|"$mu_plugins_dir"/*) ;;
		*) fail "Synchronized mu-plugin target escaped mu-plugins directory" ;;
	esac
	[ ! -L "$mu_plugins_dir" ] || fail "WordPress mu-plugins directory must not be a symbolic link"
	[ -d "$mu_plugins_dir" ] || fail "WordPress mu-plugins directory was not found"
	chown -- "$SITE_OWNER:$SITE_GROUP" "$mu_plugins_dir" || fail "Mu-plugins directory ownership normalization failed"
	[ -e "$target_path" ] || fail "Synchronized mu-plugin target was not found"
	chown -R -- "$SITE_OWNER:$SITE_GROUP" "$target_path" || fail "Synchronized mu-plugin ownership normalization failed"
	printf '%s\n' "Mu-plugin ownership normalized to $SITE_OWNER:$SITE_GROUP"
}

normalize_uploads_ownership() {
	target_path="$1"
	case "$(id -u)" in
		0) ;;
		*) return 0 ;;
	esac
	discover_site_owner || return 1
	canonical_wp_for_ownership="$(CDPATH= cd -P "$WP_DIR" && pwd)" || fail "Could not determine canonical WordPress path"
	uploads_dir="$canonical_wp_for_ownership/wp-content/uploads"
	[ "$target_path" = "$uploads_dir" ] || fail "Uploads ownership target escaped uploads directory"
	[ ! -L "$uploads_dir" ] || fail "Uploads ownership directory must not be a symbolic link"
	[ -d "$uploads_dir" ] || fail "WordPress uploads directory was not found"
	chown -R -- "$SITE_OWNER:$SITE_GROUP" "$uploads_dir" || fail "Uploads ownership normalization failed"
	printf '%s\n' "Uploads ownership normalized to $SITE_OWNER:$SITE_GROUP"
}

normalize_divi_ownership() {
	discover_site_owner || return 1
	canonical_wp_for_ownership="$(CDPATH= cd -P "$WP_DIR" && pwd)" || fail "Could not determine canonical WordPress path"
	divi_dir="$canonical_wp_for_ownership/wp-content/themes/Divi"
	[ -d "$divi_dir" ] || return 0
	chown -R -- "$SITE_OWNER:$SITE_GROUP" "$divi_dir" || fail "Divi ownership normalization failed"
	printf '%s\n' "Divi ownership normalized to $SITE_OWNER:$SITE_GROUP"
}

restore_transient_target() {
	failed_root="${TRANSIENT_NEW%/*}"
	failed_target="$failed_root/${TRANSIENT_TARGET##*/}.__failed__.$$"
	[ ! -e "$failed_target" ] || rm -rf "$failed_target" 2>/dev/null || true
	if [ -e "$TRANSIENT_TARGET" ]; then
		mv "$TRANSIENT_TARGET" "$failed_target" 2>/dev/null || return 1
	fi
	if [ -e "$TRANSIENT_OLD" ]; then
		if mv "$TRANSIENT_OLD" "$TRANSIENT_TARGET" 2>/dev/null; then
			rm -rf "$failed_target" 2>/dev/null || true
			return 0
		fi
		if [ -e "$failed_target" ]; then
			mv "$failed_target" "$TRANSIENT_TARGET" 2>/dev/null || true
		fi
		return 1
	fi
	rm -rf "$failed_target" 2>/dev/null || true
}

copy_paths() {
	paths="$1"
	component_label="$2"
	[ -n "$paths" ] || fail "$component_label sync paths are empty"
	require_cmd du
	canonical_wp="$(CDPATH= cd -P "$WP_DIR" && pwd)"
	CANONICAL_WP_DIR="$canonical_wp"
	old_ifs="$IFS"
	IFS=','
	for relative in $paths; do
		IFS="$old_ifs"
		assert_sync_path "$relative" "$component_label"
		source_path="$REPO_DIR/$relative"
		target_path="$canonical_wp/$relative"
		[ -d "$source_path" ] || fail "Configured sync source was not found"
		assert_no_symlink_components "$canonical_wp" "$relative"
		assert_no_production_extra_files "$source_path" "$target_path" "$component_label"
		case "$target_path" in "$canonical_wp"/*) ;; *) fail "Sync target escaped WordPress directory" ;; esac
		mkdir -p "$(dirname "$target_path")"
		source_kb="$(du -sk "$source_path" | awk 'NR==1 { print $1 }')"
		case "$source_kb" in ''|*[!0-9]*) fail "$component_label size check failed" ;; esac
		assert_free_space_kb "$WP_DIR" "$source_kb" "WordPress filesystem"
		transient_root="$WP_DIR/wp-content/.deploy-transient"
		[ ! -L "$transient_root" ] || fail "Transient directory must not be a symbolic link"
		mkdir -p "$transient_root"
		target_name="${target_path##*/}"
		TRANSIENT_TARGET="$target_path"
		TRANSIENT_NEW="$transient_root/$target_name.__new__.$timestamp.$$"
		TRANSIENT_OLD="$transient_root/$target_name.__old__.$timestamp.$$"
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
		TRANSIENT_REPLACED=1
		normalize_theme_ownership "$target_path"
		if [ "$component_label" = plugins ]; then normalize_plugin_ownership "$target_path"; fi
		if [ "$component_label" = mu-plugins ]; then normalize_mu_plugin_ownership "$target_path"; fi
		TRANSIENT_COMMITTED=1
		rm -rf "$TRANSIENT_OLD" 2>/dev/null || fail "Old code target cleanup failed"
		TRANSIENT_NEW=''; TRANSIENT_OLD=''; TRANSIENT_TARGET=''; TRANSIENT_REPLACED=0; TRANSIENT_COMMITTED=0
		IFS=','
	done
	IFS="$old_ifs"
	if [ "$DEPLOY_MODE" = full ]; then normalize_divi_ownership; fi
}

copy_code() { copy_paths "$SYNC_PATHS" code; }
copy_plugins() { [ -n "$PLUGIN_SYNC_PATHS" ] || return 0; copy_paths "$PLUGIN_SYNC_PATHS" plugins; }

copy_mu_plugin_files() {
	paths="$1"
	canonical_wp_for_mu_plugins="$(CDPATH= cd -P "$WP_DIR" && pwd)" || fail "Could not determine canonical WordPress path"
	CANONICAL_WP_DIR="$canonical_wp_for_mu_plugins"
	old_ifs="$IFS"
	IFS=','
	for relative in $paths; do
		IFS="$old_ifs"
		source_path="$REPO_DIR/$relative"
		target_path="$canonical_wp_for_mu_plugins/$relative"
		[ -f "$source_path" ] || fail "Configured mu-plugin sync source was not found"
		[ ! -L "$source_path" ] || fail "Configured mu-plugin sync source must not be a symbolic link"
		assert_no_symlink_components "$REPO_DIR" "$relative"
		assert_no_symlink_components "$canonical_wp_for_mu_plugins" "$relative"
		source_kb="$(du -sk "$source_path" | awk 'NR==1 { print $1 }')"
		case "$source_kb" in ''|*[!0-9]*) fail "Mu-plugin size check failed" ;; esac
		assert_free_space_kb "$WP_DIR" "$source_kb" "WordPress filesystem"
		transient_root="$canonical_wp_for_mu_plugins/wp-content/.deploy-transient"
		[ ! -L "$transient_root" ] || fail "Transient directory must not be a symbolic link"
		mkdir -p "$transient_root"
		target_name="${target_path##*/}"
		TRANSIENT_TARGET="$target_path"
		TRANSIENT_NEW="$transient_root/$target_name.__new__.$timestamp.$$"
		TRANSIENT_OLD="$transient_root/$target_name.__old__.$timestamp.$$"
		rm -rf "$TRANSIENT_NEW" "$TRANSIENT_OLD"
		cp -- "$source_path" "$TRANSIENT_NEW"
		[ -f "$TRANSIENT_NEW" ] || fail "Atomic MU-plugin staging failed"
		if [ -e "$target_path" ]; then mv "$target_path" "$TRANSIENT_OLD"; fi
		if ! mv "$TRANSIENT_NEW" "$target_path"; then
			[ ! -e "$TRANSIENT_OLD" ] || mv "$TRANSIENT_OLD" "$target_path"
			fail "Atomic MU-plugin replacement failed"
		fi
		TRANSIENT_REPLACED=1
		normalize_mu_plugin_ownership "$target_path"
		TRANSIENT_COMMITTED=1
		rm -rf "$TRANSIENT_OLD" 2>/dev/null || fail "Old MU-plugin target cleanup failed"
		TRANSIENT_NEW=''; TRANSIENT_OLD=''; TRANSIENT_TARGET=''; TRANSIENT_REPLACED=0; TRANSIENT_COMMITTED=0
		IFS=','
	done
	IFS="$old_ifs"
}

copy_mu_plugins() {
	[ -n "$MU_PLUGIN_SYNC_PATHS" ] || return 0
	require_cmd du
	canonical_wp_for_mu_plugins="$(CDPATH= cd -P "$WP_DIR" && pwd)" || fail "Could not determine canonical WordPress path"
	mu_plugins_dir="$canonical_wp_for_mu_plugins/wp-content/mu-plugins"
	[ ! -L "$mu_plugins_dir" ] || fail "WordPress mu-plugins directory must not be a symbolic link"
	[ -d "$mu_plugins_dir" ] || fail "WordPress mu-plugins directory was not found"

	# Validate all configured sources before replacing any MU-plugin target.
	directory_paths=''
	file_paths=''
	old_ifs="$IFS"
	IFS=','
	for relative in $MU_PLUGIN_SYNC_PATHS; do
		IFS="$old_ifs"
		assert_sync_path "$relative" mu-plugins
		source_path="$REPO_DIR/$relative"
		target_path="$canonical_wp_for_mu_plugins/$relative"
		if [ -d "$source_path" ]; then
			directory_paths="${directory_paths}${directory_paths:+,}$relative"
		elif [ -f "$source_path" ]; then
			file_paths="${file_paths}${file_paths:+,}$relative"
		else
			fail "Configured mu-plugin sync source was not found"
		fi
		[ ! -L "$source_path" ] || fail "Configured mu-plugin sync source must not be a symbolic link"
		assert_no_symlink_components "$REPO_DIR" "$relative"
		case "$target_path" in "$canonical_wp_for_mu_plugins"/*) ;; *) fail "Mu-plugin sync target escaped WordPress directory" ;; esac
		assert_no_symlink_components "$canonical_wp_for_mu_plugins" "$relative"
		IFS=','
	done
	IFS="$old_ifs"

	[ -z "$directory_paths" ] || copy_paths "$directory_paths" mu-plugins
	[ -z "$file_paths" ] || copy_mu_plugin_files "$file_paths"
}

backup_database() {
	require_cmd mysqldump
	name="$(wp_config_value DB_NAME)"
	user="$(wp_config_value DB_USER)"
	pass="$(wp_config_value DB_PASSWORD)"
	database_connection "$(wp_config_value DB_HOST)"
	create_mysql_defaults_file
	mkdir -p "$BACKUP_DIR"
	BACKUP_FILE="$BACKUP_DIR/db-$timestamp.sql"
	if ! mysqldump --defaults-file="$MYSQL_DEFAULTS_FILE" --single-transaction --quick --no-tablespaces --default-character-set=utf8mb4 "$name" > "$BACKUP_FILE"; then
		rm -f "$BACKUP_FILE"
		BACKUP_FILE=''
		fail "Database backup failed"
	fi
	if ! ( assert_sql_dump "$BACKUP_FILE" ); then
		rm -f "$BACKUP_FILE"
		BACKUP_FILE=''
		fail "Database backup validation failed"
	fi
}

mysql_import_file() {
	import_file="$1"
	mysql --defaults-file="$MYSQL_DEFAULTS_FILE" "$name" < "$import_file"
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
				manual_wp_cli="$(wp_cli_manual_prefix)"
				if {
					printf '%s\n' 'status=manual-recovery-required'
					printf 'created_at=%s\n' "$timestamp"
					printf 'wp_dir=%s\n' "$WP_DIR"
					printf 'db_name=%s\n' "$name"
					printf "restore_command=%s db import '%s'\n" "$manual_wp_cli" "$MANUAL_RECOVERY_BACKUP"
					printf "verify_command=%s core is-installed\n" "$manual_wp_cli"
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
		printf "RECOVERY_COMMAND=%s db import '%s'\n" "$(wp_cli_manual_prefix)" "$MANUAL_RECOVERY_BACKUP" >&2
	fi
}

import_database() {
	require_cmd mysql
	assert_sql_dump "$SQL_FILE"
	name="$(wp_config_value DB_NAME)"
	user="$(wp_config_value DB_USER)"
	pass="$(wp_config_value DB_PASSWORD)"
	database_connection "$(wp_config_value DB_HOST)"
	create_mysql_defaults_file
	if ! mysql_import_file "$SQL_FILE"; then
		fail_after_database_mutation "Database import failed"
	fi

}

finalize_database_backup() {
	if command -v gzip >/dev/null 2>&1; then
		gzip -f "$BACKUP_FILE"
		gzip -t "$BACKUP_FILE.gz" || fail "Compressed database backup is invalid"
	fi
}

rollback_database_or_require_manual_recovery() {
	if mysql_import_file "$BACKUP_FILE"; then
		cleanup_backups || true
		return 0
	fi
	preserve_manual_recovery
	return 1
}

fail_after_database_mutation() {
	reason="$1"
	if rollback_database_or_require_manual_recovery; then
		database_mutation_active=0
		fail "$reason; rollback completed"
	fi
	database_mutation_active=0
	fail "$reason and rollback failed; manual recovery is required"
}

rewrite_wordpress_urls() {
	: "${LOCAL_URL:?LOCAL_URL is required for database deployment}"
	[ "$(normalize_url "$LOCAL_URL")" != "$(normalize_url "$REMOTE_URL")" ] || fail "Local and remote URLs must differ for database deployment"

	if ! wp_cli search-replace "$LOCAL_URL" "$REMOTE_URL" --all-tables-with-prefix --precise --recurse-objects --skip-columns=guid; then
		fail_after_database_mutation "URL rewrite failed"
	fi

	remaining_replacements="$(wp_cli search-replace "$LOCAL_URL" "$REMOTE_URL" --all-tables-with-prefix --precise --recurse-objects --skip-columns=guid --dry-run --format=count)" || fail_after_database_mutation "URL rewrite verification failed"
	case "$remaining_replacements" in
		0) ;;
		*) fail_after_database_mutation "URL rewrite verification failed" ;;
	esac
}

validate_uploads_manifest_tree() {
	manifest="$1"
	root="$2"
	[ -f "$manifest" ] || return 1
	[ -d "$root" ] && [ ! -L "$root" ] || return 1
	if [ -n "$(find "$root" -type l -print -quit)" ]; then return 1; fi
	count=0
	previous=''
	while IFS="$(printf '\t')" read -r sha size relative extra; do
		[ -n "$relative" ] || return 1
		[ -z "${extra:-}" ] || return 1
		[ "${#sha}" -eq 64 ] || return 1
		case "$sha" in *[!0-9A-Fa-f]*) return 1 ;; esac
		case "$size" in ''|*[!0-9]*) return 1 ;; esac
		case "$relative" in ''|/*|../*|*/../*|*/..|*//*|*'\t'*) return 1 ;; esac
		[ -z "$previous" ] || [ "$relative" \> "$previous" ] || return 1
		file="$root/$relative"
		[ -f "$file" ] && [ ! -L "$file" ] || return 1
		[ "$(stat -c '%s' "$file")" = "$size" ] || return 1
		[ "$(sha256sum "$file" | awk '{print tolower($1)}')" = "$(printf '%s' "$sha" | tr '[:upper:]' '[:lower:]')" ] || return 1
		previous="$relative"
		count=$((count + 1))
	done < "$manifest"
	actual_count="$(find "$root" -type f | wc -l | tr -d ' ')"
	[ "$actual_count" = "$count" ] || return 1
}

install_uploads_manifest() {
	source_manifest="$1"
	[ -f "$source_manifest" ] || fail "Uploads manifest was not found"
	[ ! -L "$UPLOADS_MANIFEST_PATH" ] || fail "Uploads manifest target must not be a symbolic link"
	[ ! -e "$UPLOADS_MANIFEST_PATH" ] || [ -f "$UPLOADS_MANIFEST_PATH" ] || fail "Uploads manifest target must be a regular file"
	if [ -f "$UPLOADS_MANIFEST_PATH" ]; then
		UPLOADS_MANIFEST_OLD="$BACKUP_DIR/uploads-manifest.tsv.old.$timestamp.$$"
		cp -- "$UPLOADS_MANIFEST_PATH" "$UPLOADS_MANIFEST_OLD" || fail "Uploads manifest backup failed"
		chmod 600 "$UPLOADS_MANIFEST_OLD" || fail "Uploads manifest backup mode update failed"
		chown root:root "$UPLOADS_MANIFEST_OLD" || fail "Uploads manifest backup ownership normalization failed"
	fi
	UPLOADS_MANIFEST_NEW="$BACKUP_DIR/uploads-manifest.tsv.new.$timestamp.$$"
	cp -- "$source_manifest" "$UPLOADS_MANIFEST_NEW" || fail "Uploads manifest staging failed"
	chmod 600 "$UPLOADS_MANIFEST_NEW" || fail "Uploads manifest mode update failed"
	chown root:root "$UPLOADS_MANIFEST_NEW" || fail "Uploads manifest ownership normalization failed"
	mv -f "$UPLOADS_MANIFEST_NEW" "$UPLOADS_MANIFEST_PATH" || fail "Uploads manifest replacement failed"
	UPLOADS_MANIFEST_NEW=''
	UPLOADS_MANIFEST_REPLACED=1
}

commit_uploads_manifest() {
	[ ! -L "$UPLOADS_TRANSACTION_LOG" ] || fail "Uploads transaction log must not be a symbolic link"
	[ ! -e "$UPLOADS_TRANSACTION_LOG" ] || [ -f "$UPLOADS_TRANSACTION_LOG" ] || fail "Uploads transaction log must be a regular file"
	if [ -f "$UPLOADS_TRANSACTION_LOG" ]; then
		UPLOADS_TRANSACTION_LOG_OLD="$BACKUP_DIR/uploads-transactions.log.old.$timestamp.$$"
		cp -- "$UPLOADS_TRANSACTION_LOG" "$UPLOADS_TRANSACTION_LOG_OLD" || fail "Uploads transaction log backup failed"
		chmod 600 "$UPLOADS_TRANSACTION_LOG_OLD" || fail "Uploads transaction log backup mode update failed"
		chown root:root "$UPLOADS_TRANSACTION_LOG_OLD" || fail "Uploads transaction log backup ownership normalization failed"
	fi
	UPLOADS_TRANSACTION_LOG_NEW="$BACKUP_DIR/uploads-transactions.log.new.$timestamp.$$"
	if [ -f "$UPLOADS_TRANSACTION_LOG" ]; then cp -- "$UPLOADS_TRANSACTION_LOG" "$UPLOADS_TRANSACTION_LOG_NEW" || fail "Uploads transaction log staging failed"; else : > "$UPLOADS_TRANSACTION_LOG_NEW"; fi
	printf 'release=%s mode=%s manifest_sha256=%s\n' "$timestamp" "$UPLOADS_TRANSACTION_KIND" "$(sha256sum "$UPLOADS_MANIFEST_PATH" | awk '{print toupper($1)}')" >> "$UPLOADS_TRANSACTION_LOG_NEW" || fail "Uploads transaction log write failed"
	chmod 600 "$UPLOADS_TRANSACTION_LOG_NEW" || fail "Uploads transaction log mode update failed"
	chown root:root "$UPLOADS_TRANSACTION_LOG_NEW" || fail "Uploads transaction log ownership normalization failed"
	mv -f "$UPLOADS_TRANSACTION_LOG_NEW" "$UPLOADS_TRANSACTION_LOG" || fail "Uploads transaction log replacement failed"
	UPLOADS_TRANSACTION_LOG_NEW=''
	UPLOADS_TRANSACTION_LOG_REPLACED=1
	if [ -n "$UPLOADS_MANIFEST_OLD" ]; then rm -f "$UPLOADS_MANIFEST_OLD" 2>/dev/null || true; UPLOADS_MANIFEST_OLD=''; fi
	if [ -n "$UPLOADS_TRANSACTION_LOG_OLD" ]; then rm -f "$UPLOADS_TRANSACTION_LOG_OLD" 2>/dev/null || true; UPLOADS_TRANSACTION_LOG_OLD=''; fi
	UPLOADS_MANIFEST_REPLACED=0
	UPLOADS_TRANSACTION_LOG_REPLACED=0
	printf 'UPLOADS_MANIFEST_RELEASE=%s\n' "$timestamp"
	printf 'UPLOADS_MANIFEST_SHA256=%s\n' "$(sha256sum "$UPLOADS_MANIFEST_PATH" | awk '{print toupper($1)}')"
}

assert_uploads_delta_baseline() {
	canonical_wp_for_uploads="$(CDPATH= cd -P "$WP_DIR" && pwd)" || return 1
	current_uploads="$canonical_wp_for_uploads/wp-content/uploads"
	[ ! -L "$current_uploads" ] && [ -d "$current_uploads" ] || return 1
	[ -f "$UPLOADS_MANIFEST_PATH" ] && [ ! -L "$UPLOADS_MANIFEST_PATH" ] || return 1
	validate_uploads_manifest_tree "$UPLOADS_MANIFEST_PATH" "$current_uploads"
}

sync_uploads_delta() {
	UPLOADS_TRANSACTION_KIND='delta'
	[ -f "$UPLOADS_DELTA_ZIP" ] || fail "Uploads delta archive was not found"
	[ -f "$UPLOADS_MANIFEST_FILE" ] || fail "Uploads manifest file was not found"
	require_cmd unzip
	require_cmd sha256sum
	require_cmd cmp
	assert_uploads_delta_baseline || fail 'UPLOADS_DELTA_FALLBACK_REQUIRED: uploads baseline is missing or drifted'
	canonical_wp_for_uploads="$(CDPATH= cd -P "$WP_DIR" && pwd)" || fail "Could not determine canonical WordPress path"
	CANONICAL_WP_DIR="$canonical_wp_for_uploads"
	transient_root="$canonical_wp_for_uploads/wp-content/.deploy-transient"
	[ ! -L "$transient_root" ] || fail "Transient directory must not be a symbolic link"
	mkdir -p "$transient_root"
	new="$transient_root/uploads.__new__"
	old="$transient_root/uploads.__old__"
	current="$canonical_wp_for_uploads/wp-content/uploads"
	[ ! -L "$new" ] && [ ! -L "$old" ] && [ ! -L "$current" ] || fail "Uploads paths must not be symbolic links"
	unzip -tq "$UPLOADS_DELTA_ZIP" >/dev/null || fail "Uploads delta archive integrity check failed"
	UPLOADS_DELTA_STAGE="$SERVER_EXPECTED_TMP_DIR/uploads-delta-$timestamp.$$"
	rm -rf "$UPLOADS_DELTA_STAGE"
	mkdir -p "$UPLOADS_DELTA_STAGE"
	ARCHIVE_LISTING="$SERVER_EXPECTED_TMP_DIR/uploads-delta-$timestamp.list"
	unzip -Z1 "$UPLOADS_DELTA_ZIP" > "$ARCHIVE_LISTING"
	while IFS= read -r entry; do
		case "$entry" in manifest.tsv|delete.list|payload/|payload/*) ;; *) fail "Uploads delta archive contains an unsafe entry" ;; esac
		case "$entry" in *'..'*|/*|*'//'*) fail "Uploads delta archive contains an unsafe path" ;; esac
	done < "$ARCHIVE_LISTING"
	rm -f "$ARCHIVE_LISTING"
	ARCHIVE_LISTING=''
	unzip -q "$UPLOADS_DELTA_ZIP" -d "$UPLOADS_DELTA_STAGE"
	[ -f "$UPLOADS_DELTA_STAGE/manifest.tsv" ] && [ -f "$UPLOADS_DELTA_STAGE/delete.list" ] || fail "Uploads delta metadata is incomplete"
	cmp -s "$UPLOADS_DELTA_STAGE/manifest.tsv" "$UPLOADS_MANIFEST_FILE" || fail "Uploads delta manifest does not match sidecar"
	if [ -n "$(find "$UPLOADS_DELTA_STAGE" -type l -print -quit)" ]; then fail "Uploads delta archive contains a symbolic link"; fi
	require_cmd du
	base_uploads_kb="$(du -sk "$current" | awk 'NR==1 { print $1 }')"
	payload_uploads_kb="$(du -sk "$UPLOADS_DELTA_STAGE/payload" 2>/dev/null | awk 'NR==1 { print $1 }')"
	case "$base_uploads_kb:$payload_uploads_kb" in *[!0-9:]*|:*) fail "Uploads delta size check failed" ;; esac
	assert_free_space_kb "$WP_DIR" "$((base_uploads_kb + payload_uploads_kb))" "WordPress filesystem"
	rm -rf "$new" "$old"
	TRANSIENT_TARGET="$current"; TRANSIENT_NEW="$new"; TRANSIENT_OLD="$old"
	mkdir -p "$new"
	cp -a "$current/." "$new/" || fail "Uploads delta base staging failed"
	while IFS= read -r relative; do
		[ -z "$relative" ] && continue
		case "$relative" in ''|/*|../*|*/../*|*/..|*//*|*'\t'*) fail "Uploads delta delete list contains an unsafe path" ;; esac
		rm -f "$new/$relative"
	done < "$UPLOADS_DELTA_STAGE/delete.list"
	find "$UPLOADS_DELTA_STAGE/payload" -type f -print > "$UPLOADS_DELTA_STAGE/payload.list" 2>/dev/null || true
	while IFS= read -r payload_file; do
		[ -z "$payload_file" ] && continue
		relative="${payload_file#"$UPLOADS_DELTA_STAGE/payload/"}"
		case "$relative" in ''|/*|../*|*/../*|*/..|*//*|*'\t'*) fail "Uploads delta payload contains an unsafe path" ;; esac
		destination="$new/$relative"
		mkdir -p "$(dirname "$destination")"
		cp -- "$payload_file" "$destination" || fail "Uploads delta payload copy failed"
	done < "$UPLOADS_DELTA_STAGE/payload.list"
	validate_uploads_manifest_tree "$UPLOADS_MANIFEST_FILE" "$new" || fail "Uploads delta final manifest verification failed"
	[ -d "$current" ] || fail "WordPress uploads directory was not found"
	mv "$current" "$old" || fail "Atomic uploads delta staging failed"
	if ! mv "$new" "$current"; then
		[ ! -e "$old" ] || mv "$old" "$current"
		fail "Atomic uploads delta replacement failed"
	fi
	TRANSIENT_REPLACED=1
	normalize_uploads_ownership "$current"
	install_uploads_manifest "$UPLOADS_MANIFEST_FILE"
	commit_uploads_manifest
	TRANSIENT_COMMITTED=1
	rm -rf "$old" 2>/dev/null || fail "Old uploads target cleanup failed"
	rm -rf "$UPLOADS_DELTA_STAGE"
	UPLOADS_DELTA_STAGE=''; TRANSIENT_NEW=''; TRANSIENT_OLD=''; TRANSIENT_TARGET=''; TRANSIENT_REPLACED=0; TRANSIENT_COMMITTED=0
}

sync_uploads() {
	UPLOADS_TRANSACTION_KIND='full'
	[ -f "$UPLOADS_ZIP" ] || fail "Uploads archive was not found"
	require_cmd unzip
	canonical_wp_for_uploads="$(CDPATH= cd -P "$WP_DIR" && pwd)" || fail "Could not determine canonical WordPress path"
	CANONICAL_WP_DIR="$canonical_wp_for_uploads"
	transient_root="$canonical_wp_for_uploads/wp-content/.deploy-transient"
	[ ! -L "$transient_root" ] || fail "Transient directory must not be a symbolic link"
	mkdir -p "$transient_root"
	new="$transient_root/uploads.__new__"
	old="$transient_root/uploads.__old__"
	current="$canonical_wp_for_uploads/wp-content/uploads"
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
	if [ -n "$UPLOADS_MANIFEST_FILE" ]; then
		validate_uploads_manifest_tree "$UPLOADS_MANIFEST_FILE" "$new" || fail "Uploads manifest verification failed"
	fi
	[ ! -d "$current" ] || mv "$current" "$old"
	if ! mv "$new" "$current"; then
		[ ! -d "$old" ] || mv "$old" "$current"
		fail "Atomic uploads replacement failed"
	fi
	TRANSIENT_REPLACED=1
	normalize_uploads_ownership "$current"
	if [ -n "$UPLOADS_MANIFEST_FILE" ]; then install_uploads_manifest "$UPLOADS_MANIFEST_FILE"; fi
	if [ -n "$UPLOADS_MANIFEST_FILE" ]; then commit_uploads_manifest; fi
	TRANSIENT_COMMITTED=1
	rm -rf "$old" 2>/dev/null || fail "Old uploads target cleanup failed"
	TRANSIENT_NEW=''; TRANSIENT_OLD=''; TRANSIENT_TARGET=''; TRANSIENT_REPLACED=0; TRANSIENT_COMMITTED=0
}

cleanup_wordpress() {
	if ! refresh_wordpress_runtime_cache; then
		printf '%s\n' 'WARNING: Runtime cache refresh failed after database deployment; database changes remain committed.' >&2
	fi
	wp_cli rewrite flush --hard || true
}

refresh_wordpress_runtime_cache() {
	# Divi's public cache-clearing method requires an authenticated editor.
	# The internal method is the same invalidation path without that HTTP-only
	# capability check, which makes it safe to use from this guarded WP-CLI
	# runner after a successful atomic code replacement.
	if ! normalize_divi_runtime_cache_ownership; then
		return 1
	fi
	if ! wp_cli_as_site_owner eval 'if ( class_exists( "ET_Core_PageResource" ) ) { $previous_error_reporting = error_reporting(); error_reporting( $previous_error_reporting & ~E_WARNING ); try { ET_Core_PageResource::do_remove_static_resources( "all", "all", true ); } finally { error_reporting( $previous_error_reporting ); } echo "Divi static resources invalidated.\\n"; } else { echo "Divi static resources are not installed.\\n"; }'; then
		return 1
	fi
	if ! wp_cli_as_site_owner cache flush; then
		return 1
	fi
	if ! wp_cli_as_site_owner transient delete --all; then
		return 1
	fi
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
assert_theme_ownership_prerequisites
assert_runtime_cache_ownership_prerequisites

case "$DEPLOY_MODE" in
	preflight)
		require_cmd git
		[ -f "$SERVER_GIT_SSH_KEY" ] || fail "Server Git SSH key was not found"
		wp_cli --info
		;;
	code|db|code-db|uploads|plugins|mu-plugins|full)
		cleanup_artifacts=1
		acquire_lock
		cleanup_stale_temp_files
		mkdir -p "$BACKUP_DIR"
		assert_free_space_kb "$WP_DIR" 0 "WordPress filesystem"
		assert_free_space_kb "$BACKUP_DIR" 0 "Backup filesystem"
		if [ -n "$UPLOADS_DELTA_ZIP" ]; then
			assert_uploads_delta_baseline || fail 'UPLOADS_DELTA_FALLBACK_REQUIRED: uploads baseline is missing or drifted'
		fi

		case "$DEPLOY_MODE" in
			code|plugins|mu-plugins|code-db|full) update_repository ;;
		esac
		case "$DEPLOY_MODE" in
			code|code-db|full) copy_code ;;
		esac
		case "$DEPLOY_MODE" in
			plugins|full) copy_plugins ;;
		esac
		case "$DEPLOY_MODE" in
			mu-plugins|full) copy_mu_plugins ;;
		esac
		case "$DEPLOY_MODE" in
			code) refresh_wordpress_runtime_cache ;;
		esac
		case "$DEPLOY_MODE" in
			uploads)
				if [ -n "$UPLOADS_DELTA_ZIP" ]; then sync_uploads_delta; else sync_uploads; fi
				;;
		esac
		case "$DEPLOY_MODE" in
			db|code-db|full)
				require_cmd wc
				assert_sql_dump "$SQL_FILE"
				incoming_kb="$(wc -c < "$SQL_FILE" | awk '{ print int(($1 + 1023) / 1024) }')"
				case "$incoming_kb" in ''|*[!0-9]*) fail "Incoming SQL size check failed" ;; esac
				assert_free_space_kb "$BACKUP_DIR" "$incoming_kb" "Backup filesystem"
				backup_database
				database_mutation_active=1
				import_database
				rewrite_wordpress_urls
				if [ -n "$UPLOADS_DELTA_ZIP" ]; then sync_uploads_delta; elif [ -n "$UPLOADS_ZIP" ]; then sync_uploads; fi
				cleanup_wordpress
				database_mutation_active=0
				finalize_database_backup
				cleanup_backups || true
				;;
		esac
		;;
esac

echo "WordPress deployment completed ($DEPLOY_MODE)"
