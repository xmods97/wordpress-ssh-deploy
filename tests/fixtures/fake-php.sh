#!/usr/bin/env sh

case "${FIXTURE_EXPECT_ALLOW_ROOT-}" in
	1)
		case " $* " in *' --allow-root '*) ;; *) echo 'Missing --allow-root for root WP-CLI invocation' >&2; exit 1 ;; esac
		;;
	0)
		case " $* " in *' --allow-root '*) echo 'Unexpected --allow-root for non-root WP-CLI invocation' >&2; exit 1 ;; esac
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
	*' search-replace '*)
		if [ -n "${FIXTURE_ROOT:-}" ]; then
			printf '%s\n' "$*" >> "$FIXTURE_ROOT/php-calls.log"
		fi
		case " $* " in
			*' --dry-run '*)
				case "${FIXTURE_REWRITE_DRY_RUN_REMAINING:-0}" in
					1) printf '%s\n' '1' ;;
					*) printf '%s\n' '0' ;;
				esac
				;;
			*)
				if [ "${FIXTURE_FAIL_URL_REWRITE:-0}" = 1 ]; then
					echo 'URL rewrite fixture failure' >&2
					exit 1
				fi
				printf '%s\n' 'Success: Made 1 replacement.'
				;;
		esac
		;;
	*' option update '*|*' cache flush '*|*' transient delete '*|*' rewrite flush '*)
		printf '%s\n' 'WP-CLI mutation fixture'
		;;
	*)
		echo 'Unexpected fake PHP invocation' >&2
		exit 1
		;;
esac
