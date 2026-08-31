#!/usr/bin/env sh
set -eu

while [ "$#" -gt 0 ]; do
	case "$1" in
		-u|-g) shift 2 ;;
		--) shift; break ;;
		*) break ;;
	esac
done

exec "$@"
