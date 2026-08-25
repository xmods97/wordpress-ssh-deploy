#!/bin/sh
set -eu

# Bella-only private Git source policy installer. Run as root on the server.
# It changes only SERVER_GIT_REMOTE, SERVER_GIT_BRANCH, SERVER_GIT_SSH_PORT and
# SERVER_SYNC_PATHS in server.config.sh.

config_backup=''
config_stage=''

cleanup() {
    status=$?
    trap - EXIT
    if [ "$status" -ne 0 ] && [ -n "$config_backup" ] && [ -f "$config_backup" ]; then
        restore_stage="${CONFIG}.restore.${stamp:-recovery}"
        if install -o root -g root -m 600 "$config_backup" "$restore_stage" && mv -f "$restore_stage" "$CONFIG"; then
            printf '%s\n' 'bella-git-policy-install: previous server.config.sh restored' >&2
        else
            printf '%s\n' 'bella-git-policy-install: previous server.config.sh could not be restored' >&2
        fi
    fi
    [ -z "${config_stage:-}" ] || rm -f "$config_stage"
    exit "$status"
}
trap cleanup EXIT

fail() { printf '%s\n' "bella-git-policy-install: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail 'root is required'

DATA='/root/.wordpress-ssh-deploy/bella-maria'
BACKUPS="$DATA/backups"
CONFIG='/root/.local/libexec/wordpress-ssh-deploy/bella-maria/server.config.sh'
EXPECTED_REMOTE='origin'
EXPECTED_BRANCH='codex/bella-maria-v2026-08-23-02'
EXPECTED_SSH_PORT='443'
EXPECTED_SYNC_PATHS='wp-content/themes/bella-maria-child'

for path in "$DATA" "$BACKUPS" "$CONFIG"; do
    [ -e "$path" ] || fail "required path is missing: $path"
done

stamp=$(date +%Y%m%d-%H%M%S)
config_backup="$BACKUPS/server.config.sh.bak.$stamp"
config_stage="${CONFIG}.install.$stamp"
[ ! -e "$config_backup" ] || fail "backup path already exists: $config_backup"

cp -p "$CONFIG" "$config_backup"
chmod 600 "$config_backup"
chown root:root "$config_backup"

awk -v remote="$EXPECTED_REMOTE" -v branch="$EXPECTED_BRANCH" -v ssh_port="$EXPECTED_SSH_PORT" -v sync_paths="$EXPECTED_SYNC_PATHS" '
BEGIN { remote_seen = 0; branch_seen = 0; ssh_port_seen = 0; sync_paths_seen = 0; quote = sprintf("%c", 39) }
/^SERVER_GIT_REMOTE=/ {
    if (!remote_seen) { printf "SERVER_GIT_REMOTE=%s%s%s\n", quote, remote, quote; remote_seen = 1 }
    next
}
/^SERVER_GIT_BRANCH=/ {
    if (!branch_seen) { printf "SERVER_GIT_BRANCH=%s%s%s\n", quote, branch, quote; branch_seen = 1 }
    next
}
/^SERVER_GIT_SSH_PORT=/ {
    if (!ssh_port_seen) { printf "SERVER_GIT_SSH_PORT=%s%s%s\n", quote, ssh_port, quote; ssh_port_seen = 1 }
    next
}
/^SERVER_SYNC_PATHS=/ {
    if (!sync_paths_seen) { printf "SERVER_SYNC_PATHS=%s%s%s\n", quote, sync_paths, quote; sync_paths_seen = 1 }
    next
}
{ print }
END {
    if (!remote_seen) printf "SERVER_GIT_REMOTE=%s%s%s\n", quote, remote, quote
    if (!branch_seen) printf "SERVER_GIT_BRANCH=%s%s%s\n", quote, branch, quote
    if (!ssh_port_seen) printf "SERVER_GIT_SSH_PORT=%s%s%s\n", quote, ssh_port, quote
    if (!sync_paths_seen) printf "SERVER_SYNC_PATHS=%s%s%s\n", quote, sync_paths, quote
}
' "$CONFIG" > "$config_stage"
chmod 600 "$config_stage"
chown root:root "$config_stage"

remote_count=$(grep -Ec '^SERVER_GIT_REMOTE=' "$config_stage" || true)
branch_count=$(grep -Ec '^SERVER_GIT_BRANCH=' "$config_stage" || true)
ssh_port_count=$(grep -Ec '^SERVER_GIT_SSH_PORT=' "$config_stage" || true)
sync_paths_count=$(grep -Ec '^SERVER_SYNC_PATHS=' "$config_stage" || true)
[ "$remote_count" = 1 ] || fail 'server.config.sh must contain exactly one SERVER_GIT_REMOTE assignment'
[ "$branch_count" = 1 ] || fail 'server.config.sh must contain exactly one SERVER_GIT_BRANCH assignment'
[ "$ssh_port_count" = 1 ] || fail 'server.config.sh must contain exactly one SERVER_GIT_SSH_PORT assignment'
[ "$sync_paths_count" = 1 ] || fail 'server.config.sh must contain exactly one SERVER_SYNC_PATHS assignment'
grep -Fqx "SERVER_GIT_REMOTE='$EXPECTED_REMOTE'" "$config_stage" || fail 'unexpected SERVER_GIT_REMOTE policy'
grep -Fqx "SERVER_GIT_BRANCH='$EXPECTED_BRANCH'" "$config_stage" || fail 'unexpected SERVER_GIT_BRANCH policy'
grep -Fqx "SERVER_GIT_SSH_PORT='$EXPECTED_SSH_PORT'" "$config_stage" || fail 'unexpected SERVER_GIT_SSH_PORT policy'
grep -Fqx "SERVER_SYNC_PATHS='$EXPECTED_SYNC_PATHS'" "$config_stage" || fail 'unexpected SERVER_SYNC_PATHS policy'

old_without_policy="${CONFIG}.old-policy.$stamp"
new_without_policy="${CONFIG}.new-policy.$stamp"
sed '/^SERVER_GIT_REMOTE=/d; /^SERVER_GIT_BRANCH=/d; /^SERVER_GIT_SSH_PORT=/d; /^SERVER_SYNC_PATHS=/d' "$CONFIG" > "$old_without_policy"
sed '/^SERVER_GIT_REMOTE=/d; /^SERVER_GIT_BRANCH=/d; /^SERVER_GIT_SSH_PORT=/d; /^SERVER_SYNC_PATHS=/d' "$config_stage" > "$new_without_policy"
cmp -s "$old_without_policy" "$new_without_policy" || fail 'policy installer changed unrelated server.config.sh content'
rm -f "$old_without_policy" "$new_without_policy"

mv -f "$config_stage" "$CONFIG"
config_stage=''
test "$(stat -c '%U:%G' "$CONFIG")" = root:root || fail 'server.config.sh owner mismatch'
test "$(stat -c '%a' "$CONFIG")" = 600 || fail 'server.config.sh mode is not 600'
grep -Fqx "SERVER_GIT_REMOTE='$EXPECTED_REMOTE'" "$CONFIG" || fail 'installed remote policy mismatch'
grep -Fqx "SERVER_GIT_BRANCH='$EXPECTED_BRANCH'" "$CONFIG" || fail 'installed branch policy mismatch'
grep -Fqx "SERVER_GIT_SSH_PORT='$EXPECTED_SSH_PORT'" "$CONFIG" || fail 'installed SSH port policy mismatch'
grep -Fqx "SERVER_SYNC_PATHS='$EXPECTED_SYNC_PATHS'" "$CONFIG" || fail 'installed sync paths policy mismatch'

trap - EXIT
printf '%s\n' 'BELLA_GIT_POLICY_SYNC_OK'
printf '%s\n' "git_remote=$EXPECTED_REMOTE"
printf '%s\n' "git_branch=$EXPECTED_BRANCH"
printf '%s\n' "git_ssh_port=$EXPECTED_SSH_PORT"
printf '%s\n' "sync_paths=$EXPECTED_SYNC_PATHS"
printf '%s\n' "config_backup=$config_backup"
