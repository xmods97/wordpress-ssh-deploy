#!/usr/bin/env sh
set -eu

case "$1" in
	-tq) exit 0 ;;
	-Z1) printf '%s\n' '2026/08/new-upload.txt'; exit 0 ;;
	-l) printf '%s\n' '1 1 file'; exit 0 ;;
	-q)
		[ "$#" -eq 4 ] && [ "$3" = '-d' ] || exit 1
		mkdir -p "$4/2026/08"
		printf '%s\n' 'new upload' > "$4/2026/08/new-upload.txt"
		exit 0
		;;
	*) exit 1 ;;
esac
