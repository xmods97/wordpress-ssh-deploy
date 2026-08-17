#!/usr/bin/env sh
set -eu

repo_dir="$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)"
fixture_dir="${TMPDIR:-/tmp}/wordpress-ssh-deploy-wp-cli-root-test-$$"
target_root="${TMPDIR:-/tmp}/wordpress-ssh-deploy-wp-cli-root-fixture-$$"
mkdir -p "$fixture_dir" "$target_root/wp/wp-content" "$target_root/repo/.git" "$target_root/tmp" "$target_root/backups" "$target_root/bin"
trap 'rm -rf "$fixture_dir" "$target_root"' 0 1 2 15

cp "$repo_dir/server-deploy.sh" "$fixture_dir/server-deploy.sh"
sed -e "s#/tmp/wordpress-ssh-deploy-fixture#$target_root#g" \
	-e "s#^SERVER_PHP_BIN=.*#SERVER_PHP_BIN='/usr/bin/sh'#" \
	"$repo_dir/tests/fixtures/server.config.production.sh" > "$fixture_dir/server.config.sh"
cp "$repo_dir/tests/fixtures/fake-php.sh" "$target_root/fake-php.sh"
: > "$target_root/bin/wp"
: > "$target_root/id_ed25519"
: > "$target_root/wp/wp-config.php"

cat > "$target_root/bin/wp" <<'SH'
#!/usr/bin/env sh
case "${EXPECT_ALLOW_ROOT:-}" in
	1)
		case " $* " in
			*' --allow-root '*) ;;
			*) echo 'WP-CLI root invocation was missing --allow-root' >&2; exit 1 ;;
		esac
		;;
	0)
		case " $* " in
			*' --allow-root '*) echo 'WP-CLI non-root invocation unexpectedly used --allow-root' >&2; exit 1 ;;
			esac
		;;
	*) echo 'WP-CLI smoke expectation was not configured' >&2; exit 1 ;;
esac
exec sh "$FIXTURE_ROOT/fake-php.sh" "$@"
SH
run_case() {
	expected_uid="$1"
	expected_allow_root="$2"
	if ! output="$(
	(
		cd "$fixture_dir"
		export FIXTURE_ROOT="$target_root"
		export FAKE_EFFECTIVE_UID="$expected_uid" EXPECT_ALLOW_ROOT="$expected_allow_root"
		export SERVER_FILE_OWNER='root' SERVER_FILE_GROUP='root'
		export SERVER_ALLOW_PRODUCTION_PULL='1' ALLOW_PRODUCTION_PULL='1'
		export ENVIRONMENT='production' LOCAL_URL='http://local.example.test'
		export REMOTE_URL='https://example.com' WP_DIR="$target_root/wp"
		export REPO_DIR="$target_root/repo" BACKUP_DIR="$target_root/backups"
		export EXPECTED_WP_DIR="$target_root/wp"
		export EXPECTED_DB_NAME='wordpress_production' EXPECTED_DB_TABLE_PREFIX='wp_'
		export EXPECTED_REMOTE_DOMAIN='example.com'
		export SYNC_PATHS='wp-content/themes/example-theme'
		export GIT_SSH_KEY="$target_root/id_ed25519"
		export PHP_BIN='/usr/bin/sh' WP_CLI_BIN="$target_root/bin/wp"
		export KEEP_BACKUPS='10' MIN_REMOTE_FREE_SPACE_MB='1'
		export PULL_ARTIFACT="$target_root/tmp/pull-db.sql.gz" DEPLOY_MODE='pull-db'
		export PATH="$target_root/bin:/usr/bin:/bin"
		rm -f "$target_root/tmp/pull-db.sql.gz"
		sh -c '
			id() {
				[ "${1:-}" = "-u" ] && printf "%s\\n" "${FAKE_EFFECTIVE_UID:-0}"
			}
			getent() { return 0; }
			chown() { return 0; }
			if ! command -v df >/dev/null 2>&1; then df() {
				printf "%s\\n" "Filesystem 1024-blocks Used Available Capacity Mounted on" "fixture 1000000 0 1000000 0% /"
			}; fi
			if ! command -v awk >/dev/null 2>&1; then awk() {
				case "$*" in
					*"END { exit (!found || invalid)"*)
						prefix=${2#prefix=}
						file="$4"
						found=0
						while IFS= read -r line; do
							case "$line" in
								"CREATE TABLE \`$prefix"*|"CREATE TABLE IF NOT EXISTS \`$prefix"*) found=1 ;;
								"CREATE TABLE \`"*|"CREATE TABLE IF NOT EXISTS \`"*) return 1 ;;
							 esac
						 done < "$file"
						[ "$found" -eq 1 ]
						;;
					*"NR==2"*) printf "%s\\n" "1000000" ;;
					*"NR>"*) : ;;
					*"for (i = 1; i <= NF"*)
						while IFS= read -r line; do
							old_ifs="$IFS"
							IFS=","; set -- $line; IFS="$old_ifs"
							for table in "$@"; do
								[ -n "$table" ] && printf "%s\\n" "$table"
								done
						done
						;;
					*) return 1 ;;
				 esac
			}; fi
			if ! command -v gzip >/dev/null 2>&1; then gzip() {
				case "${1:-}" in
					-c) cat "$2" ;;
					-t) test -s "$2" ;;
					*) return 1 ;;
				 esac
			}; fi
			. ./server-deploy.sh
		' wp-cli-root-fixture
	) 2>&1
	)"; then
		echo "WP-CLI root compatibility runner failed (uid=$expected_uid): $output" >&2
		return 1
	fi

case "$output" in
	*'WordPress pull export completed (pull-db)'*) ;;
	*) echo "WP-CLI root compatibility did not complete (uid=$expected_uid): $output" >&2; return 1 ;;
esac

[ -s "$target_root/tmp/pull-db.sql.gz" ] || {
	echo "WP-CLI root compatibility did not create the pull artifact (uid=$expected_uid)" >&2
	return 1
}
}

run_case 0 1
run_case 1000 0
echo 'WP-CLI root compatibility: OK'
