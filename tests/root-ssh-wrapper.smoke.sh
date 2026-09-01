#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
wrapper=$repo_root/root-ssh-wrapper.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

runner=$tmp/runner.sh
cat > "$runner" <<'EOF'
#!/bin/sh
printf '%s|%s|%s|%s\n' "${DEPLOY_MODE-}" "${PRODUCTION_FULL_OPT_IN-}" "${PLUGIN_SYNC_PATHS-}" "${ALLOWED_DEPLOY_MODES-}" >> "$RUNNER_RECORD"
exit 0
EOF

scp_bin=$tmp/fake-scp.sh
cat > "$scp_bin" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$SCP_RECORD"
exit 0
EOF
chmod +x "$scp_bin"

config=$tmp/wrapper.config
cat > "$config" <<EOF
REMOTE_RUNNER_PATH='$runner'
REMOTE_TMP_PATH='$tmp/tmp'
ALLOW_PRODUCTION_FULL_OPT_IN='1'
SCP_BIN='$scp_bin'
EOF
mkdir -p "$tmp/tmp"
export RUNNER_RECORD="$tmp/runner-record"
export SCP_RECORD="$tmp/scp-record"

SSH_ORIGINAL_COMMAND="ENVIRONMENT='staging' DEPLOY_MODE='preflight' sh '$runner'" \
    "$wrapper" "$config"

SSH_ORIGINAL_COMMAND="ENVIRONMENT='production' PLUGIN_SYNC_PATHS='' ALLOWED_DEPLOY_MODES='preflight,code,db,code-db,uploads,plugins,full' DEPLOY_MODE='full' PRODUCTION_FULL_OPT_IN='1' sh '$runner'" \
    "$wrapper" "$config"
grep -F -- 'full|1' "$RUNNER_RECORD" >/dev/null

SSH_ORIGINAL_COMMAND="ENVIRONMENT='production' DEPLOY_MODE='preflight' PRODUCTION_FULL_OPT_IN='0' sh '$runner'" \
    "$wrapper" "$config"
grep -F -- 'preflight|0' "$RUNNER_RECORD" >/dev/null

SSH_ORIGINAL_COMMAND="LOCAL_URL='http://local.example.test' REMOTE_URL='https://staging.example.test' ENVIRONMENT='staging' EXPECTED_REMOTE_DOMAIN='staging.example.test' WP_DIR='/srv/www/site' REPO_DIR='/srv/repo/site' BACKUP_DIR='/srv/backups/site' KEEP_BACKUPS='5' MIN_REMOTE_FREE_SPACE_MB='100' GIT_SSH_KEY='/root/.ssh/git' PHP_BIN='/usr/bin/php' WP_CLI_BIN='/usr/local/bin/wp' EXPECTED_WP_DIR='/srv/www/site' EXPECTED_DB_NAME='user_db' EXPECTED_DB_TABLE_PREFIX='wp_' EXPECTED_DB_TABLE_COUNT='2' SYNC_PATHS='wp-content' PLUGIN_SYNC_PATHS='wp-content/plugins/example-plugin' ALLOWED_DEPLOY_MODES='preflight,code,db,code-db,uploads,plugins,full' FULL_SYNC_PATHS='wp-content' PROTECTED_PATHS='' PROTECTED_ARCHIVE='' REPLACE_PROTECTED='0' DEPLOY_MODE='preflight' SQL_FILE='' UPLOADS_ZIP='' sh '$runner'" \
    "$wrapper" "$config"

SSH_ORIGINAL_COMMAND="ENVIRONMENT='staging' DEPLOY_MODE='code' sh '$runner'" \
    "$wrapper" "$config"
SSH_ORIGINAL_COMMAND="ENVIRONMENT='staging' DEPLOY_MODE='db' sh '$runner'" \
    "$wrapper" "$config"

component_policy='preflight,code,db,code-db,uploads,plugins,full'
SSH_ORIGINAL_COMMAND="ENVIRONMENT='production' PLUGIN_SYNC_PATHS='' ALLOWED_DEPLOY_MODES='$component_policy' DEPLOY_MODE='code-db' PRODUCTION_FULL_OPT_IN='0' sh '$runner'" \
    "$wrapper" "$config"
SSH_ORIGINAL_COMMAND="ENVIRONMENT='production' PLUGIN_SYNC_PATHS='' ALLOWED_DEPLOY_MODES='$component_policy' DEPLOY_MODE='uploads' PRODUCTION_FULL_OPT_IN='0' sh '$runner'" \
    "$wrapper" "$config"
