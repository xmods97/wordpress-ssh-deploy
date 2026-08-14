#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
wrapper=$repo_root/root-ssh-wrapper.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

runner=$tmp/runner.sh
cat > "$runner" <<'EOF'
#!/bin/sh
exit 0
EOF

config=$tmp/wrapper.config
cat > "$config" <<EOF
REMOTE_RUNNER_PATH='$runner'
REMOTE_TMP_PATH='$tmp/tmp'
SCP_BIN='sh'
EOF
mkdir -p "$tmp/tmp"

SSH_ORIGINAL_COMMAND="DEPLOY_MODE='preflight' sh '$runner'" \
    "$wrapper" "$config"

SSH_ORIGINAL_COMMAND="LOCAL_URL='http://local.example.test' REMOTE_URL='https://staging.example.test' ENVIRONMENT='staging' EXPECTED_REMOTE_DOMAIN='staging.example.test' WP_DIR='/srv/www/site' REPO_DIR='/srv/repo/site' BACKUP_DIR='/srv/backups/site' KEEP_BACKUPS='5' MIN_REMOTE_FREE_SPACE_MB='100' GIT_SSH_KEY='/root/.ssh/git' PHP_BIN='/usr/bin/php' WP_CLI_BIN='/usr/local/bin/wp' EXPECTED_WP_DIR='/srv/www/site' EXPECTED_DB_NAME='user_db' EXPECTED_DB_TABLE_PREFIX='wp_' SYNC_PATHS='wp-content' FULL_SYNC_PATHS='wp-content' PROTECTED_PATHS='' PROTECTED_ARCHIVE='' REPLACE_PROTECTED='0' DEPLOY_MODE='preflight' SQL_FILE='' UPLOADS_ZIP='' sh '$runner'" \
    "$wrapper" "$config"

SSH_ORIGINAL_COMMAND="mkdir -p '$tmp/tmp'" \
    "$wrapper" "$config"

SSH_ORIGINAL_COMMAND="rm -f '$tmp/tmp/a.sql' '$tmp/tmp/b.zip'" \
    "$wrapper" "$config"

printf 'exit 0\n' > "$tmp/tmp/download.sql"
if ! printf '\0\0' | SSH_ORIGINAL_COMMAND="scp -f $tmp/tmp/download.sql" \
    "$wrapper" "$config" >/dev/null; then
    echo 'wrapper rejected the real scp -f protocol' >&2
    exit 1
fi

expect_reject() {
    command=$1
    if SSH_ORIGINAL_COMMAND="$command" "$wrapper" "$config" >/dev/null 2>&1; then
        echo "wrapper accepted a forbidden command: $command" >&2
        exit 1
    fi
}

expect_reject ''
expect_reject "sh '$tmp/other-runner.sh'"
expect_reject "DEPLOY_MODE='preflight' DEPLOY_MODE='code' sh '$runner'"
expect_reject "PATH='/tmp' sh '$runner'"
expect_reject "DEPLOY_MODE='preflight' \$(id) sh '$runner'"
expect_reject "rm -f '$tmp/outside.txt'"
expect_reject "rm -f '$tmp/tmp/../escape.txt'"
expect_reject "scp -f $tmp/outside.txt"

marker=$tmp/should-not-exist
if SSH_ORIGINAL_COMMAND="DEPLOY_MODE='preflight'; touch '$marker' sh '$runner'" \
    "$wrapper" "$config" 2>/dev/null; then
    echo 'wrapper accepted shell metacharacters' >&2
    exit 1
fi
[ ! -e "$marker" ]

if SSH_ORIGINAL_COMMAND="scp -t '$tmp/tmp/../escape.zip'" \
    "$wrapper" "$config" </dev/null 2>/dev/null; then
    echo 'wrapper accepted traversal' >&2
    exit 1
fi

echo 'Root SSH wrapper smoke: OK'
