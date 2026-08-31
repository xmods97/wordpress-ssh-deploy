#!/usr/bin/env sh
set -eu

repo_dir="$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)"
fixture_dir="${TMPDIR:-/tmp}/wordpress-ssh-deploy-uploads-owner-runner-$$"
target_root='/tmp/wordpress-ssh-deploy-owner-fixture'
mkdir -p "$fixture_dir"
trap 'rm -rf "$fixture_dir" "$target_root"' 0 1 2 15

cp "$repo_dir/server-deploy.sh" "$fixture_dir/server-deploy.sh"
cp "$repo_dir/tests/fixtures/server.config.owner.sh" "$fixture_dir/server.config.sh"
mkdir -p "$target_root/wp/wp-content/uploads/2026/07" "$target_root/repo/.git" \
	"$target_root/tmp" "$target_root/backups" "$target_root/bin"
: > "$target_root/wp/wp-config.php"
: > "$target_root/id_ed25519"
: > "$target_root/bin/wp"
cp "$repo_dir/tests/fixtures/fake-php.sh" "$target_root/bin/php"
cp "$repo_dir/tests/fixtures/fake-df.sh" "$target_root/bin/df"
cp "$repo_dir/tests/fixtures/fake-stat.sh" "$target_root/bin/stat"
cp "$repo_dir/tests/fixtures/fake-chown.sh" "$target_root/bin/chown"
cp "$repo_dir/tests/fixtures/fake-id.sh" "$target_root/bin/id"
cp "$repo_dir/tests/fixtures/fake-runuser.sh" "$target_root/bin/runuser"
cp "$repo_dir/tests/fixtures/fake-unzip.sh" "$target_root/bin/unzip"
chmod +x "$target_root/bin/runuser" "$target_root/bin/unzip"
printf '%s\n' 'old upload' > "$target_root/wp/wp-content/uploads/2026/07/old.txt"

run_runner() {
	uid="$1"
	uploads_zip="$2"
	chown_fail="${3:-0}"
	PATH="$target_root/bin:/usr/bin:/bin" \
	FIXTURE_ROOT="$target_root" \
	FIXTURE_EFFECTIVE_UID="$uid" \
	FIXTURE_CHOWN_FAIL="$chown_fail" \
	FIXTURE_SERVER_PLUGIN_SYNC_PATHS='' \
	FIXTURE_ENVIRONMENT='staging' \
	FIXTURE_URL='https://owner.example.com' \
	FIXTURE_DB_NAME='wordpress_owner_fixture' \
	ENVIRONMENT='staging' LOCAL_URL='http://owner.local' REMOTE_URL='https://owner.example.com' \
	WP_DIR="$target_root/wp" REPO_DIR="$target_root/repo" BACKUP_DIR="$target_root/backups" \
	EXPECTED_WP_DIR="$target_root/wp" EXPECTED_DB_NAME='wordpress_owner_fixture' EXPECTED_REMOTE_DOMAIN='owner.example.com' \
	SYNC_PATHS='wp-content/themes/bella-maria-child' PLUGIN_SYNC_PATHS='' \
	ALLOWED_DEPLOY_MODES='preflight,code,db,code-db,uploads,plugins,full' \
	GIT_SSH_KEY="$target_root/id_ed25519" PHP_BIN="$target_root/bin/php" WP_CLI_BIN="$target_root/bin/wp" \
	KEEP_BACKUPS='10' MIN_REMOTE_FREE_SPACE_MB='1' DEPLOY_MODE='uploads' SQL_FILE='' UPLOADS_ZIP="$uploads_zip" \
	sh "$fixture_dir/server-deploy.sh" 2>&1
}

: > "$target_root/tmp/uploads-fixture.zip"
: > "$target_root/chown-calls.log"
root_output="$(run_runner 0 "$target_root/tmp/uploads-fixture.zip")"
case "$root_output" in *'Uploads ownership normalized to admin_nadry:admin_nadry'*) ;; *) echo "$root_output" >&2; exit 1 ;; esac
grep -Fq -- "-R -- admin_nadry:admin_nadry $target_root/wp/wp-content/uploads" "$target_root/chown-calls.log"
[ -f "$target_root/wp/wp-content/uploads/2026/08/new-upload.txt" ] || { echo 'Root uploads mode did not replace uploads tree' >&2; exit 1; }
[ ! -e "$target_root/wp/wp-content/uploads/2026/07/old.txt" ] || { echo 'Root uploads mode retained old uploads tree' >&2; exit 1; }

: > "$target_root/tmp/uploads-fixture.zip"
: > "$target_root/chown-calls.log"
nonroot_output="$(run_runner 1000 "$target_root/tmp/uploads-fixture.zip")"
case "$nonroot_output" in *'WordPress deployment completed (uploads)'*) ;; *) echo "$nonroot_output" >&2; exit 1 ;; esac
[ ! -s "$target_root/chown-calls.log" ] || { echo 'Non-root uploads mode must not normalize ownership' >&2; exit 1; }

printf '%s\n' 'previous upload' > "$target_root/wp/wp-content/uploads/2026/08/new-upload.txt"
mkdir -p "$target_root/wp/wp-content/uploads/2026/07"
printf '%s\n' 'rollback upload' > "$target_root/wp/wp-content/uploads/2026/07/rollback.txt"
: > "$target_root/tmp/uploads-fixture.zip"
: > "$target_root/chown-calls.log"
if failure_output="$(run_runner 0 "$target_root/tmp/uploads-fixture.zip" 1)"; then
	echo 'Uploads ownership failure must fail the deployment' >&2
	exit 1
fi
case "$failure_output" in *'Uploads ownership normalization failed'*'AUTOMATIC_CODE_ROLLBACK=completed'*) ;; *) echo "$failure_output" >&2; exit 1 ;; esac
[ -f "$target_root/wp/wp-content/uploads/2026/07/rollback.txt" ] || { echo 'Uploads ownership failure did not restore previous uploads tree' >&2; exit 1; }
grep -Fq 'previous upload' "$target_root/wp/wp-content/uploads/2026/08/new-upload.txt" || { echo 'Failed uploads tree remained active after rollback' >&2; exit 1; }

echo 'Uploads ownership root/non-root/rollback: OK'
