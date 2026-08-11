#!/usr/bin/env sh

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
	*' config get table_prefix '*)
		printf '%s\n' "${FIXTURE_TABLE_PREFIX:-wp_}"
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
	*)
		echo 'Unexpected fake PHP invocation' >&2
		exit 1
		;;
esac
