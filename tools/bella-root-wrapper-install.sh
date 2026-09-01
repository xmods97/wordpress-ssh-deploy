#!/bin/sh
set -eu

wrapper_backup=''
config_backup=''
authorized_backup=''
mutation_started=0

print_recovery_paths() {
    [ -n "$wrapper_backup" ] && printf '%s\n' "bella-wrapper-install: wrapper backup: $wrapper_backup" >&2
    [ -n "$config_backup" ] && printf '%s\n' "bella-wrapper-install: config backup: $config_backup" >&2
    [ -n "$authorized_backup" ] && printf '%s\n' "bella-wrapper-install: authorized_keys backup: $authorized_backup" >&2
    return 0
}

cleanup_stages() {
    for path in "${wrapper_stage:-}" "${config_stage:-}" "${authorized_stage:-}" "${authorized_check:-}"; do
        if [ -n "$path" ]; then
            rm -f "$path" || printf '%s\n' "bella-wrapper-install: could not remove staged path: $path" >&2
        fi
    done
}

restore_one() {
    source_path=$1
    target_path=$2
    mode=$3
    restore_stage="${target_path}.restore.${stamp:-recovery}"
    if ! install -o root -g root -m "$mode" "$source_path" "$restore_stage"; then
        printf '%s\n' "bella-wrapper-install: could not stage restore for $target_path" >&2
        return 1
    fi
    if ! mv -f "$restore_stage" "$target_path"; then
        printf '%s\n' "bella-wrapper-install: could not commit restore for $target_path" >&2
        rm -f "$restore_stage" || true
        return 1
    fi
    return 0
}

restore_on_failure() {
    status=$?
    trap - EXIT
    if [ "$mutation_started" = 1 ]; then
        printf '%s\n' 'bella-wrapper-install: installation failed; restoring backups' >&2
        restore_one "$wrapper_backup" "$WRAPPER" 700 || true
        restore_one "$config_backup" "$CONFIG" 600 || true
        restore_one "$authorized_backup" "$AUTHORIZED" 600 || true
        print_recovery_paths
    fi
    cleanup_stages
    exit "$status"
}

trap restore_on_failure EXIT

fail() {
    printf '%s\n' "bella-wrapper-install: $*" >&2
    print_recovery_paths
    exit 1
}

[ "$(id -u)" = 0 ] || fail 'root is required'

RUNTIME='/root/.local/libexec/wordpress-ssh-deploy/bella-maria'
DATA='/root/.wordpress-ssh-deploy/bella-maria'
BACKUPS="$DATA/backups"
WRAPPER="$RUNTIME/root-ssh-wrapper.sh"
CONFIG="$DATA/wrapper.config"
NEW_WRAPPER="$DATA/tmp/root-ssh-wrapper.new"
AUTHORIZED='/root/.ssh/authorized_keys'
EXPECTED_SHA='153B46B3C948E9364CB437BCD59355E2D29A5417648CFDA7AF35B1482A721986'
TARGET='command="/root/.local/libexec/wordpress-ssh-deploy/bella-maria/root-ssh-wrapper.sh /root/.wordpress-ssh-deploy/bella-maria/wrapper.config"'

for path in "$RUNTIME" "$DATA" "$BACKUPS" "$WRAPPER" "$CONFIG" "$NEW_WRAPPER" "$AUTHORIZED"; do
    [ -e "$path" ] || fail "required path is missing: $path"
done

actual_sha=$(sha256sum "$NEW_WRAPPER" | awk '{print toupper($1)}')
[ "$actual_sha" = "$EXPECTED_SHA" ] || fail "new wrapper SHA mismatch: $actual_sha"
sh -n "$NEW_WRAPPER" || fail 'new wrapper shell syntax failed'

grep -Fq 'REMOTE_RUNNER_PATH=' "$CONFIG" || fail 'Bella runner path is missing from wrapper config'
grep -Fq 'REMOTE_TMP_PATH=' "$CONFIG" || fail 'Bella tmp path is missing from wrapper config'

opt_count=$(grep -Ec '^ALLOW_PRODUCTION_FULL_OPT_IN=' "$CONFIG" || true)
[ "$opt_count" -le 1 ] || fail 'wrapper config contains duplicate full opt-in settings'

key_count=$(grep -F -c "$TARGET" "$AUTHORIZED" || true)
[ "$key_count" = 1 ] || fail 'Bella authorized_keys target entry count is not exactly one'

stamp=$(date +%Y%m%d-%H%M%S)
wrapper_backup="$BACKUPS/root-ssh-wrapper.sh.bak.$stamp"
config_backup="$BACKUPS/wrapper.config.bak.$stamp"
authorized_backup="$BACKUPS/authorized_keys.bak.$stamp"

