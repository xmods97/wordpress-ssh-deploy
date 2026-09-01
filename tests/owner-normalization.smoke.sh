#!/usr/bin/env sh
set -eu

repo_dir="$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)"
fixture_dir="${TMPDIR:-/tmp}/wordpress-ssh-deploy-owner-runner-$$"
target_root='/tmp/wordpress-ssh-deploy-owner-fixture'
mkdir -p "$fixture_dir"
trap 'rm -rf "$fixture_dir" "$target_root"' 0 1 2 15

cp "$repo_dir/server-deploy.sh" "$fixture_dir/server-deploy.sh"
cp "$repo_dir/tests/fixtures/server.config.owner.sh" "$fixture_dir/server.config.sh"
mkdir -p "$target_root/wp/wp-content/themes/Divi" "$target_root/wp/wp-content/themes/bella-maria-child" \
	"$target_root/wp/wp-content/plugins/example-plugin" "$target_root/repo/.git" \
	"$target_root/repo/wp-content/themes/bella-maria-child" "$target_root/repo/wp-content/plugins/example-plugin" \
	"$target_root/wp/wp-content/mu-plugins" "$target_root/repo/wp-content/mu-plugins/example-loader" \
	"$target_root/tmp" "$target_root/backups" "$target_root/bin"
: > "$target_root/wp/wp-config.php"
: > "$target_root/id_ed25519"
: > "$target_root/bin/wp"
cp "$repo_dir/tests/fixtures/fake-php.sh" "$target_root/bin/php"
cp "$repo_dir/tests/fixtures/fake-df.sh" "$target_root/bin/df"
cp "$repo_dir/tests/fixtures/fake-du.sh" "$target_root/bin/du"
cp "$repo_dir/tests/fixtures/fake-stat.sh" "$target_root/bin/stat"
cp "$repo_dir/tests/fixtures/fake-chown.sh" "$target_root/bin/chown"
cp "$repo_dir/tests/fixtures/fake-id.sh" "$target_root/bin/id"
cp "$repo_dir/tests/fixtures/fake-runuser.sh" "$target_root/bin/runuser"
cp "$repo_dir/tests/fixtures/fake-mysqldump.sh" "$target_root/bin/mysqldump"
cp "$repo_dir/tests/fixtures/fake-mysql.sh" "$target_root/bin/mysql"
cp "$repo_dir/tests/fixtures/fake-chmod.sh" "$target_root/bin/chmod"
cp "$repo_dir/tests/fixtures/fake-git.sh" "$target_root/bin/git"
printf '%s\n' 'child release' > "$target_root/repo/wp-content/themes/bella-maria-child/style.css"
printf '%s\n' 'old release' > "$target_root/wp/wp-content/themes/bella-maria-child/style.css"
printf '%s\n' 'plugin release' > "$target_root/repo/wp-content/plugins/example-plugin/plugin.php"
printf '%s\n' 'mu release' > "$target_root/repo/wp-content/mu-plugins/example-loader/loader.php"

