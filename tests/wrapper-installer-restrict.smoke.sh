#!/usr/bin/env sh
set -eu

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' 0 1 2 15

target='command="/root/.local/libexec/wordpress-ssh-deploy/bella-maria/root-ssh-wrapper.sh /root/.wordpress-ssh-deploy/bella-maria/wrapper.config"'

stage_authorized() {
	input=$1
	output=$2
	awk -v target="$target" '
index($0, target) {
		if ($0 !~ /(^|,)restrict(,|[[:space:]])/) {
			$0 = "restrict," $0
		}
}
{ print }
' "$input" > "$output"
}

compare_authorized() {
	current=$1
	staged=$2
	restrict_added=$3
	check="$tmp/check.$restrict_added"
	awk -v target="$target" -v restrict_added="$restrict_added" '
{
		line = $0
		if (index(line, target) && restrict_added == 1 && line ~ /^restrict,/) {
			sub(/^restrict,/, "", line)
		}
		print line
}
' "$staged" > "$check"
	cmp -s "$current" "$check"
}

existing="$tmp/existing"
existing_staged="$tmp/existing.staged"
printf '%s\n' "restrict,$target,no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAAexisting" > "$existing"
existing_restrict_count=$(awk -v target="$target" '
index($0, target) && $0 ~ /(^|,)restrict(,|[[:space:]])/ { count++ }
END { print count + 0 }
' "$existing")
[ "$existing_restrict_count" = 1 ]
restrict_added=0
[ "$existing_restrict_count" = 1 ] || restrict_added=1
stage_authorized "$existing" "$existing_staged"
cmp -s "$existing" "$existing_staged"
compare_authorized "$existing" "$existing_staged" "$restrict_added"

plain="$tmp/plain"
plain_staged="$tmp/plain.staged"
printf '%s\n' "$target,no-agent-forwarding ssh-ed25519 AAAAplain" > "$plain"
plain_restrict_count=$(awk -v target="$target" '
index($0, target) && $0 ~ /(^|,)restrict(,|[[:space:]])/ { count++ }
END { print count + 0 }
' "$plain")
[ "$plain_restrict_count" = 0 ]
restrict_added=1
stage_authorized "$plain" "$plain_staged"
grep -F -- "restrict,$target" "$plain_staged" >/dev/null
compare_authorized "$plain" "$plain_staged" "$restrict_added"

printf '%s\n' 'Wrapper installer restrict idempotence: OK'
