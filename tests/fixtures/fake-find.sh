#!/usr/bin/env sh
set -eu

if [ "${FIXTURE_FIND_FAIL:-0}" = '1' ] && [ "${PWD:-}" = "${FIXTURE_FIND_FAIL_DIR:-}" ]; then
	printf '%s\n' 'fixture find failure' >&2
	exit 1
fi

exec /usr/bin/find "$@"