run_runner() {
	mode="$1"
	plugin_paths='wp-content/plugins/example-plugin'
	if [ "${FIXTURE_PLUGIN_SYNC_PATHS+x}" = x ]; then plugin_paths="$FIXTURE_PLUGIN_SYNC_PATHS"; fi
	mu_plugin_paths=''
	if [ "${FIXTURE_MU_PLUGIN_SYNC_PATHS+x}" = x ]; then mu_plugin_paths="$FIXTURE_MU_PLUGIN_SYNC_PATHS"; fi
	PATH="$target_root/bin:/usr/bin:/bin" \
	FIXTURE_ROOT="$target_root" \
	FIXTURE_EFFECTIVE_UID="${FIXTURE_EFFECTIVE_UID:-1000}" \
	FIXTURE_ENVIRONMENT='staging' \
	FIXTURE_URL='https://owner.example.com' \
	FIXTURE_DB_NAME='wordpress_owner_fixture' \
	ENVIRONMENT='staging' LOCAL_URL='http://owner.local' REMOTE_URL='https://owner.example.com' \
	WP_DIR="$target_root/wp" REPO_DIR="$target_root/repo" BACKUP_DIR="$target_root/backups" \
	EXPECTED_WP_DIR="$target_root/wp" EXPECTED_DB_NAME='wordpress_owner_fixture' EXPECTED_REMOTE_DOMAIN='owner.example.com' \
SYNC_PATHS='wp-content/themes/bella-maria-child' PLUGIN_SYNC_PATHS="$plugin_paths" MU_PLUGIN_SYNC_PATHS="$mu_plugin_paths" \
	ALLOWED_DEPLOY_MODES='preflight,code,db,code-db,uploads,plugins,mu-plugins,full' \
	GIT_SSH_KEY="$target_root/id_ed25519" PHP_BIN="$target_root/bin/php" WP_CLI_BIN="$target_root/bin/wp" \
	KEEP_BACKUPS='10' MIN_REMOTE_FREE_SPACE_MB='1' DEPLOY_MODE="$mode" SQL_FILE="${2:-}" UPLOADS_ZIP='' \
	sh "$fixture_dir/server-deploy.sh" 2>&1
}

code_output="$(run_runner code)"
case "$code_output" in *'Theme ownership normalized to admin_nadry:admin_nadry'*) ;; *) echo "$code_output" >&2; exit 1 ;; esac
grep -Fq "admin_nadry:admin_nadry $target_root/wp/wp-content/themes" "$target_root/chown-calls.log"
grep -Fq -- "admin_nadry:admin_nadry $target_root/wp/wp-content/themes/bella-maria-child" "$target_root/chown-calls.log"
if grep -Fq 'Divi' "$target_root/chown-calls.log"; then echo 'Code-only mode must not normalize Divi' >&2; exit 1; fi

printf '%s\n' 'new release' > "$target_root/repo/wp-content/themes/bella-maria-child/style.css"
if run_output="$(FIXTURE_CHOWN_FAIL=1 run_runner code)"; then echo 'Chown failure must fail the deployment' >&2; exit 1; fi
grep -Fq 'child release' "$target_root/wp/wp-content/themes/bella-maria-child/style.css"

plugin_output="$(run_runner plugins)"
[ -n "$plugin_output" ]
case "$plugin_output" in *'Plugin ownership normalized to admin_nadry:admin_nadry'*) ;; *) echo "$plugin_output" >&2; exit 1 ;; esac
[ -f "$target_root/wp/wp-content/plugins/example-plugin/plugin.php" ] || { echo 'Plugin component was not copied' >&2; exit 1; }
grep -Fq 'plugin release' "$target_root/wp/wp-content/plugins/example-plugin/plugin.php"

printf '%s\n' '-- MySQL dump 10.13  Distrib fixture' '-- Table structure for table `wp_options`' 'CREATE TABLE `wp_options` (`option_id` bigint NOT NULL);' 'INSERT INTO `wp_options` VALUES (2);' > "$target_root/tmp/local-db-fixture.sql"
: > "$target_root/chown-calls.log"
full_output="$(run_runner full "$target_root/tmp/local-db-fixture.sql")"
case "$full_output" in *'Theme ownership normalized to admin_nadry:admin_nadry'*) ;; *) echo "$full_output" >&2; exit 1 ;; esac
grep -Fq -- "admin_nadry:admin_nadry $target_root/wp/wp-content/themes/Divi" "$target_root/chown-calls.log"
[ "$(wc -l < "$target_root/mysql-calls.log")" -eq 1 ] || { echo 'Full mode did not execute database import' >&2; exit 1; }

