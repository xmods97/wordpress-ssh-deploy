#!/usr/bin/env sh

case " $* " in
	*' db tables '*)
		printf '%s\n' 'wp_options,wp_posts'
		;;
	*' db export '*)
		output=''
	previous=''
	for argument in "$@"; do
		if [ "$previous" = 'export' ]; then output="$argument"; break; fi
		previous="$argument"
	done
	[ -n "$output" ] || exit 1
	cat > "$output" <<'SQL'
-- MySQL dump 10.13  Distrib fixture
--
-- Table structure for table `wp_options`
CREATE TABLE `wp_options` (`option_id` bigint NOT NULL);
INSERT INTO `wp_options` VALUES (1);
-- Table structure for table `wp_posts`
CREATE TABLE `wp_posts` (`ID` bigint NOT NULL);
INSERT INTO `wp_posts` VALUES (1);
SQL
	;;
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
