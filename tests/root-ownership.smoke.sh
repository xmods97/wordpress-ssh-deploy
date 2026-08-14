#!/usr/bin/env sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
target="$fixture/site"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/bin" "$target/wp/wp-content" "$target/repo/.git" "$target/tmp" "$target/backups"
: > "$target/wp/wp-config.php"
: > "$target/id_ed25519"
: > "$target/bin-wp"
cp "$repo_root/server-deploy.sh" "$fixture/server-deploy.sh"
cp "$repo_root/tests/fixtures/fake-mysqldump.sh" "$fixture/bin/mysqldump"
cp "$repo_root/tests/fixtures/fake-mysql.sh" "$fixture/bin/mysql"
cp "$repo_root/tests/fixtures/fake-df.sh" "$fixture/bin/df"

cat > "$fixture/bin/id" <<'EOF'
#!/usr/bin/env sh
case "${1:-}:${2:-}" in
	-u:) case "${FIXTURE_ID_MODE:-root}" in root) printf '%s\n' 0 ;; invalid) printf '%s\n' invalid ;; *) exit 1 ;; esac ;;
	-u:site-owner) printf '%s\n' 1001 ;;
	*) exit 1 ;;
esac
EOF

cat > "$fixture/bin/getent" <<'EOF'
#!/usr/bin/env sh
[ "${1:-}" = group ] && [ "${2:-}" = site-group ]
EOF

cat > "$fixture/bin/chown" <<'EOF'
#!/usr/bin/env sh
: "${FIXTURE_ROOT:?FIXTURE_ROOT is required}"
if [ "${FIXTURE_EXPECT_LOCK_DURING_CHOWN:-0}" = 1 ] && [ ! -d "$FIXTURE_ROOT/lock/deploy.lock" ]; then
	echo 'Ownership restoration began after deploy lock was released' >&2
	exit 1
fi
printf '%s\n' "$*" >> "$FIXTURE_ROOT/chown.log"
[ "${FIXTURE_CHOWN_FAIL:-0}" = 0 ]
EOF

cat > "$fixture/bin/php" <<'EOF'
#!/usr/bin/env sh
wp_path=''
for arg in "$@"; do
	case "$arg" in --path=*) wp_path=${arg#--path=} ;; esac
done
case " $* " in
	*' eval '*) printf '%s\n' staging ;;
	*' option get home '*|*' option get siteurl '*) printf '%s\n' https://staging.example.test ;;
	*' config get DB_NAME '*) printf '%s\n' wordpress_staging ;;
	*' config get table_prefix '*) printf '%s\n' wp_ ;;
	*' config get DB_USER '*) printf '%s\n' fixture_user ;;
	*' config get DB_PASSWORD '*) printf '%s\n' fixture_password ;;
	*' config get DB_HOST '*) printf '%s\n' localhost ;;
	*' rewrite flush '*)
		mkdir -p "$wp_path/wp-content/cache" "$wp_path/wp-content/upgrade"
		: > "$wp_path/.htaccess"
		;;
	*' search-replace '*|*' option update '*|*' cache flush '*|*' transient delete '*|*' --info '*) : ;;
	*) echo 'Unexpected fake PHP invocation' >&2; exit 1 ;;
esac
EOF

chmod +x "$fixture/bin/id" "$fixture/bin/getent" "$fixture/bin/chown" "$fixture/bin/php" \
	"$fixture/bin/mysqldump" "$fixture/bin/mysql" "$fixture/bin/df"

config="$fixture/server.config.sh"
cat > "$config" <<EOF
SERVER_ENVIRONMENT='staging'
SERVER_EXPECTED_URL='https://staging.example.test'
SERVER_EXPECTED_WP_DIR='$target/wp'
SERVER_EXPECTED_REPO_DIR='$target/repo'
SERVER_EXPECTED_TMP_DIR='$target/tmp'
SERVER_EXPECTED_BACKUP_DIR='$target/backups'
SERVER_EXPECTED_DB_NAME='wordpress_staging'
SERVER_EXPECTED_DB_TABLE_PREFIX='wp_'
SERVER_GIT_SSH_KEY='$target/id_ed25519'
SERVER_PHP_BIN='$fixture/bin/php'
SERVER_WP_CLI_BIN='$target/bin-wp'
SERVER_SYNC_PATHS='wp-content/themes/example-theme'
SERVER_KEEP_BACKUPS='10'
SERVER_MIN_FREE_SPACE_MB='1'
SERVER_LOCK_DIR='$target/lock/deploy.lock'
SERVER_FILE_OWNER='site-owner'
SERVER_FILE_GROUP='site-group'
EOF