: > "$target_root/chown-calls.log"
: > "$target_root/mysql-calls.log"
printf '%s\n' '-- MySQL dump 10.13  Distrib fixture' '-- Table structure for table `wp_options`' 'CREATE TABLE `wp_options` (`option_id` bigint NOT NULL);' 'INSERT INTO `wp_options` VALUES (2);' > "$target_root/tmp/local-db-fixture.sql"
code_db_output="$(run_runner code-db "$target_root/tmp/local-db-fixture.sql")"
case "$code_db_output" in *'WordPress deployment completed (code-db)'*) ;; *) echo "$code_db_output" >&2; exit 1 ;; esac
[ "$(wc -l < "$target_root/mysql-calls.log")" -eq 1 ] || { echo 'Code-db mode did not execute database import' >&2; exit 1; }

if root_owner_output="$(FIXTURE_OWNER_UID=0 run_runner code)"; then
	echo 'Root-owned WordPress content must be rejected' >&2
	exit 1
fi
case "$root_owner_output" in *'WordPress content owner must not be root'*) ;; *) echo "$root_owner_output" >&2; exit 1 ;; esac

mu_plugin_output="$(FIXTURE_EFFECTIVE_UID=0 FIXTURE_MU_PLUGIN_SYNC_PATHS='wp-content/mu-plugins/example-loader' FIXTURE_SERVER_MU_PLUGIN_SYNC_PATHS='wp-content/mu-plugins/example-loader' run_runner mu-plugins)"
case "$mu_plugin_output" in *'Mu-plugin ownership normalized to admin_nadry:admin_nadry'*) ;; *) echo "$mu_plugin_output" >&2; exit 1 ;; esac
[ -f "$target_root/wp/wp-content/mu-plugins/example-loader/loader.php" ] || { echo 'MU-plugin component was not copied' >&2; exit 1; }
grep -Fq 'mu release' "$target_root/wp/wp-content/mu-plugins/example-loader/loader.php"
grep -Fq -- "admin_nadry:admin_nadry $target_root/wp/wp-content/mu-plugins" "$target_root/chown-calls.log"
grep -Fq -- "admin_nadry:admin_nadry $target_root/wp/wp-content/mu-plugins/example-loader" "$target_root/chown-calls.log"

printf '%s\n' 'mu release after failure' > "$target_root/repo/wp-content/mu-plugins/example-loader/loader.php"
if mu_failure_output="$(FIXTURE_EFFECTIVE_UID=0 FIXTURE_MU_PLUGIN_SYNC_PATHS='wp-content/mu-plugins/example-loader' FIXTURE_SERVER_MU_PLUGIN_SYNC_PATHS='wp-content/mu-plugins/example-loader' FIXTURE_CHOWN_FAIL=1 run_runner mu-plugins)"; then
	echo 'MU-plugin chown failure must fail the deployment' >&2
	exit 1
fi
case "$mu_failure_output" in *'AUTOMATIC_CODE_ROLLBACK=completed'*) ;; *) echo "$mu_failure_output" >&2; exit 1 ;; esac
grep -Fq 'mu release' "$target_root/wp/wp-content/mu-plugins/example-loader/loader.php"

printf '%s\n' 'mu file release' > "$target_root/repo/wp-content/mu-plugins/example-file.php"
printf '%s\n' 'old mu file release' > "$target_root/wp/wp-content/mu-plugins/example-file.php"
mu_file_output="$(FIXTURE_EFFECTIVE_UID=0 FIXTURE_MU_PLUGIN_SYNC_PATHS='wp-content/mu-plugins/example-file.php' FIXTURE_SERVER_MU_PLUGIN_SYNC_PATHS='wp-content/mu-plugins/example-file.php' run_runner mu-plugins)"
case "$mu_file_output" in *'Mu-plugin ownership normalized to admin_nadry:admin_nadry'*) ;; *) echo "$mu_file_output" >&2; exit 1 ;; esac
grep -Fq 'mu file release' "$target_root/wp/wp-content/mu-plugins/example-file.php"
grep -Fq -- "admin_nadry:admin_nadry $target_root/wp/wp-content/mu-plugins/example-file.php" "$target_root/chown-calls.log"

echo 'Owner normalization code/plugin/MU/full: OK'
