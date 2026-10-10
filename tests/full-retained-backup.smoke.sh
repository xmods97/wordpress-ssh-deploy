#!/usr/bin/env sh
set -eu

repo_dir="$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)"
fixture_dir="/tmp/wordpress-ssh-deploy-retained-backup-test-$$"
target_root="/tmp/wordpress-ssh-deploy-retained-backup-target-$$"
wp_dir="$target_root/wp"
repo_path="$target_root/repo"
tmp_dir="$target_root/tmp"
backup_dir="$target_root/backups"
bin_dir="$target_root/bin"
cleanup_fixture() {
	status=$?
	trap - 0 1 2 15
	rm -rf "$fixture_dir" "$target_root"
	exit "$status"
}
trap cleanup_fixture 0 1 2 15

mkdir -p "$fixture_dir" "$wp_dir/wp-content/themes/example-theme" "$wp_dir/wp-content/plugins/example-plugin" "$wp_dir/wp-content/mu-plugins" "$wp_dir/wp-content/uploads/2026/08" "$repo_path/.git" "$repo_path/wp-content/themes/example-theme" "$repo_path/wp-content/plugins/example-plugin" "$repo_path/wp-content/mu-plugins" "$tmp_dir" "$bin_dir"
cp "$repo_dir/server-deploy.sh" "$fixture_dir/server-deploy.sh"
: > "$wp_dir/wp-config.php"
: > "$target_root/id_ed25519"
printf '%s\n' 'old theme' > "$wp_dir/wp-content/themes/example-theme/style.css"
printf '%s\n' 'new theme' > "$repo_path/wp-content/themes/example-theme/style.css"
printf '%s\n' 'old plugin' > "$wp_dir/wp-content/plugins/example-plugin/plugin.php"
printf '%s\n' 'new plugin' > "$repo_path/wp-content/plugins/example-plugin/plugin.php"
printf '%s\n' 'old mu plugin' > "$wp_dir/wp-content/mu-plugins/example.php"
printf '%s\n' 'new mu plugin' > "$repo_path/wp-content/mu-plugins/example.php"
printf '%s\n' 'old upload' > "$wp_dir/wp-content/uploads/2026/08/image.txt"