run_root_db() {
	cat > "$target/tmp/incoming.sql" <<'SQL'
-- MySQL dump 10.13  Distrib fixture
CREATE TABLE `wp_options` (`option_id` bigint NOT NULL);
INSERT INTO `wp_options` VALUES (1);
SQL
	PATH="$fixture/bin:/usr/bin:/bin" \
	FIXTURE_ROOT="$target" \
	FIXTURE_EXPECT_LOCK_DURING_CHOWN="${FIXTURE_EXPECT_LOCK_DURING_CHOWN:-0}" \
	ENVIRONMENT='staging' \
	LOCAL_URL='http://local.example.test' \
	REMOTE_URL='https://staging.example.test' \
	WP_DIR="$target/wp" \
	REPO_DIR="$target/repo" \
	BACKUP_DIR="$target/backups" \
	EXPECTED_WP_DIR="$target/wp" \
	EXPECTED_DB_NAME='wordpress_staging' \
	EXPECTED_DB_TABLE_PREFIX='wp_' \
	EXPECTED_REMOTE_DOMAIN='staging.example.test' \
	SYNC_PATHS='wp-content/themes/example-theme' \
	GIT_SSH_KEY="$target/id_ed25519" \
	PHP_BIN="$fixture/bin/php" \
	WP_CLI_BIN="$target/bin-wp" \
	KEEP_BACKUPS='10' \
	MIN_REMOTE_FREE_SPACE_MB='1' \
	DEPLOY_MODE='db' \
	SQL_FILE="$target/tmp/incoming.sql" \
	UPLOADS_ZIP='' \
	sh "$fixture/server-deploy.sh"
}

output="$(FIXTURE_ID_MODE=invalid run_root_db 2>&1 || true)"
case "$output" in
	*'Could not determine effective uid'*) ;;
	*) echo 'Invalid effective UID did not fail closed' >&2; exit 1 ;;
esac

cp "$config" "$config.saved"
grep -v '^SERVER_FILE_OWNER=' "$config.saved" > "$config.tmp"
mv "$config.tmp" "$config"
output="$(run_root_db 2>&1 || true)"
case "$output" in
	*'SERVER_FILE_OWNER is required for root execution'*) ;;
	*) echo 'Root execution accepted a missing owner policy' >&2; exit 1 ;;
esac
mv "$config.saved" "$config"

output="$(FIXTURE_EXPECT_LOCK_DURING_CHOWN=1 run_root_db 2>&1)"
case "$output" in
	*'WordPress deployment completed (db)'*) ;;
	*) echo 'Root database fixture did not complete' >&2; echo "$output" >&2; exit 1 ;;
esac
for path in "$target/wp/.htaccess" "$target/wp/wp-content/cache" "$target/wp/wp-content/upgrade"; do
	grep -F -- "$path" "$target/chown.log" >/dev/null || {
		echo "Ownership was not restored for $path" >&2
		exit 1
	}
done

rm -f "$target/chown.log"
if output="$(FIXTURE_EXPECT_LOCK_DURING_CHOWN=1 FIXTURE_CHOWN_FAIL=1 run_root_db 2>&1)"; then
	echo 'Failed ownership restoration returned success' >&2
	exit 1
fi
case "$output" in
	*'Could not restore the configured WordPress file owner/group'*) ;;
	*) echo 'Failed ownership restoration was not reported' >&2; exit 1 ;;
esac
case "$output" in
	*'WordPress deployment completed (db)'*) echo 'Success was reported after failed ownership restoration' >&2; exit 1 ;;
esac
[ ! -d "$target/lock/deploy.lock" ] || {
	echo 'Lock directory remained after failed ownership restoration' >&2
	exit 1
}

echo 'Root ownership policy and cleanup: OK'