SSH_ORIGINAL_COMMAND="ENVIRONMENT='production' PLUGIN_SYNC_PATHS='wp-content/plugins/example-plugin,wp-content/plugins/second-plugin' ALLOWED_DEPLOY_MODES='$component_policy' DEPLOY_MODE='plugins' PRODUCTION_FULL_OPT_IN='0' sh '$runner'" \
    "$wrapper" "$config"
grep -F -- "code-db|0||$component_policy" "$RUNNER_RECORD" >/dev/null
grep -F -- "uploads|0||$component_policy" "$RUNNER_RECORD" >/dev/null
grep -F -- "plugins|0|wp-content/plugins/example-plugin,wp-content/plugins/second-plugin|$component_policy" "$RUNNER_RECORD" >/dev/null

SSH_ORIGINAL_COMMAND="mkdir -p '$tmp/tmp'" \
    "$wrapper" "$config"

SSH_ORIGINAL_COMMAND="rm -f '$tmp/tmp/a.sql' '$tmp/tmp/b.zip'" \
    "$wrapper" "$config"

printf 'exit 0\n' > "$tmp/tmp/download.sql"
if ! SSH_ORIGINAL_COMMAND="scp -f $tmp/tmp/download.sql" \
    "$wrapper" "$config" </dev/null >/dev/null; then
    echo 'wrapper rejected the scp -f protocol' >&2
    exit 1
fi
grep -F -- "-f $tmp/tmp/download.sql" "$SCP_RECORD" >/dev/null

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
expect_reject "ENVIRONMENT='production' PLUGIN_SYNC_PATHS='' PLUGIN_SYNC_PATHS='wp-content/plugins/example-plugin' ALLOWED_DEPLOY_MODES='$component_policy' DEPLOY_MODE='plugins' sh '$runner'"
expect_reject "ENVIRONMENT='production' PLUGIN_SYNC_PATHS='wp-content/plugins/example-plugin' ALLOWED_DEPLOY_MODES='$component_policy' ALLOWED_DEPLOY_MODES='plugins' DEPLOY_MODE='plugins' sh '$runner'"
expect_reject "DEPLOY_MODE='full' PRODUCTION_FULL_OPT_IN='1' sh '$runner'"
expect_reject "ENVIRONMENT='production' PRODUCTION_FULL_OPT_IN='1' sh '$runner'"
expect_reject "PATH='/tmp' sh '$runner'"
expect_reject "DEPLOY_MODE='preflight' \$(id) sh '$runner'"
expect_reject "DEPLOY_MODE='bogus' sh '$runner'"
expect_reject "ENVIRONMENT='production' PLUGIN_SYNC_PATHS='' ALLOWED_DEPLOY_MODES='preflight,code-db' DEPLOY_MODE='uploads' sh '$runner'"
expect_reject "ENVIRONMENT='production' PLUGIN_SYNC_PATHS='' ALLOWED_DEPLOY_MODES='preflight,code-db,code-db' DEPLOY_MODE='code-db' sh '$runner'"
expect_reject "ENVIRONMENT='production' PLUGIN_SYNC_PATHS='' ALLOWED_DEPLOY_MODES='preflight,unknown' DEPLOY_MODE='preflight' sh '$runner'"
expect_reject "ENVIRONMENT='production' PLUGIN_SYNC_PATHS='' DEPLOY_MODE='code-db' sh '$runner'"
expect_reject "ENVIRONMENT='production' PLUGIN_SYNC_PATHS='' ALLOWED_DEPLOY_MODES='$component_policy' DEPLOY_MODE='plugins' sh '$runner'"
expect_reject "ENVIRONMENT='production' ALLOWED_DEPLOY_MODES='$component_policy' DEPLOY_MODE='plugins' sh '$runner'"
expect_reject "ENVIRONMENT='production' PLUGIN_SYNC_PATHS='../plugins/example-plugin' ALLOWED_DEPLOY_MODES='$component_policy' DEPLOY_MODE='plugins' sh '$runner'"
expect_reject "ENVIRONMENT='production' PLUGIN_SYNC_PATHS='wp-content/themes/example-theme' ALLOWED_DEPLOY_MODES='$component_policy' DEPLOY_MODE='plugins' sh '$runner'"
expect_reject "ENVIRONMENT='production' PLUGIN_SYNC_PATHS='wp-content/plugins/example plugin' ALLOWED_DEPLOY_MODES='$component_policy' DEPLOY_MODE='plugins' sh '$runner'"
expect_reject "ENVIRONMENT='production' PLUGIN_SYNC_PATHS='wp-content/plugins/example-plugin,,wp-content/plugins/second-plugin' ALLOWED_DEPLOY_MODES='$component_policy' DEPLOY_MODE='plugins' sh '$runner'"
expect_reject "ENVIRONMENT='production' DEPLOY_MODE='code' PRODUCTION_FULL_OPT_IN='1' sh '$runner'"
expect_reject "ENVIRONMENT='staging' DEPLOY_MODE='full' PRODUCTION_FULL_OPT_IN='1' sh '$runner'"
expect_reject "ENVIRONMENT='production' DEPLOY_MODE='full' PRODUCTION_FULL_OPT_IN='0' sh '$runner'"
expect_reject "ENVIRONMENT='Production' DEPLOY_MODE='full' sh '$runner'"
expect_reject "ENVIRONMENT='prod' DEPLOY_MODE='full' sh '$runner'"
expect_reject "ENVIRONMENT='production.' DEPLOY_MODE='full' sh '$runner'"
expect_reject "DEPLOY_MODE='full' PRODUCTION_FULL_OPT_IN='2' sh '$runner'"
expect_reject "DEPLOY_MODE='full' PRODUCTION_FULL_OPT_IN='true' sh '$runner'"
expect_reject "DEPLOY_MODE='full' PRODUCTION_FULL_OPT_IN='1;touch' sh '$runner'"
expect_reject "ENVIRONMENT='staging' DEPLOY_MODE='preflight'
sh '$runner'"
control_cr=$(printf '\r')
control_tab=$(printf '\t')
expect_reject "ENVIRONMENT='staging${control_cr}' DEPLOY_MODE='preflight' sh '$runner'"
expect_reject "ENVIRONMENT='staging'${control_tab}DEPLOY_MODE='preflight' sh '$runner'"
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

