#!/usr/bin/env sh
set -eu

repo_dir="$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)"
fixture_dir="${TMPDIR:-/tmp}/wordpress-ssh-deploy-server-test-$$"
target_root='/tmp/wordpress-ssh-deploy-fixture'
mkdir -p "$fixture_dir"
cleanup_fixture() {
	status=$?
	trap - 0 1 2 15
	rm -rf "$fixture_dir" "$target_root"
	exit "$status"
}
trap cleanup_fixture 0 1 2 15

cp "$repo_dir/server-deploy.sh" "$fixture_dir/server-deploy.sh"
cp "$repo_dir/tests/fixtures/server.config.production.sh" "$fixture_dir/server.config.sh"

run_server() {
	PATH="$target_root/bin:/usr/bin:/bin:/mingw64/bin" \
	FIXTURE_ROOT="$target_root" \
	ENVIRONMENT="$1" \
	REMOTE_URL='https://example.com' \
	WP_DIR='/tmp/wordpress-ssh-deploy-fixture/wp' \
	REPO_DIR='/tmp/wordpress-ssh-deploy-fixture/repo' \
	BACKUP_DIR='/tmp/wordpress-ssh-deploy-fixture/backups' \
	EXPECTED_WP_DIR='/tmp/wordpress-ssh-deploy-fixture/wp' \
	EXPECTED_DB_NAME='wordpress_production' \
	EXPECTED_REMOTE_DOMAIN='example.com' \
	SYNC_PATHS='wp-content/themes/example-theme' \
	PLUGIN_SYNC_PATHS='' \
	MU_PLUGIN_SYNC_PATHS='' \
	ALLOWED_DEPLOY_MODES="${FIXTURE_ALLOWED_DEPLOY_MODES:-preflight,code,full}" \
	GIT_SSH_KEY='/tmp/wordpress-ssh-deploy-fixture/id_ed25519' \
	PHP_BIN='/tmp/wordpress-ssh-deploy-fixture/bin/php' \
	WP_CLI_BIN='/tmp/wordpress-ssh-deploy-fixture/bin/wp' \
	FIXTURE_PHP_BASE='/tmp/wordpress-ssh-deploy-fixture/bin/php-base' \
	KEEP_BACKUPS='10' \
	MIN_REMOTE_FREE_SPACE_MB='1' \
	SQL_FILE="${FIXTURE_SQL_FILE:-}" \
	UPLOADS_ZIP="${FIXTURE_UPLOADS_ZIP:-}" \
	UPLOADS_MANIFEST_FILE="${FIXTURE_UPLOADS_MANIFEST_FILE:-}" \
	DEPLOY_COMPONENTS="${FIXTURE_DEPLOY_COMPONENTS:-}" \
	PRODUCTION_FULL_OPT_IN="${FIXTURE_PRODUCTION_FULL_OPT_IN-${PRODUCTION_FULL_OPT_IN:-0}}" \
	DEPLOY_MODE="$2" \
	sh "$fixture_dir/server-deploy.sh" 2>&1
}

output="$(run_server production db || true)"
case "$output" in
	*'Deploy mode is not enabled by profile policy'*) ;;
	*) echo "Production DB mode was not rejected by profile policy" >&2; exit 1 ;;
esac

cp "$fixture_dir/server.config.sh" "$fixture_dir/server.config.explicit.sh"
grep -v '^SERVER_ALLOWED_DEPLOY_MODES=' "$fixture_dir/server.config.explicit.sh" > "$fixture_dir/server.config.sh"
output="$(FIXTURE_ALLOWED_DEPLOY_MODES='preflight,code,db' run_server production db || true)"
case "$output" in
	*'Deploy mode is not enabled by server policy'*) ;;
	*) echo "Legacy production server policy did not fail closed for DB mode" >&2; exit 1 ;;
esac
mv "$fixture_dir/server.config.explicit.sh" "$fixture_dir/server.config.sh"

