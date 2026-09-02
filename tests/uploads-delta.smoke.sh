#!/usr/bin/env sh
set -eu

repo_dir="$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)"
fixture_dir="${TMPDIR:-/tmp}/wordpress-ssh-deploy-uploads-delta-$$"
target_root="/tmp/wordpress-ssh-deploy-uploads-delta-fixture"
mkdir -p "$fixture_dir"
trap 'rm -rf "$fixture_dir" "$target_root"' 0 1 2 15

cp "$repo_dir/server-deploy.sh" "$fixture_dir/server-deploy.sh"
cp "$repo_dir/tests/fixtures/server.config.owner.sh" "$fixture_dir/server.config.sh"
sed -i "s#/tmp/wordpress-ssh-deploy-owner-fixture#$target_root#g" "$fixture_dir/server.config.sh"
mkdir -p "$target_root/wp/wp-content/uploads/2026/09" "$target_root/repo/.git" \
	"$target_root/tmp" "$target_root/backups" "$target_root/bin"
: > "$target_root/wp/wp-config.php"
: > "$target_root/id_ed25519"
: > "$target_root/bin/wp"
cp "$repo_dir/tests/fixtures/fake-php.sh" "$target_root/bin/php"
cp "$repo_dir/tests/fixtures/fake-df.sh" "$target_root/bin/df"
cp "$repo_dir/tests/fixtures/fake-chown.sh" "$target_root/bin/chown"
cp "$repo_dir/tests/fixtures/fake-id.sh" "$target_root/bin/id"
cp "$repo_dir/tests/fixtures/fake-runuser.sh" "$target_root/bin/runuser"
cp "$repo_dir/tests/fixtures/fake-unzip-delta.sh" "$target_root/bin/unzip"
printf '%s\n' 'keep' > "$target_root/wp/wp-content/uploads/keep.txt"
printf '%s\n' 'old' > "$target_root/wp/wp-content/uploads/old.txt"

make_manifest() {
	root="$1"
	manifest="$2"
	: > "$manifest"
	find "$root" -type f -print | sort | while IFS= read -r file; do
		relative="${file#"$root/"}"
		printf '%s\t%s\t%s\n' "$(sha256sum "$file" | awk '{print tolower($1)}')" "$(stat -c '%s' "$file")" "$relative" >> "$manifest"
	done
}

run_delta() {
	delta="$1"
	manifest="$2"
	PATH="$target_root/bin:/usr/bin:/bin" \
	FIXTURE_ROOT="$target_root" FIXTURE_EFFECTIVE_UID='0' FIXTURE_CHOWN_FAIL="${FIXTURE_CHOWN_FAIL:-0}" \
	FIXTURE_SERVER_PLUGIN_SYNC_PATHS='' FIXTURE_ENVIRONMENT='staging' FIXTURE_URL='https://owner.example.com' FIXTURE_DB_NAME='wordpress_owner_fixture' \
	ENVIRONMENT='staging' LOCAL_URL='http://owner.local' REMOTE_URL='https://owner.example.com' \
	WP_DIR="$target_root/wp" REPO_DIR="$target_root/repo" BACKUP_DIR="$target_root/backups" \
	EXPECTED_WP_DIR="$target_root/wp" EXPECTED_DB_NAME='wordpress_owner_fixture' EXPECTED_REMOTE_DOMAIN='owner.example.com' \
	SYNC_PATHS='wp-content/themes/bella-maria-child' PLUGIN_SYNC_PATHS='' MU_PLUGIN_SYNC_PATHS='' \
	ALLOWED_DEPLOY_MODES='preflight,code,db,code-db,uploads,plugins,mu-plugins,full' \
	GIT_SSH_KEY="$target_root/id_ed25519" PHP_BIN="$target_root/bin/php" WP_CLI_BIN="$target_root/bin/wp" \
	KEEP_BACKUPS='10' MIN_REMOTE_FREE_SPACE_MB='1' DEPLOY_MODE='uploads' SQL_FILE='' UPLOADS_ZIP='' \
	UPLOADS_DELTA_ZIP="$delta" UPLOADS_MANIFEST_FILE="$manifest" \
	sh "$fixture_dir/server-deploy.sh" 2>&1
}

