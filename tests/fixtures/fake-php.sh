#!/usr/bin/env sh

if [ "${FIXTURE_ROOT:-}" != "" ]; then
	printf '%s\n' "$*" >> "$FIXTURE_ROOT/php-calls.log"
fi

case " $* " in
	*' search-replace '* )
		case "$*" in
			*' --dry-run --format=count'*) printf '%s\n' "${FIXTURE_REWRITE_DRY_RUN_REMAINING:-0}" ;;
			*) [ "${FIXTURE_FAIL_URL_REWRITE:-0}" = 1 ] && exit 1; printf '%s\n' 'WP-CLI mutation fixture' ;;
		esac
		exit 0
		;;
esac

case " $* " in
	*' eval '*)
		printf '%s\n' "${FIXTURE_ENVIRONMENT:-production}"
		;;
	*' option get home '*|*' option get siteurl '*)
		printf '%s\n' "${FIXTURE_URL:-https://example.com}"
		;;
	*' config get DB_NAME '*)
		printf '%s\n' "${FIXTURE_DB_NAME:-wordpress_production}"
		;;
	*' config get DB_USER '*)
		printf '%s\n' 'fixture_user'
		;;
	*' config get DB_PASSWORD '*)
		printf '%s\n' 'fixture_password'
		;;
	*' config get DB_HOST '*)
		printf '%s\n' 'localhost'
		;;
	*' --info '*)
		printf '%s\n' 'WP-CLI fixture'
		;;
	*' search-replace '*|*' option update '*|*' cache flush '*|*' transient delete '*|*' rewrite flush '*)
		printf '%s\n' 'WP-CLI mutation fixture'
		;;
	*)
		echo 'Unexpected fake PHP invocation' >&2
		exit 1
		;;
esac