output="$(FIXTURE_ALLOWED_DEPLOY_MODES='preflight,code,db,code-db,uploads,plugins,full' run_server production db || true)"
case "$output" in
	*'WordPress configuration was not found'*) ;;
	*) echo "Explicit production DB capability did not pass mode policy" >&2; exit 1 ;;
esac

output="$(FIXTURE_ALLOWED_DEPLOY_MODES='preflight,code,db,code-db,uploads,plugins,full' run_server production plugins || true)"
case "$output" in
	*'Plugins mode requires configured plugin sync paths'*) ;;
	*) echo "Plugins mode did not reject an empty plugin allowlist" >&2; exit 1 ;
esac

output="$(FIXTURE_ALLOWED_DEPLOY_MODES='preflight,code,db,code-db,uploads,plugins,mu-plugins,full' run_server production mu-plugins || true)"
case "$output" in
	*'Mu-plugins mode requires configured mu-plugin sync paths'*) ;;
	*) echo "MU-plugins mode did not reject an empty MU-plugin allowlist" >&2; exit 1 ;;
esac

output="$(FIXTURE_ALLOWED_DEPLOY_MODES='preflight,code' FIXTURE_DEPLOY_COMPONENTS='code' run_server production components || true)"
case "$output" in
	*'Deploy mode is not enabled by profile policy'*) ;;
	*) echo "Components mode was not rejected by the profile policy" >&2; exit 1 ;;
esac

output="$(FIXTURE_ALLOWED_DEPLOY_MODES='preflight,components' FIXTURE_DEPLOY_COMPONENTS='plugins' run_server production components || true)"
case "$output" in
	*'Components mode requires configured plugin sync paths'*) ;;
	*) echo "Components mode did not reject an empty plugin allowlist" >&2; exit 1 ;;
esac

output="$(FIXTURE_ALLOWED_DEPLOY_MODES='preflight,components' FIXTURE_DEPLOY_COMPONENTS='code,db,uploads' run_server production components || true)"
case "$output" in
	*'Production component selection requires an explicit client profile opt-in'*) ;;
	*) echo "Full-equivalent components did not require the production opt-in" >&2; exit 1 ;;
esac

output="$(FIXTURE_ALLOWED_DEPLOY_MODES='preflight,components' FIXTURE_DEPLOY_COMPONENTS='code,db,uploads' FIXTURE_PRODUCTION_FULL_OPT_IN=1 run_server production components || true)"
case "$output" in
	*'Production component selection is disabled by server policy'*) ;;
	*) echo "Full-equivalent components bypassed the server production policy" >&2; exit 1 ;;
esac

output="$(FIXTURE_ALLOWED_DEPLOY_MODES='preflight,code,unknown' run_server production code || true)"
case "$output" in
	*'Invalid profile deploy mode policy'*) ;;
	*) echo "Unknown profile mode was not rejected" >&2; exit 1 ;;
esac

output="$(run_server production full || true)"
case "$output" in
	*'Production full mode requires an explicit client profile opt-in'*) ;;
	*) echo "Production full mode was not rejected without client opt-in" >&2; exit 1 ;;
esac

output="$(PRODUCTION_FULL_OPT_IN=1 run_server production full || true)"
case "$output" in
	*'Production full mode is disabled by server policy'*) ;;
	*) echo "Production full mode was not rejected without server opt-in" >&2; exit 1 ;;
esac

output="$(run_server staging code || true)"
case "$output" in
	*'Environment does not match server policy'*) ;;
	*) echo "Server environment mismatch was not rejected correctly" >&2; exit 1 ;;
esac