make_manifest "$target_root/wp/wp-content/uploads" "$target_root/backups/uploads-manifest.tsv"
mkdir -p "$target_root/delta-source/payload/2026/09"
mkdir -p "$target_root/delta-source/source"
cp -a "$target_root/wp/wp-content/uploads/." "$target_root/delta-source/source/"
printf '%s\n' 'changed' > "$target_root/delta-source/source/2026/09/new.txt"
rm -f "$target_root/delta-source/source/old.txt"
cp "$target_root/delta-source/source/2026/09/new.txt" "$target_root/delta-source/payload/2026/09/new.txt"
make_manifest "$target_root/delta-source/source" "$target_root/delta-source/manifest.tsv"
cp "$target_root/delta-source/manifest.tsv" "$target_root/tmp/uploads-manifest.tsv"
: > "$target_root/delta-source/delete.list"
printf '%s\n' 'old.txt' > "$target_root/delta-source/delete.list"
: > "$target_root/tmp/uploads-delta.zip"
if first_output="$(run_delta "$target_root/tmp/uploads-delta.zip" "$target_root/tmp/uploads-manifest.tsv" 2>&1)"; then
	case "$first_output" in *'WordPress deployment completed (uploads)'*) ;; *) echo "$first_output" >&2; exit 1 ;; esac
else
	echo "$first_output" >&2
	exit 1
fi
[ -f "$target_root/wp/wp-content/uploads/2026/09/new.txt" ]
[ ! -e "$target_root/wp/wp-content/uploads/old.txt" ]
[ -f "$target_root/backups/uploads-manifest.tsv" ]
grep -Eq '^release=[0-9]{8}-[0-9]{6} mode=delta manifest_sha256=[0-9A-Fa-f]{64}$' "$target_root/backups/uploads-transactions.log"

cp "$target_root/delta-source/manifest.tsv" "$target_root/tmp/uploads-manifest.tsv"
: > "$target_root/tmp/uploads-delta.zip"
if repeat_output="$(run_delta "$target_root/tmp/uploads-delta.zip" "$target_root/tmp/uploads-manifest.tsv" 2>&1)"; then
	case "$repeat_output" in *'WordPress deployment completed (uploads)'*) ;; *) echo "$repeat_output" >&2; exit 1 ;; esac
else
	echo "$repeat_output" >&2
	exit 1
fi

before_manifest="$(cat "$target_root/backups/uploads-manifest.tsv")"
before_log="$(cat "$target_root/backups/uploads-transactions.log")"
: > "$target_root/tmp/uploads-delta.zip"
cp "$target_root/delta-source/manifest.tsv" "$target_root/tmp/uploads-manifest.tsv"
if rollback_output="$(FIXTURE_CHOWN_FAIL=1 run_delta "$target_root/tmp/uploads-delta.zip" "$target_root/tmp/uploads-manifest.tsv" 2>&1)"; then
	echo 'Uploads delta chown failure must fail closed' >&2
	exit 1
fi
case "$rollback_output" in *'AUTOMATIC_CODE_ROLLBACK=completed'*) ;; *) echo "$rollback_output" >&2; exit 1 ;; esac
[ "$(cat "$target_root/backups/uploads-manifest.tsv")" = "$before_manifest" ]
[ "$(cat "$target_root/backups/uploads-transactions.log")" = "$before_log" ]
[ -f "$target_root/wp/wp-content/uploads/2026/09/new.txt" ]
[ ! -e "$target_root/wp/wp-content/uploads/old.txt" ]

printf '%s\n' 'drifted' > "$target_root/wp/wp-content/uploads/keep.txt"
cp "$target_root/delta-source/manifest.tsv" "$target_root/tmp/uploads-manifest.tsv"
: > "$target_root/tmp/uploads-delta.zip"
if output="$(run_delta "$target_root/tmp/uploads-delta.zip" "$target_root/tmp/uploads-manifest.tsv" 2>&1)"; then
	echo 'Remote drift must fail closed' >&2
	exit 1
fi
case "$output" in *UPLOADS_DELTA_FALLBACK_REQUIRED*) ;; *) echo "$output" >&2; exit 1 ;; esac

echo 'Uploads delta add/change/delete, manifest and drift guard: OK'
