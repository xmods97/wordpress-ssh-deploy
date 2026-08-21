#!/usr/bin/env sh

: "${FIXTURE_ROOT:?FIXTURE_ROOT is required}"
if [ "${0##*/}" = chmod ]; then
	printf '%s\n' "$*" >> "$FIXTURE_ROOT/chmod-calls.log"
	if [ "${FIXTURE_CHMOD_FAIL:-0}" = 1 ]; then exit 1; fi
	if [ "${FIXTURE_CHMOD_FAIL_DIR:-0}" = 1 ]; then
		case "$*" in
			*protected-manual-recovery-*) exit 1 ;;
		esac
	fi
	case "$*" in
		*RECOVERY.txt)
			if [ "${FIXTURE_CHMOD_FAIL_MARKER:-0}" = 1 ]; then exit 1; fi
			;;
	esac
	exit 0
fi
printf '%s\n' 'call' >> "$FIXTURE_ROOT/mysql-calls.log"
if [ "${FIXTURE_DELETE_BACKUP_ON_FIRST_IMPORT:-0}" = 1 ] && [ ! -e "$FIXTURE_ROOT/backup-deleted.marker" ]; then
	: > "$FIXTURE_ROOT/backup-deleted.marker"
	for backup_file in "$FIXTURE_ROOT"/backups/db-*.sql; do
		[ -e "$backup_file" ] || continue
		rm -f "$backup_file"
	done
fi
if [ "${FIXTURE_CORRUPT_BACKUP_ON_FIRST_IMPORT:-0}" = 1 ] && [ ! -e "$FIXTURE_ROOT/backup-corrupted.marker" ]; then
	: > "$FIXTURE_ROOT/backup-corrupted.marker"
	for backup_file in "$FIXTURE_ROOT"/backups/db-*.sql; do
		[ -e "$backup_file" ] || continue
		printf '%s\n' 'CORRUPTED_BACKUP' > "$backup_file"
		break
	done
fi
if [ "${FIXTURE_FAIL_ALL_IMPORTS:-0}" = 1 ]; then exit 1; fi
if grep -q 'INCOMING_FAIL'; then exit 1; fi
exit 0