cp "$repo_dir/tests/fixtures/fake-php.sh" "$bin_dir/php"
cp "$repo_dir/tests/fixtures/fake-id.sh" "$bin_dir/id"
cp "$repo_dir/tests/fixtures/fake-stat.sh" "$bin_dir/stat"
cp "$repo_dir/tests/fixtures/fake-chown.sh" "$bin_dir/chown"
cp "$repo_dir/tests/fixtures/fake-runuser.sh" "$bin_dir/runuser"
cp "$repo_dir/tests/fixtures/fake-df.sh" "$bin_dir/df"
cp "$repo_dir/tests/fixtures/fake-du.sh" "$bin_dir/du"
cp "$repo_dir/tests/fixtures/fake-git.sh" "$bin_dir/git"
cp "$repo_dir/tests/fixtures/fake-mysqldump.sh" "$bin_dir/mysqldump"
cp "$repo_dir/tests/fixtures/fake-mysql.sh" "$bin_dir/mysql"
cp "$repo_dir/tests/fixtures/fake-find.sh" "$bin_dir/find"
cp "$repo_dir/tests/fixtures/fake-unzip.sh" "$bin_dir/unzip"
cat > "$bin_dir/chmod" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$FIXTURE_ROOT/chmod-calls.log"
exec /usr/bin/chmod "$@"
EOF
: > "$bin_dir/wp"
: > "$tmp_dir/uploads-full.zip"
chmod 700 "$bin_dir"/*

cat > "$fixture_dir/server.config.sh" <<EOF
SERVER_ENVIRONMENT='production'
SERVER_ALLOW_PRODUCTION_FULL='1'
SERVER_EXPECTED_URL='https://example.com'
SERVER_EXPECTED_WP_DIR='$wp_dir'
SERVER_EXPECTED_REPO_DIR='$repo_path'
SERVER_EXPECTED_TMP_DIR='$tmp_dir'
SERVER_EXPECTED_BACKUP_DIR='$backup_dir'
SERVER_EXPECTED_DB_NAME='wordpress_production'
SERVER_GIT_SSH_KEY='$target_root/id_ed25519'
SERVER_PHP_BIN='$bin_dir/php'
SERVER_WP_CLI_BIN='$bin_dir/wp'
SERVER_SYNC_PATHS='wp-content/themes/example-theme'
SERVER_PLUGIN_SYNC_PATHS='wp-content/plugins/example-plugin'
SERVER_MU_PLUGIN_SYNC_PATHS='wp-content/mu-plugins/example.php'
SERVER_ALLOWED_DEPLOY_MODES='preflight,code,db,code-db,uploads,plugins,mu-plugins,full,components'
SERVER_KEEP_BACKUPS='10'
SERVER_MIN_FREE_SPACE_MB='1'
SERVER_LOCK_DIR='$target_root/lock/deploy.lock'
EOF

run_server() {
	mode="$1"
	PATH="$bin_dir:/usr/bin:/bin:/mingw64/bin" \
	FIXTURE_ROOT="$target_root" \
	FIXTURE_EFFECTIVE_UID=1000 \
	ENVIRONMENT='production' \
	LOCAL_URL='http://example.test' \
	REMOTE_URL='https://example.com' \
	WP_DIR="$wp_dir" \
	REPO_DIR="$repo_path" \
	BACKUP_DIR="$backup_dir" \
	EXPECTED_WP_DIR="$wp_dir" \
	EXPECTED_DB_NAME='wordpress_production' \
	EXPECTED_REMOTE_DOMAIN='example.com' \
	SYNC_PATHS='wp-content/themes/example-theme' \
	PLUGIN_SYNC_PATHS='wp-content/plugins/example-plugin' \
	MU_PLUGIN_SYNC_PATHS='wp-content/mu-plugins/example.php' \
	DEPLOY_COMPONENTS="${FIXTURE_DEPLOY_COMPONENTS:-}" \
	ALLOWED_DEPLOY_MODES='preflight,code,db,code-db,uploads,plugins,mu-plugins,full,components' \
	GIT_SSH_KEY="$target_root/id_ed25519" \
	PHP_BIN="$bin_dir/php" \
	WP_CLI_BIN="$bin_dir/wp" \
	KEEP_BACKUPS='10' \
	MIN_REMOTE_FREE_SPACE_MB='1' \
	UPLOADS_ZIP="$tmp_dir/uploads-full.zip" \
	SQL_FILE="${FIXTURE_SQL_FILE:-}" \
	UPLOADS_MANIFEST_FILE="${FIXTURE_UPLOADS_MANIFEST_FILE:-}" \
	PRODUCTION_FULL_OPT_IN=1 \
	DEPLOY_MODE="$mode" \
	sh "$fixture_dir/server-deploy.sh" 2>&1
}

low_space_output="$(FIXTURE_DF_AVAILABLE_KB=2048 run_server full || true)"
case "$low_space_output" in
	*'Retained component backup filesystem does not have enough free space'*) ;;
	*) echo 'Insufficient backup space did not stop before deployment' >&2; exit 1 ;;
esac
[ "$(cat "$wp_dir/wp-content/themes/example-theme/style.css")" = 'old theme' ] || { echo 'Theme changed despite the retained-backup space failure' >&2; exit 1; }
[ -z "$(find "$backup_dir" -mindepth 1 -maxdepth 1 -name '.component-backup-*.tmp' -print)" ] || { echo 'Failed backup staging directory was not cleaned' >&2; exit 1; }
[ -z "$(find "$backup_dir" -mindepth 1 -maxdepth 1 -name 'component-backup-*' -print)" ] || { echo 'Failed backup space check published an incomplete backup' >&2; exit 1; }

: > "$tmp_dir/uploads-full.zip"
full_output="$(run_server full || true)"
case "$full_output" in
	*'SQL dump is empty or missing'*) ;;
	*) echo 'Full fixture did not stop at the expected pre-database gate' >&2; echo "$full_output" >&2; exit 1 ;;
esac
backup_dir_created="$(printf '%s\n' "$full_output" | sed -n 's/^RETAINED_COMPONENT_BACKUP=//p' | tail -n 1)"
[ -n "$backup_dir_created" ] && [ -d "$backup_dir_created" ] || { echo 'Full run did not retain its component backup' >&2; exit 1; }
backup_line="$(printf '%s\n' "$full_output" | grep -n '^RETAINED_COMPONENT_BACKUP=' | head -n 1 | cut -d: -f1)"
replacement_line="$(printf '%s\n' "$full_output" | grep -n 'Theme ownership normalized' | head -n 1 | cut -d: -f1)"
[ "$backup_line" -lt "$replacement_line" ] || { echo 'Retained backup was not created before theme replacement' >&2; exit 1; }
(cd "$backup_dir_created" && sha256sum -c asset-backup.tar.sha256 >/dev/null) || { echo 'Retained component backup checksum failed' >&2; exit 1; }
grep -F '700 ' "$target_root/chmod-calls.log" >/dev/null || { echo 'Retained backup directory was not hardened to mode 700' >&2; exit 1; }
grep -F '600 ' "$target_root/chmod-calls.log" >/dev/null || { echo 'Retained backup files were not hardened to mode 600' >&2; exit 1; }
grep -F 'root:root' "$target_root/chown-calls.log" >/dev/null || { echo 'Retained backup artifacts were not assigned to root' >&2; exit 1; }

restore_root="$fixture_dir/restore"
mkdir -p "$restore_root"
cp -R "$wp_dir/wp-content" "$restore_root/"
tab="$(printf '\t')"
while IFS="$tab" read -r record state type relative; do
	[ "$record" = target ] || continue
		case "$relative" in wp-content/themes/*|wp-content/plugins/*|wp-content/mu-plugins/*|wp-content/uploads) ;; *) echo 'Backup manifest contains an unexpected restore path' >&2; exit 1 ;; esac
	case "$state" in
		present)
			rm -rf -- "$restore_root/$relative"
			tar -C "$restore_root" -xpf "$backup_dir_created/asset-backup.tar" -- "$relative"
			;;
		absent) rm -rf -- "$restore_root/$relative" ;;
		*) echo 'Backup manifest contains an invalid target state' >&2; exit 1 ;;
	esac
done < "$backup_dir_created/manifest.tsv"
[ "$(cat "$restore_root/wp-content/themes/example-theme/style.css")" = 'old theme' ] || { echo 'Theme restore from the retained archive failed' >&2; exit 1; }
[ "$(cat "$restore_root/wp-content/plugins/example-plugin/plugin.php")" = 'old plugin' ] || { echo 'Plugin restore from the retained archive failed' >&2; exit 1; }
[ "$(cat "$restore_root/wp-content/mu-plugins/example.php")" = 'old mu plugin' ] || { echo 'MU-plugin restore from the retained archive failed' >&2; exit 1; }
[ "$(cat "$restore_root/wp-content/uploads/2026/08/image.txt")" = 'old upload' ] || { echo 'Uploads restore from the retained archive failed' >&2; exit 1; }

for old_backup in component-backup-20000101-000000-1 component-backup-20000102-000000-2; do
	mkdir -p "$backup_dir/$old_backup"
	printf '%s\n' 'old archive' > "$backup_dir/$old_backup/asset-backup.tar"
	printf '%s\n' 'fixture manifest' > "$backup_dir/$old_backup/manifest.tsv"
	(cd "$backup_dir/$old_backup" && sha256sum asset-backup.tar > asset-backup.tar.sha256)
done

: > "$tmp_dir/uploads-full.zip"
cat > "$tmp_dir/components.sql" <<'SQL'
-- MySQL dump 10.13  Distrib fixture
-- Table structure for table `wp_options`
CREATE TABLE `wp_options` (`option_id` bigint NOT NULL);
INSERT INTO `wp_options` VALUES (2);
SQL
printf '%s\t%s\t%s\n' "$(printf 'new upload\n' | sha256sum | awk '{ print $1 }')" '11' '2026/08/new-upload.txt' > "$tmp_dir/uploads-manifest.tsv"
code_output="$(FIXTURE_SQL_FILE="$tmp_dir/components.sql" FIXTURE_UPLOADS_MANIFEST_FILE="$tmp_dir/uploads-manifest.tsv" FIXTURE_DEPLOY_COMPONENTS='code,db,uploads,plugins,mu-plugins' run_server components)"
case "$code_output" in
	*'WordPress deployment completed (components)'*) ;;
	*) echo 'All-component deployment fixture did not complete successfully' >&2; echo "$code_output" >&2; exit 1 ;;
esac
[ "$(cat "$wp_dir/wp-content/themes/example-theme/style.css")" = 'new theme' ] || { echo 'Combined component deployment did not replace theme code' >&2; exit 1; }
[ "$(cat "$wp_dir/wp-content/plugins/example-plugin/plugin.php")" = 'new plugin' ] || { echo 'Combined component deployment did not replace plugin code' >&2; exit 1; }
[ "$(cat "$wp_dir/wp-content/mu-plugins/example.php")" = 'new mu plugin' ] || { echo 'Combined component deployment did not replace MU-plugin code' >&2; exit 1; }
[ -f "$wp_dir/wp-content/uploads/2026/08/new-upload.txt" ] && [ ! -e "$wp_dir/wp-content/uploads/2026/08/image.txt" ] || { echo 'Combined component deployment did not replace uploads as a full snapshot' >&2; exit 1; }
[ "$(wc -l < "$target_root/mysql-calls.log" | awk '{ print $1 }')" -eq 1 ] || { echo 'Combined component deployment did not execute one SQL import' >&2; exit 1; }
[ -s "$backup_dir/uploads-manifest.tsv" ] || { echo 'Combined component deployment did not install the verified uploads manifest' >&2; exit 1; }
grep -Fq 'mode=full' "$backup_dir/uploads-transactions.log" || { echo 'Combined component deployment did not record the full uploads transaction' >&2; exit 1; }
find "$backup_dir" -maxdepth 1 -type f -name 'db-*.sql.gz' -print | grep -q . || { echo 'Combined component deployment did not retain its database backup' >&2; exit 1; }
backup_count="$(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name 'component-backup-*' -print | wc -l | awk '{ print $1 }')"
[ "$backup_count" -eq 2 ] || { echo "Retained backup retention count was $backup_count, expected 2" >&2; exit 1; }
[ ! -e "$backup_dir/component-backup-20000101-000000-1" ] && [ ! -e "$backup_dir/component-backup-20000102-000000-2" ] || { echo 'Old retained backups were not pruned after successful deployment' >&2; exit 1; }

printf '%s\n' 'All five components, full uploads manifest and retained backup: OK'