disabled_config=$tmp/wrapper-disabled.config
sed "s/ALLOW_PRODUCTION_FULL_OPT_IN='1'/ALLOW_PRODUCTION_FULL_OPT_IN='0'/" "$config" > "$disabled_config"
if SSH_ORIGINAL_COMMAND="ENVIRONMENT='production' DEPLOY_MODE='full' PRODUCTION_FULL_OPT_IN='1' sh '$runner'" \
    "$wrapper" "$disabled_config" >/dev/null 2>&1; then
    echo 'wrapper accepted the production token when disabled by config' >&2
    exit 1
fi

SSH_ORIGINAL_COMMAND="ENVIRONMENT='production' DEPLOY_MODE='preflight' PRODUCTION_FULL_OPT_IN='0' sh '$runner'" \
    "$wrapper" "$disabled_config"
grep -F -- 'preflight|0' "$RUNNER_RECORD" >/dev/null

missing_opt_in_config=$tmp/wrapper-missing-opt-in.config
grep -v '^ALLOW_PRODUCTION_FULL_OPT_IN=' "$config" > "$missing_opt_in_config"
if ALLOW_PRODUCTION_FULL_OPT_IN=1 \
    SSH_ORIGINAL_COMMAND="ENVIRONMENT='production' DEPLOY_MODE='full' PRODUCTION_FULL_OPT_IN='1' sh '$runner'" \
    "$wrapper" "$missing_opt_in_config" >/dev/null 2>&1; then
    echo 'wrapper trusted ALLOW_PRODUCTION_FULL_OPT_IN from the inherited environment' >&2
    exit 1
fi

missing_runner_config=$tmp/wrapper-missing-runner.config
grep -v '^REMOTE_RUNNER_PATH=' "$config" > "$missing_runner_config"
if REMOTE_RUNNER_PATH="$runner" \
    SSH_ORIGINAL_COMMAND="ENVIRONMENT='staging' DEPLOY_MODE='preflight' sh '$runner'" \
    "$wrapper" "$missing_runner_config" >/dev/null 2>&1; then
    echo 'wrapper trusted REMOTE_RUNNER_PATH from the inherited environment' >&2
    exit 1
fi

missing_tmp_config=$tmp/wrapper-missing-tmp.config
grep -v '^REMOTE_TMP_PATH=' "$config" > "$missing_tmp_config"
if REMOTE_TMP_PATH="$tmp/evil-tmp" \
    SSH_ORIGINAL_COMMAND="ENVIRONMENT='staging' DEPLOY_MODE='preflight' sh '$runner'" \
    "$wrapper" "$missing_tmp_config" >/dev/null 2>&1; then
    echo 'wrapper trusted REMOTE_TMP_PATH from the inherited environment' >&2
    exit 1
fi

missing_scp_config=$tmp/wrapper-missing-scp.config
grep -v '^SCP_BIN=' "$config" > "$missing_scp_config"
if SCP_BIN="$scp_bin" \
    SSH_ORIGINAL_COMMAND="scp -f $tmp/tmp/download.sql" \
    "$wrapper" "$missing_scp_config" </dev/null >/dev/null 2>&1; then
    echo 'wrapper trusted SCP_BIN from the inherited environment' >&2
    exit 1
fi

echo 'Root SSH wrapper smoke: OK'
