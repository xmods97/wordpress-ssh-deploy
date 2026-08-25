#!/bin/sh

# Bella-only runner installer. Run as root from the server-side temporary area.
# It changes only the protected runner; server.config.sh, wrapper policy and
# production full-mode flags are intentionally untouched.

set -eu

fail() { printf '%s\n' "bella-runner-install: $*" >&2; exit 1; }

RUNTIME='/root/.local/libexec/wordpress-ssh-deploy/bella-maria'
DATA='/root/.wordpress-ssh-deploy/bella-maria'
BACKUPS="$DATA/backups"
RUNNER="$RUNTIME/server-deploy.sh"
NEW_RUNNER="$DATA/tmp/server-deploy.sh.new"
EXPECTED_SHA='0FA90FBC7B48C2B44AEC481E74CADAAF6A769B78905DB241F51736E21EC5E858'

test "$(id -u)" = 0 || fail 'root is required'
test -f "$RUNNER" || fail 'current runner is missing'
test -f "$NEW_RUNNER" || fail 'new runner is missing'
test -d "$BACKUPS" || fail 'backup directory is missing'

actual_sha=$(sha256sum "$NEW_RUNNER" | awk '{print toupper($1)}')
test "$actual_sha" = "$EXPECTED_SHA" || fail "new runner SHA mismatch: $actual_sha"
sh -n "$NEW_RUNNER" || fail 'new runner shell syntax failed'

stamp=$(date +%Y%m%d-%H%M%S)
backup="$BACKUPS/server-deploy.sh.bak.$stamp"
stage="$RUNTIME/server-deploy.sh.install.$stamp"
restore_stage="$RUNTIME/server-deploy.sh.restore.$stamp"
installed=0

cleanup() {
    status=$?
    trap - 0 1 2 15
    if [ "$status" -ne 0 ] && [ "$installed" -eq 1 ] && [ -f "$backup" ]; then
        if install -o root -g root -m 700 "$backup" "$restore_stage" 2>/dev/null && mv -f "$restore_stage" "$RUNNER"; then
            printf '%s\n' 'bella-runner-install: previous runner restored' >&2
        else
            printf '%s\n' 'bella-runner-install: previous runner restore failed' >&2
        fi
    fi
    rm -f "$stage" "$restore_stage"
    exit "$status"
}
trap cleanup 0 1 2 15

test ! -e "$backup" || fail 'backup path already exists'
cp -p "$RUNNER" "$backup"
chmod 700 "$backup"
chown root:root "$backup"

install -o root -g root -m 700 "$NEW_RUNNER" "$stage"
mv -f "$stage" "$RUNNER"
installed=1

installed_sha=$(sha256sum "$RUNNER" | awk '{print toupper($1)}')
test "$installed_sha" = "$EXPECTED_SHA" || fail "installed runner SHA mismatch: $installed_sha"
test "$(stat -c '%a' "$RUNNER")" = 700 || fail 'installed runner mode is not 700'
test "$(stat -c '%U:%G' "$RUNNER")" = root:root || fail 'installed runner owner mismatch'
sh -n "$RUNNER" || fail 'installed runner shell syntax failed'

rm -f "$NEW_RUNNER"
printf '%s\n' 'BELLA_RUNNER_SYNC_OK'
printf '%s\n' "runner_sha=$EXPECTED_SHA"
printf '%s\n' "runner_backup=$backup"
