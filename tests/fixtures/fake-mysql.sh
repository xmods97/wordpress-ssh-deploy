#!/usr/bin/env sh

: "${FIXTURE_ROOT:?FIXTURE_ROOT is required}"
printf '%s\n' 'call' >> "$FIXTURE_ROOT/mysql-calls.log"
if grep -q 'INCOMING_FAIL'; then exit 1; fi
exit 0
