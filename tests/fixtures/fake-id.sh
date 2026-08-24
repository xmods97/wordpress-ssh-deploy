#!/usr/bin/env sh

[ "$#" -eq 1 ] && [ "$1" = '-u' ] || {
	echo 'Unexpected fake id invocation' >&2
	exit 1
}

printf '%s\n' "${FIXTURE_EFFECTIVE_UID:-1000}"
