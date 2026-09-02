#!/usr/bin/env sh
set -eu

case "$1" in
	-tq) exit 0 ;;
	-Z1)
		printf '%s\n' 'manifest.tsv' 'delete.list' 'payload/' 'payload/2026/09/new.txt'
		exit 0
		;;
	-q)
		archive="$2"
		[ "$3" = '-d' ] || exit 1
		destination="$4"
		[ -n "${FIXTURE_ROOT:-}" ] || exit 1
		cp "$FIXTURE_ROOT/delta-source/manifest.tsv" "$destination/manifest.tsv"
		cp "$FIXTURE_ROOT/delta-source/delete.list" "$destination/delete.list"
		mkdir -p "$destination/payload/2026/09"
		cp "$FIXTURE_ROOT/delta-source/payload/2026/09/new.txt" "$destination/payload/2026/09/new.txt"
		exit 0
		;;
	*) exit 1 ;;
esac