for path in "$wrapper_backup" "$config_backup" "$authorized_backup"; do
    [ ! -e "$path" ] || fail "backup path already exists: $path"
done

cp -p "$WRAPPER" "$wrapper_backup"
cp -p "$CONFIG" "$config_backup"
cp -p "$AUTHORIZED" "$authorized_backup"
chmod 700 "$wrapper_backup"
chmod 600 "$config_backup" "$authorized_backup"
chown root:root "$wrapper_backup" "$config_backup" "$authorized_backup"

wrapper_stage="$RUNTIME/root-ssh-wrapper.sh.install.$stamp"
config_stage="$DATA/wrapper.config.install.$stamp"
authorized_stage="/root/.ssh/authorized_keys.install.$stamp"

existing_restrict_count=$(awk -v target="$TARGET" '
index($0, target) && $0 ~ /(^|,)restrict(,|[[:space:]])/ { count++ }
END { print count + 0 }
' "$AUTHORIZED")
[ "$existing_restrict_count" -le 1 ] || fail 'authorized_keys contains duplicate Bella restrict target entries'
restrict_added=0
[ "$existing_restrict_count" = 1 ] || restrict_added=1

install -o root -g root -m 700 "$NEW_WRAPPER" "$wrapper_stage"

install -o root -g root -m 600 "$CONFIG" "$config_stage"

awk -v target="$TARGET" '
index($0, target) {
    if ($0 !~ /(^|,)restrict(,|[[:space:]])/) {
        $0 = "restrict," $0
    }
}
{ print }
' "$AUTHORIZED" > "$authorized_stage"
chmod 600 "$authorized_stage"
chown root:root "$authorized_stage"

config_count=$(grep -Ec "^ALLOW_PRODUCTION_FULL_OPT_IN='[01]'$" "$config_stage" || true)
raw_config_count=$(grep -Ec '^ALLOW_PRODUCTION_FULL_OPT_IN=' "$config_stage" || true)
[ "$config_count" = "$raw_config_count" ] || fail 'wrapper config full opt-in must be exactly 0 or 1'
[ "$config_count" -le 1 ] || fail 'staged wrapper config contains duplicate full opt-in settings'

restrict_count=$(awk -v target="$TARGET" '
index($0, target) && $0 ~ /^restrict,/ { count++ }
END { print count + 0 }
' "$authorized_stage")
[ "$restrict_count" = 1 ] || fail 'staged Bella key does not have restrict'

authorized_check="$DATA/authorized_keys.check.$stamp"
awk -v target="$TARGET" -v restrict_added="$restrict_added" '
{
    line = $0
    if (index(line, target) && restrict_added == 1 && line ~ /^restrict,/) {
        sub(/^restrict,/, "", line)
    }
    print line
}
' "$authorized_stage" > "$authorized_check"
cmp -s "$AUTHORIZED" "$authorized_check" || fail 'staged authorized_keys changes more than Bella restrict'
rm -f "$authorized_check"

mutation_started=1
mv -f "$wrapper_stage" "$WRAPPER"
mv -f "$config_stage" "$CONFIG"
mv -f "$authorized_stage" "$AUTHORIZED"

test "$(sha256sum "$WRAPPER" | awk '{print toupper($1)}')" = "$EXPECTED_SHA" || fail 'installed wrapper SHA mismatch'
test "$(stat -c '%a' "$WRAPPER")" = 700 || fail 'wrapper mode is not 700'
test "$(stat -c '%a' "$CONFIG")" = 600 || fail 'wrapper config mode is not 600'
test "$(stat -c '%a' "$AUTHORIZED")" = 600 || fail 'authorized_keys mode is not 600'
test "$(stat -c '%U:%G' "$WRAPPER")" = root:root || fail 'wrapper owner mismatch'
test "$(stat -c '%U:%G' "$CONFIG")" = root:root || fail 'wrapper config owner mismatch'
test "$(stat -c '%U:%G' "$AUTHORIZED")" = root:root || fail 'authorized_keys owner mismatch'
sh -n "$WRAPPER" || fail 'installed wrapper shell syntax failed'
sshd -t || fail 'sshd configuration validation failed'

final_restrict_count=$(awk -v target="$TARGET" '
index($0, target) && $0 ~ /^restrict,/ { count++ }
END { print count + 0 }
' "$AUTHORIZED")
[ "$final_restrict_count" = 1 ] || fail 'installed Bella key restrict verification failed'

mutation_started=0
trap - EXIT

printf '%s\n' 'BELLA_WRAPPER_SYNC_OK'
printf '%s\n' "wrapper_sha=$EXPECTED_SHA"
printf '%s\n' "backup_stamp=$stamp"
printf '%s\n' "wrapper_backup=$wrapper_backup"
printf '%s\n' "config_backup=$config_backup"
printf '%s\n' "authorized_backup=$authorized_backup"
