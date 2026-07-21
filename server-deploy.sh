#!/usr/bin/env sh
set -eu

: "${WP_DIR:?WP_DIR is required}"
: "${REPO_DIR:?REPO_DIR is required}"
: "${BACKUP_DIR:?BACKUP_DIR is required}"
: "${EXPECTED_WP_DIR:?EXPECTED_WP_DIR is required}"
: "${EXPECTED_DB_NAME:?EXPECTED_DB_NAME is required}"
: "${SYNC_PATHS:?SYNC_PATHS is required}"

DEPLOY_MODE="${DEPLOY_MODE:-full}"
KEEP_BACKUPS="${KEEP_BACKUPS:-10}"
SQL_FILE="${SQL_FILE:-}"
UPLOADS_ZIP="${UPLOADS_ZIP:-}"
PHP_BIN="${PHP_BIN:-php}"
WP_CLI_BIN="${WP_CLI_BIN:-wp}"
timestamp="$(date +%Y%m%d-%H%M%S)"

fail() { echo "ERROR: $1" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"; }

[ "$WP_DIR" = "$EXPECTED_WP_DIR" ] || fail "WP_DIR safety lock mismatch"
[ -f "$WP_DIR/wp-config.php" ] || fail "wp-config.php not found: $WP_DIR"
[ -d "$WP_DIR/wp-content" ] || fail "wp-content not found: $WP_DIR"
[ -d "$REPO_DIR/.git" ] || fail "Git repository not found: $REPO_DIR"

wp_config_value() {
	"$PHP_BIN" -r "\$c=file_get_contents('$WP_DIR/wp-config.php'); if (preg_match(\"/define\\(\\s*['\\\"]$1['\\\"]\\s*,\\s*['\\\"]([^'\\\"]*)['\\\"]\\s*\\)/\", \$c, \$m)) echo \$m[1];"
}
wp_cli() { "$PHP_BIN" "$WP_CLI_BIN" --path="$WP_DIR" "$@"; }
mysql_args() {
	case "$1" in *:*) printf '%s\n' "--host=${1%%:*}" "--port=${1##*:}" ;; *) printf '%s\n' "--host=$1" ;; esac
}
assert_database() {
	actual="$(wp_config_value DB_NAME)"
	[ "$actual" = "$EXPECTED_DB_NAME" ] || fail "DB_NAME safety lock mismatch"
}
copy_code() {
	old_ifs="$IFS"; IFS=','
	for relative in $SYNC_PATHS; do
		IFS="$old_ifs"
		case "$relative" in ''|/*|*../*|../*|*/..) fail "Unsafe sync path: $relative" ;; esac
		source_path="$REPO_DIR/$relative"; target_path="$WP_DIR/$relative"
		[ -d "$source_path" ] || fail "Sync source not found: $source_path"
		mkdir -p "$(dirname "$target_path")"
		if command -v rsync >/dev/null 2>&1; then rsync -a --delete "$source_path/" "$target_path/"
		else rm -rf "$target_path"; mkdir -p "$target_path"; cp -R "$source_path/." "$target_path/"; fi
		IFS=','
	done
	IFS="$old_ifs"
}
backup_database() {
	require_cmd mysqldump; assert_database
	name="$(wp_config_value DB_NAME)"; user="$(wp_config_value DB_USER)"
	pass="$(wp_config_value DB_PASSWORD)"; host="$(wp_config_value DB_HOST)"
	mkdir -p "$BACKUP_DIR"; file="$BACKUP_DIR/db-$timestamp.sql"
	MYSQL_PWD="$pass" mysqldump $(mysql_args "$host") --user="$user" --single-transaction --quick --no-tablespaces --default-character-set=utf8mb4 "$name" > "$file"
	command -v gzip >/dev/null 2>&1 && gzip -f "$file"
}
import_database() {
	require_cmd mysql; assert_database; [ -f "$SQL_FILE" ] || fail "SQL file not found"
	name="$(wp_config_value DB_NAME)"; user="$(wp_config_value DB_USER)"
	pass="$(wp_config_value DB_PASSWORD)"; host="$(wp_config_value DB_HOST)"
	MYSQL_PWD="$pass" mysql $(mysql_args "$host") --user="$user" "$name" < "$SQL_FILE"
}
sync_uploads() {
	[ -f "$UPLOADS_ZIP" ] || fail "Uploads archive not found"; require_cmd unzip
	new="$WP_DIR/wp-content/uploads.__new__"; old="$WP_DIR/wp-content/uploads.__old__"; current="$WP_DIR/wp-content/uploads"
	rm -rf "$new" "$old"; mkdir -p "$new"; unzip -q "$UPLOADS_ZIP" -d "$new"
	[ ! -d "$current" ] || mv "$current" "$old"; mv "$new" "$current"; rm -rf "$old"
}
cleanup_wordpress() {
	wp_cli search-replace "$LOCAL_URL" "$REMOTE_URL" --all-tables --precise --recurse-objects --skip-columns=guid
	wp_cli option update home "$REMOTE_URL"; wp_cli option update siteurl "$REMOTE_URL"
	wp_cli cache flush || true; wp_cli transient delete --all || true; wp_cli rewrite flush --hard || true
}
cleanup() {
	find "$BACKUP_DIR" -type f -name 'db-*.sql*' | sort -r | awk "NR>$KEEP_BACKUPS" | xargs -r rm -f
	[ -z "$SQL_FILE" ] || rm -f "$SQL_FILE"; [ -z "$UPLOADS_ZIP" ] || rm -f "$UPLOADS_ZIP"
}

case "$DEPLOY_MODE" in
	preflight) require_cmd git; require_cmd mysql; require_cmd mysqldump; require_cmd unzip; assert_database; wp_cli --info ;;
	code) copy_code ;;
	db|full)
		[ "$DEPLOY_MODE" != full ] || copy_code
		backup_database; import_database
		[ -z "$UPLOADS_ZIP" ] || sync_uploads
		cleanup_wordpress; cleanup
		;;
	*) fail "Unknown DEPLOY_MODE: $DEPLOY_MODE" ;;
esac

echo "WordPress deployment completed ($DEPLOY_MODE)"