mkdir -p "$target_root/wp/wp-content/themes/example-theme" "$target_root/wp/wp-content/uploads/2026/01" "$target_root/repo/.git" "$target_root/tmp" "$target_root/bin"
mkdir -p "$target_root/tmp/nested/deeper"
: > "$target_root/wp/wp-config.php"
: > "$target_root/id_ed25519"
: > "$target_root/tmp/local-db-stale.sql"
touch -t 202001010000 "$target_root/tmp/local-db-stale.sql"
: > "$target_root/tmp/preflight-input.sql"
printf '%s\n' 'nested temporary fixture' > "$target_root/tmp/nested/inventory.txt"
printf '%s\n' 'depth limit fixture' > "$target_root/tmp/nested/deeper/ignored.txt"
cp "$repo_dir/tests/fixtures/fake-php.sh" "$target_root/bin/php-base"
cat > "$target_root/bin/php" <<'EOF'
#!/usr/bin/env sh
case " $* " in
	*' db tables --all-tables '*) printf '%s\n' 'wp_options' 'wp_posts'; exit 0 ;;
esac
exec "$FIXTURE_PHP_BASE" "$@"
EOF
chmod +x "$target_root/bin/php"
printf '%s\n' 'theme inventory fixture' > "$target_root/wp/wp-content/themes/example-theme/target-theme.txt"
printf '%s\n' 'uploads inventory fixture' > "$target_root/wp/wp-content/uploads/2026/01/target-upload.jpg"
cp "$repo_dir/tests/fixtures/fake-id.sh" "$target_root/bin/id"
cp "$repo_dir/tests/fixtures/fake-stat.sh" "$target_root/bin/stat"
cp "$repo_dir/tests/fixtures/fake-chown.sh" "$target_root/bin/chown"
cp "$repo_dir/tests/fixtures/fake-chmod.sh" "$target_root/bin/chmod"
cp "$repo_dir/tests/fixtures/fake-runuser.sh" "$target_root/bin/runuser"
cp "$repo_dir/tests/fixtures/fake-df.sh" "$target_root/bin/df"
cp "$repo_dir/tests/fixtures/fake-du.sh" "$target_root/bin/du"
cp "$repo_dir/tests/fixtures/fake-git.sh" "$target_root/bin/git"
cp "$repo_dir/tests/fixtures/fake-find.sh" "$target_root/bin/find"
cp "$repo_dir/tests/fixtures/fake-unzip.sh" "$target_root/bin/unzip-fixture"
cat > "$target_root/bin/unzip" <<'UNZIP_ENV_FIXTURE'
#!/usr/bin/env sh
set -eu
[ "${LC_ALL:-}" = C ] && [ "${LANG:-}" = C ] || { echo 'unzip locale was not normalized' >&2; exit 1; }
[ -z "${UNZIP+x}${UNZIPOPT+x}${ZIPINFO+x}${ZIPINFOOPT+x}" ] || { echo 'unzip inherited options were not cleared' >&2; exit 1; }
exec "$FIXTURE_ROOT/bin/unzip-fixture" "$@"
UNZIP_ENV_FIXTURE
chmod +x "$target_root/bin/unzip" "$target_root/bin/unzip-fixture"
: > "$target_root/bin/wp"

cp "$fixture_dir/server.config.sh" "$fixture_dir/server.config.inventory-default.sh"
sed "s/SERVER_ALLOW_PRODUCTION_FULL='0'/SERVER_ALLOW_PRODUCTION_FULL='1'/" "$fixture_dir/server.config.inventory-default.sh" > "$fixture_dir/server.config.sh"
output="$(FIXTURE_EFFECTIVE_UID=1000 FIXTURE_SQL_FILE="$target_root/tmp/preflight-input.sql" run_server production preflight)"
case "$output" in
	*'WordPress deployment completed (preflight)'*) ;;
	*) echo 'Preflight did not complete correctly' >&2; exit 1 ;;
esac
case "$output" in
	*'INVENTORY_BEGIN'*'INVENTORY_POLICY'*'full_optin=1'*'INVENTORY_END'*) ;;
	*) echo 'Read-only full-mode inventory was incomplete' >&2; exit 1 ;;
