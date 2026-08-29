#!/usr/bin/env sh
: "${FIXTURE_ROOT:?FIXTURE_ROOT is required}"
printf '%s\n' "$*" >> "$FIXTURE_ROOT/chown-calls.log"
[ "${FIXTURE_CHOWN_FAIL:-0}" = 1 ] && exit 1
exit 0
