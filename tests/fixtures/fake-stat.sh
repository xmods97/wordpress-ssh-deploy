#!/usr/bin/env sh
case "$*" in
	*"%U"*) printf '%s\n' "${FIXTURE_OWNER:-admin_nadry}" ;;
	*"%G"*) printf '%s\n' "${FIXTURE_GROUP:-admin_nadry}" ;;
	*"%u"*) printf '%s\n' "${FIXTURE_OWNER_UID:-1001}" ;;
	*) echo 'Unexpected fake stat invocation' >&2; exit 1 ;;
esac