esac
printf '%s\n' "$output" | grep -Fq "$(printf 'INVENTORY_DB_TABLE\twp_options')" || { echo 'Database table names were missing from the inventory' >&2; exit 1; }
theme_sha256="$(sha256sum "$target_root/wp/wp-content/themes/example-theme/target-theme.txt" | awk '{ print $1 }')"
uploads_sha256="$(sha256sum "$target_root/wp/wp-content/uploads/2026/01/target-upload.jpg" | awk '{ print $1 }')"
printf '%s\n' "$output" | grep -Fq "$(printf 'INVENTORY_FILE\ttheme\twp-content/themes/example-theme/target-theme.txt\tfile\t24\t%s' "$theme_sha256")" || { echo 'Theme file path, size, or SHA-256 was missing from the inventory' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq "$(printf 'INVENTORY_FILE\tuploads\twp-content/uploads/2026/01/target-upload.jpg\tfile\t26\t%s' "$uploads_sha256")" || { echo 'Uploads file path, size, or SHA-256 was missing from the inventory' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq "$(printf 'INVENTORY_TMP_BEGIN\tpath=%s\tmax_depth=2\tmax_entries=200' "$target_root/tmp")" || { echo 'Temporary inventory bounds were missing' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq "$(printf 'INVENTORY_TMP\tregular file\t%s\t' "$(wc -c < "$target_root/tmp/nested/inventory.txt" | awk '{ print $1 }')")" || { echo 'Temporary file type or size was missing' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq "'$target_root/tmp/nested/inventory.txt'" || { echo 'Nested temporary file name was missing' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq "'$target_root/tmp/nested'" || { echo 'Temporary directory metadata was missing' >&2; exit 1; }
case "$output" in *'ignored.txt'*) echo 'Temporary inventory exceeded its maximum depth' >&2; exit 1 ;; esac
tmp_inventory_count="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "INVENTORY_TMP" { count++ } END { print count + 0 }')"
[ "$tmp_inventory_count" -eq 5 ] || { echo 'Temporary inventory did not report exactly the depth-limited fixture entries' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq "$(printf 'INVENTORY_TMP_TRUNCATED\t0')" || { echo 'Complete temporary inventory was marked truncated' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq "$(printf 'INVENTORY_BACKUP_DIR\tmissing')" || { echo 'Missing backup directory state was not reported' >&2; exit 1; }
printf '%s\n' "$output" | grep -Eq '^INVENTORY_RUNNER.*sha256=[0-9a-f]{64}$' || { echo 'Inventory runner SHA-256 was missing or malformed' >&2; exit 1; }
[ -f "$target_root/tmp/local-db-stale.sql" ] || { echo 'Preflight removed a stale temporary artifact' >&2; exit 1; }
[ -f "$target_root/tmp/preflight-input.sql" ] || { echo 'Preflight exit cleanup removed an input artifact' >&2; exit 1; }
[ ! -e "$target_root/lock" ] || { echo 'Preflight created a lock directory' >&2; exit 1; }
[ ! -e "$target_root/backups" ] || { echo 'Preflight created a backup directory' >&2; exit 1; }

mkdir -p "$target_root/backups/component-backup-fixture"
printf '%s\n' 'existing backup metadata' > "$target_root/backups/component-backup-fixture/manifest.tsv"
index=1
while [ "$index" -le 10 ]; do
	backup_name="db-20261010-0000$(printf '%02d' "$index").sql"
	printf '%s\n' "$backup_name" > "$target_root/backups/$backup_name"
	index=$((index + 1))
done
index=1
while [ "$index" -le 3 ]; do
	backup_name="component-backup-retention-$(printf '%02d' "$index")"
	mkdir -p "$target_root/backups/$backup_name"
	printf '%s\n' 'archive fixture' > "$target_root/backups/$backup_name/asset-backup.tar"
	printf '%s\n' 'manifest fixture' > "$target_root/backups/$backup_name/manifest.tsv"
	backup_sha256="$(cd "$target_root/backups/$backup_name" && sha256sum asset-backup.tar | awk '{ print $1 }')"
	printf '%s  asset-backup.tar\n' "$backup_sha256" > "$target_root/backups/$backup_name/asset-backup.tar.sha256"
	index=$((index + 1))
done
mkdir -p "$target_root/tmp/bulk"
index=1
while [ "$index" -le 205 ]; do
	: > "$target_root/tmp/bulk/file-$index"
	index=$((index + 1))
done
output="$(FIXTURE_EFFECTIVE_UID=1000 run_server production preflight)"
tmp_inventory_count="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "INVENTORY_TMP" { count++ } END { print count + 0 }')"
[ "$tmp_inventory_count" -eq 200 ] || { echo 'Temporary inventory exceeded or missed its entry limit' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq "$(printf 'INVENTORY_TMP_TRUNCATED\t1')" || { echo 'Oversized temporary inventory was not marked truncated' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq "$(printf 'INVENTORY_BACKUP\tcomponent-backup-fixture/manifest.tsv')" || { echo 'Existing backup files were not inventoried' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq "$(printf 'INVENTORY_RETENTION_PREVIEW\tafter=successful_full_release\tnew_db_backup=1\tnew_asset_backup=1\tkeep_db=10\tkeep_assets=2')" || { echo 'Successful full-release backup retention assumptions were missing' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq "$(printf 'INVENTORY_DB_BACKUP_RETENTION\tdb-20261010-000001.sql\tprune_after_success')" || { echo 'Oldest database backup prune preview was incorrect' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq "$(printf 'INVENTORY_COMPONENT_BACKUP_RETENTION\tcomponent-backup-retention-01\tprune_after_success')" || { echo 'Asset backup prune preview was incorrect' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq "$(printf 'INVENTORY_COMPONENT_BACKUP_RETENTION\tcomponent-backup-fixture\tineligible_not_pruned')" || { echo 'Invalid asset backup was not protected from retention deletion' >&2; exit 1; }
[ -f "$target_root/backups/component-backup-fixture/manifest.tsv" ] || { echo 'Preflight changed an existing backup file' >&2; exit 1; }
[ -f "$target_root/backups/db-20261010-000001.sql" ] || { echo 'Preflight deleted a database backup while previewing retention' >&2; exit 1; }
[ -f "$target_root/backups/component-backup-retention-01/asset-backup.tar" ] || { echo 'Preflight deleted an asset backup while previewing retention' >&2; exit 1; }
[ ! -e "$target_root/lock" ] || { echo 'Inventory preflight created a lock directory' >&2; exit 1; }

# Windows PowerShell WriteAllLines emits CRLF; the remote validator must normalize its path field.
uploads_zip="$target_root/tmp/uploads-crlf.zip"
uploads_manifest="$target_root/tmp/uploads-crlf.tsv"
expected_upload="$target_root/tmp/expected-upload.txt"
printf '%s\n' 'archive fixture' > "$uploads_zip"
printf '%s\n' 'new upload' > "$expected_upload"
uploads_sha256="$(sha256sum "$expected_upload" | awk '{ print $1 }')"
uploads_size="$(wc -c < "$expected_upload" | tr -d ' ')"
printf '%s\t%s\t%s\r\n' "$uploads_sha256" "$uploads_size" '2026/08/new-upload.txt' > "$uploads_manifest"
zip_input_bytes="$(stat -c '%s' "$uploads_zip")"
zip_input_sha="$(sha256sum "$uploads_zip" | awk '{print $1}')"
manifest_input_bytes="$(stat -c '%s' "$uploads_manifest")"
manifest_input_sha="$(sha256sum "$uploads_manifest" | awk '{print $1}')"
output="$(UNZIP=-U UNZIPOPT=-U ZIPINFO=-U ZIPINFOOPT=-U FIXTURE_ALLOWED_DEPLOY_MODES='preflight,uploads' FIXTURE_PRODUCTION_FULL_OPT_IN=1 FIXTURE_EFFECTIVE_UID=1000 FIXTURE_UPLOADS_ZIP="$uploads_zip" FIXTURE_UPLOADS_MANIFEST_FILE="$uploads_manifest" run_server production uploads || true)"
printf '%s\n' "$output" | grep -Fq "$(printf 'UPLOADS_INPUT\tkind=zip\tpath=%s\tbytes=%s\tsha256=%s' "$uploads_zip" "$zip_input_bytes" "$zip_input_sha")" || { echo 'ZIP input readback mismatch' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq "$(printf 'UPLOADS_INPUT\tkind=manifest\tpath=%s\tbytes=%s\tsha256=%s' "$uploads_manifest" "$manifest_input_bytes" "$manifest_input_sha")" || { echo 'Manifest input readback mismatch' >&2; exit 1; }
case "$output" in
	*'WordPress deployment completed (uploads)'*) ;;
	*) printf '%s\n' "$output" >&2; echo 'CRLF uploads manifest was rejected' >&2; exit 1 ;;
esac
[ -f "$target_root/wp/wp-content/uploads/2026/08/new-upload.txt" ] || { echo 'CRLF uploads manifest did not complete the atomic replacement' >&2; exit 1; }
[ "$(sha256sum "$target_root/wp/wp-content/uploads/2026/08/new-upload.txt" | awk '{ print $1 }')" = "$uploads_sha256" ] || { echo 'CRLF uploads manifest changed the payload contents' >&2; exit 1; }

printf '%s\n' 'archive fixture' > "$uploads_zip"
printf '%s\t%s\t%s\r\n' "$(printf '%064d' 0)" "$uploads_size" '2026/08/new-upload.txt' > "$uploads_manifest"
output="$(UNZIP=-U UNZIPOPT=-U ZIPINFO=-U ZIPINFOOPT=-U FIXTURE_ALLOWED_DEPLOY_MODES='preflight,uploads' FIXTURE_PRODUCTION_FULL_OPT_IN=1 FIXTURE_EFFECTIVE_UID=1000 FIXTURE_UPLOADS_ZIP="$uploads_zip" FIXTURE_UPLOADS_MANIFEST_FILE="$uploads_manifest" run_server production uploads || true)"
case "$output" in
	*'Uploads manifest verification failed'*) ;;
	*) printf '%s\n' "$output" >&2; echo 'Invalid uploads manifest did not fail verification' >&2; exit 1 ;;
esac
printf '%s\n' "$output" | grep -Fq "$(printf 'UPLOADS_MANIFEST_VERIFY_FAIL\trow=1\tpredicate=sha256\tpath=2026/08/new-upload.txt\texpected=%s\tactual=%s' "$(printf '%064d' 0)" "$uploads_sha256")" || { echo 'First hash failure diagnostic missing' >&2; exit 1; }
[ "$(printf '%s\n' "$output" | grep -c '^UPLOADS_MANIFEST_VERIFY_FAIL')" -eq 1 ] || { echo 'Multiple first-failure diagnostics' >&2; exit 1; }

# Exercise the exact validator without additional deployment runs.
sed -n '/^manifest_verify_failure() {/,/^install_uploads_manifest() {/p' "$repo_dir/server-deploy.sh" | sed '$d' > "$fixture_dir/validator.sh"
. "$fixture_dir/validator.sh"
validator_root="$fixture_dir/validator-tree"
mkdir -p "$validator_root"
printf 'a' > "$validator_root/a"
printf 'b' > "$validator_root/b"
a_sha="$(sha256sum "$validator_root/a" | awk '{print $1}')"
b_sha="$(sha256sum "$validator_root/b" | awk '{print $1}')"
for predicate_case in file size order count; do
	case "$predicate_case" in
		file) printf '%s\t1\tmissing\n' "$a_sha" > "$fixture_dir/check.tsv" ;;
		size) printf '%s\t2\ta\n' "$a_sha" > "$fixture_dir/check.tsv" ;;
		order) printf '%s\t1\tb\n%s\t1\ta\n' "$b_sha" "$a_sha" > "$fixture_dir/check.tsv" ;;
		count) printf '%s\t1\ta\n' "$a_sha" > "$fixture_dir/check.tsv" ;;
	esac
	if diagnostic="$(validate_uploads_manifest_tree "$fixture_dir/check.tsv" "$validator_root" 2>&1)"; then echo 'Invalid validator fixture passed' >&2; exit 1; fi
	printf '%s\n' "$diagnostic" | grep -Fq "predicate=$predicate_case" || { echo "Missing $predicate_case diagnostic" >&2; exit 1; }
	[ "$(printf '%s\n' "$diagnostic" | grep -c '^UPLOADS_MANIFEST_VERIFY_FAIL')" -eq 1 ] || exit 1
done
[ ! -e "$target_root/wp/wp-content/.deploy-transient/uploads.__new__" ] || { echo 'Failed uploads extraction staging was not cleaned' >&2; exit 1; }
[ -z "$(find "$target_root/wp/wp-content/.deploy-transient" -mindepth 1 -print -quit)" ] || { echo 'Failed uploads left files in the transient directory' >&2; exit 1; }
[ -f "$target_root/wp/wp-content/uploads/2026/08/new-upload.txt" ] || { echo 'Failed uploads changed the existing uploads directory' >&2; exit 1; }
[ "$(sha256sum "$target_root/wp/wp-content/uploads/2026/08/new-upload.txt" | awk '{ print $1 }')" = "$uploads_sha256" ] || { echo 'Failed uploads changed existing upload contents' >&2; exit 1; }
[ ! -e "$uploads_zip" ] && [ ! -e "$uploads_manifest" ] || { echo 'Failed uploads left remote payload files in the temporary directory' >&2; exit 1; }

mv "$fixture_dir/server.config.inventory-default.sh" "$fixture_dir/server.config.sh"

mkdir -p "$target_root/repo/wp-content/themes/example-theme"
printf '%s\n' 'managed source' > "$target_root/repo/wp-content/themes/example-theme/style.css"
printf '%s\n' 'production-only' > "$target_root/wp/wp-content/themes/example-theme/production-only.txt"
output="$(FIXTURE_EFFECTIVE_UID=1000 run_server production code || true)"
case "$output" in
	*'PRODUCTION_EXTRA_FILES component=code'*'PRODUCTION_EXTRA_FILE=production-only.txt'*) ;;
	*) echo 'Production-only code file did not fail closed with an exact warning' >&2; exit 1 ;;
esac
[ -f "$target_root/wp/wp-content/themes/example-theme/production-only.txt" ] || { echo 'Production-only file was removed during warning' >&2; exit 1; }

output="$(FIXTURE_EFFECTIVE_UID=1000 FIXTURE_FIND_FAIL=1 FIXTURE_FIND_FAIL_DIR="$target_root/wp/wp-content/themes/example-theme" run_server production code || true)"
case "$output" in
	*'production manifest failed'*) ;;
	*) echo 'find failure did not fail closed before replacement' >&2; exit 1 ;;
esac
[ -f "$target_root/wp/wp-content/themes/example-theme/production-only.txt" ] || { echo 'Production-only file was removed after find failure' >&2; exit 1; }

output="$(FIXTURE_EFFECTIVE_UID=1000 run_server production preflight)"
case "$output" in
	*'WordPress deployment completed (preflight)'*) ;;
	*) echo 'Non-root preflight did not complete correctly' >&2; exit 1 ;;
esac

FIXTURE_EFFECTIVE_UID=1000 run_server production code >/dev/null 2>&1 || true
[ ! -d "$target_root/lock/deploy.lock" ] || { echo 'Lock directory remained after a failed operation' >&2; exit 1; }

echo 'Remote production policy: OK'
echo 'Remote lock cleanup: OK'
echo 'Remote preflight purity: OK'
echo 'Remote WP-CLI root guard: OK'
