#!/bin/sh

# Generic forced-command wrapper for a root SSH key.
#
# This file contains no site profile or secret. Install a private config next
# to it on the server and reference it from one site's authorized_keys entry:
# command="/root/.../root-ssh-wrapper.sh /root/.../site-wrapper.config"
#
# The wrapper intentionally accepts only the protocol emitted by deploy.ps1:
# the fixed runner, fixed temporary directory operations, and legacy scp. The
# runner protocol includes independent code, DB, uploads and plugins modes.
# It never provides an interactive shell and rejects traversal or shell syntax.

set -eu

die() {
    printf '%s\n' "root-ssh-wrapper: $*" >&2
    exit 126
}

[ "$#" -eq 1 ] || die 'expected one private wrapper config path'
CONFIG_FILE=$1
[ -f "$CONFIG_FILE" ] || die 'wrapper config is missing'
# Never trust an SSH-provided PATH while checking the root-owned policy file.
PATH=/usr/bin:/bin
export PATH
if ! effective_uid=$(id -u 2>/dev/null); then
    die 'cannot determine effective uid'
fi
case "$effective_uid" in
    ''|*[!0-9]*) die 'cannot determine effective uid' ;;
esac
if [ "$effective_uid" -eq 0 ]; then
    config_owner=$(stat -c '%u' "$CONFIG_FILE" 2>/dev/null || printf '%s' '-1')
    [ "$config_owner" = 0 ] || die 'wrapper config must be owned by root'
    config_mode=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || printf '%s' '777')
    case "$config_mode" in
        [0-7][2367][0-7]|[0-7][0-7][2367]) die 'wrapper config must not be group/world writable' ;;
    esac
fi

# The config is server-local and must be root-owned. It is intentionally
# sourced only after the forced command has selected this wrapper.
# shellcheck disable=SC1090
# These values are policy inputs, not client-controlled environment. Clear
# inherited values before loading the site-local root-owned configuration.
unset SCP_BIN REMOTE_RUNNER_PATH REMOTE_TMP_PATH ALLOW_PRODUCTION_FULL_OPT_IN
. "$CONFIG_FILE"

[ -n "${REMOTE_RUNNER_PATH-}" ] || die 'REMOTE_RUNNER_PATH is required'
[ -n "${REMOTE_TMP_PATH-}" ] || die 'REMOTE_TMP_PATH is required'
ALLOW_PRODUCTION_FULL_OPT_IN=${ALLOW_PRODUCTION_FULL_OPT_IN:-0}
case "$ALLOW_PRODUCTION_FULL_OPT_IN" in
    0|1) ;;
    *) die 'ALLOW_PRODUCTION_FULL_OPT_IN must be 0 or 1' ;;
esac
SCP_BIN=${SCP_BIN:-/usr/bin/scp}

case "$REMOTE_RUNNER_PATH" in
    /*) ;;
    *) die 'REMOTE_RUNNER_PATH must be an absolute POSIX path' ;;
esac
case "$REMOTE_TMP_PATH" in
    /*) ;;
    *) die 'REMOTE_TMP_PATH must be an absolute POSIX path' ;;
esac
case "$REMOTE_TMP_PATH" in
    */) die 'REMOTE_TMP_PATH must not end with /' ;;
esac

safe_value() {
    # Values are generated as single-quoted shell values by the client. The
    # server profile protocol deliberately supports only portable path/URL
    # characters; shell metacharacters and whitespace are rejected.
    case "$1" in
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.,:/@%+=?\&#~-]*) return 1 ;;
        *) return 0 ;;
    esac
}

safe_basename() {
    case "$1" in
        ''|.|..|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

safe_plugin_path_list() {
    plugin_path_list=$1
    [ -n "$plugin_path_list" ] || return 0
    case "$plugin_path_list" in
        ,*|*,|*,,*) return 1 ;;
    esac

    validation_old_ifs=$IFS
    IFS=','
    for plugin_path in $plugin_path_list; do
        IFS=$validation_old_ifs
        case "$plugin_path" in
            ''|.|*/|/*|*\\*|*:*) return 1 ;;
            ../*|*/../*|*/..|./*|*/./*|*/.) return 1 ;;
            wp-content/plugins/*) ;;
            *) return 1 ;;
        esac
        IFS=','
    done
    IFS=$validation_old_ifs
}

safe_mu_plugin_path_list() {
    mu_plugin_path_list=$1
    [ -n "$mu_plugin_path_list" ] || return 0
    case "$mu_plugin_path_list" in
        ,*|*,|*,,*) return 1 ;;
    esac

    validation_old_ifs=$IFS
    IFS=','
    for mu_plugin_path in $mu_plugin_path_list; do
        IFS=$validation_old_ifs
        case "$mu_plugin_path" in
            ''|.|*/|/*|*\\*|*:*) return 1 ;;
            ../*|*/../*|*/..|./*|*/./*|*/.) return 1 ;;
            wp-content/mu-plugins/*) ;;
            *) return 1 ;;
        esac
        IFS=','
    done
    IFS=$validation_old_ifs
}

safe_mode_list() {
    mode_list=$1
    [ -n "$mode_list" ] || return 1
    case "$mode_list" in
        ,*|*,|*,,*) return 1 ;;
    esac

    mode_list_seen=','
    validation_old_ifs=$IFS
    IFS=','
    for allowed_mode in $mode_list; do
        IFS=$validation_old_ifs
        case "$allowed_mode" in
            preflight|code|db|code-db|uploads|plugins|mu-plugins|full) ;;
            *) return 1 ;;
        esac
        case "$mode_list_seen" in
            *",$allowed_mode,"*) return 1 ;;
        esac
        mode_list_seen=$mode_list_seen$allowed_mode','
        IFS=','
    done
    IFS=$validation_old_ifs
}

reject_control_chars() {
    control_lf=$(printf '\nx')
    control_lf=${control_lf%x}
    control_cr=$(printf '\rx')
    control_cr=${control_cr%x}
    control_tab=$(printf '\tx')
    control_tab=${control_tab%x}
    case "$1" in
        *"$control_lf"*|*"$control_cr"*|*"$control_tab"*) return 1 ;;
        *) return 0 ;;
    esac
}

strip_single_quotes() {
    token=$1
    case "$token" in
        \'*\')
            token=${token#\'}
            token=${token%\'}
            printf '%s' "$token"
            ;;
        *) return 1 ;;
    esac
}

fixed_artifact_path() {
    token=$1
    case "$token" in
        \'*\') token=$(strip_single_quotes "$token") || return 1 ;;
    esac
    case "$token" in
        "$REMOTE_TMP_PATH"/*)
            basename=${token#"$REMOTE_TMP_PATH"/}
            [ "$basename" = "${basename##*/}" ] || return 1
            safe_basename "$basename" || return 1
            printf '%s/%s' "$REMOTE_TMP_PATH" "$basename"
            ;;
        *) return 1 ;;
    esac
}

run_runner_command() {
    command=$1
    # Disable pathname expansion before tokenizing the already received SSH
    # command. Contents of a variable are not recursively evaluated by the
    # shell, and every token/value is checked below before execution.
    set -f
    old_ifs=$IFS
    IFS=' '
    # shellcheck disable=SC2086
    set -- $command
    IFS=$old_ifs

    [ "$#" -ge 3 ] || die 'runner command is incomplete'
    seen=' '
    command_environment=''
    command_mode=''
    production_full_opt_in=''
    production_full_opt_in_seen=0
    plugin_sync_paths=''
    plugin_sync_paths_seen=0
    mu_plugin_sync_paths=''
    mu_plugin_sync_paths_seen=0
    allowed_deploy_modes=''
    allowed_deploy_modes_seen=0
    while [ "$#" -gt 2 ]; do
        token=$1
        shift
        case "$token" in
            LOCAL_URL=\'*\'|REMOTE_URL=\'*\'|ENVIRONMENT=\'*\'|EXPECTED_REMOTE_DOMAIN=\'*\'|WP_DIR=\'*\'|REPO_DIR=\'*\'|BACKUP_DIR=\'*\'|KEEP_BACKUPS=\'*\'|MIN_REMOTE_FREE_SPACE_MB=\'*\'|GIT_SSH_KEY=\'*\'|PHP_BIN=\'*\'|WP_CLI_BIN=\'*\'|EXPECTED_WP_DIR=\'*\'|EXPECTED_DB_NAME=\'*\'|EXPECTED_DB_TABLE_PREFIX=\'*\'|EXPECTED_DB_TABLE_COUNT=\'*\'|SYNC_PATHS=\'*\'|PLUGIN_SYNC_PATHS=\'*\'|MU_PLUGIN_SYNC_PATHS=\'*\'|ALLOWED_DEPLOY_MODES=\'*\'|FULL_SYNC_PATHS=\'*\'|PROTECTED_PATHS=\'*\'|PROTECTED_ARCHIVE=\'*\'|REPLACE_PROTECTED=\'*\'|DEPLOY_MODE=\'*\'|PRODUCTION_FULL_OPT_IN=\'*\'|SQL_FILE=\'*\'|UPLOADS_ZIP=\'*\'|UPLOADS_DELTA_ZIP=\'*\'|UPLOADS_MANIFEST_FILE=\'*\'|ALLOW_PRODUCTION_PULL=\'*\'|ALLOW_PRODUCTION_CACHE_CLEAR=\'*\'|CACHE_PATHS=\'*\'|PULL_ARTIFACT=\'*\'|PULL_PATHS=\'*\')
                name=${token%%=*}
                value=${token#*=}
                value=$(strip_single_quotes "$value") || die 'runner value must be single-quoted'
                safe_value "$value" || die 'runner value contains unsupported characters'
                case "$name" in
                    ENVIRONMENT)
                        command_environment=$value
                        ;;
                    PRODUCTION_FULL_OPT_IN)
                        production_full_opt_in_seen=1
                        production_full_opt_in=$value
                        case "$value" in
                            0) ;;
                            1)
                                [ "$ALLOW_PRODUCTION_FULL_OPT_IN" = 1 ] || die 'production full-mode token is disabled by wrapper policy'
                                ;;
                            *) die 'production full-mode token must be 0 or 1' ;;
                        esac
                        ;;
                    PLUGIN_SYNC_PATHS)
                        safe_plugin_path_list "$value" || die 'plugin sync paths are not allowed'
                        plugin_sync_paths_seen=1
                        plugin_sync_paths=$value
                        ;;
                    MU_PLUGIN_SYNC_PATHS)
                        safe_mu_plugin_path_list "$value" || die 'mu-plugin sync paths are not allowed'
                        mu_plugin_sync_paths_seen=1
                        mu_plugin_sync_paths=$value
                        ;;
                    ALLOWED_DEPLOY_MODES)
                        safe_mode_list "$value" || die 'runner mode policy is not allowed'
                        allowed_deploy_modes_seen=1
                        allowed_deploy_modes=$value
                        ;;
                    DEPLOY_MODE)
                        command_mode=$value
                        case "$value" in
                            preflight|code|db|code-db|uploads|plugins|mu-plugins|full) ;;
                            *) die 'runner mode is not allowed' ;;
                        esac
                        ;;
                esac
                case "$seen" in
                    *" $name "*) die 'duplicate runner assignment' ;;
                esac
                seen=$seen$name' '
                ;;
            *) die 'runner command contains an unapproved token' ;;
        esac
    done

    [ -n "$command_environment" ] || die 'runner environment is required'
    [ -n "$command_mode" ] || die 'runner mode is required'
    case "$command_environment" in
        development|staging|production) ;;
        *) die 'runner environment is not allowed' ;;
    esac

    if [ "$allowed_deploy_modes_seen" -eq 1 ]; then
        case ",$allowed_deploy_modes," in
            *",$command_mode,"*) ;;
            *) die 'runner mode is not enabled by client policy' ;;
        esac
    fi
    case "$command_mode" in
        code-db|uploads|plugins|mu-plugins)
            [ "$allowed_deploy_modes_seen" -eq 1 ] || die 'component mode requires an explicit client policy'
            ;;
    esac
    if [ "$command_mode" = plugins ]; then
        [ "$plugin_sync_paths_seen" -eq 1 ] && [ -n "$plugin_sync_paths" ] || die 'plugins mode requires plugin sync paths'
    fi
    if [ "$command_mode" = mu-plugins ]; then
        [ "$mu_plugin_sync_paths_seen" -eq 1 ] && [ -n "$mu_plugin_sync_paths" ] || die 'mu-plugins mode requires mu-plugin sync paths'
    fi

    if [ "$production_full_opt_in_seen" -eq 1 ] && [ "$production_full_opt_in" = 1 ]; then
        [ "$command_environment" = production ] || die 'production full-mode token requires production environment'
        [ "$command_mode" = full ] || die 'production full-mode token requires full mode'
    fi
    if [ "$command_environment" = production ] && [ "$command_mode" = full ]; then
        [ "$production_full_opt_in_seen" -eq 1 ] && [ "$production_full_opt_in" = 1 ] || die 'production full mode requires an explicit client token'
    fi

    [ "$1" = 'sh' ] || die 'runner command must invoke sh'
    shift
    [ "$#" -eq 1 ] || die 'runner command has unexpected trailing tokens'
    runner=$(strip_single_quotes "$1") || die 'runner path must be single-quoted'
    [ "$runner" = "$REMOTE_RUNNER_PATH" ] || die 'runner path does not match policy'
    # The parser above permits only assignment tokens and the fixed runner;
    # executing this exact protocol is now safe and preserves the runner's
    # existing environment-based interface.
    PATH=/usr/bin:/bin
    export PATH
    exec sh -c "$command"
}

run_scp_command() {
    command=$1
    set -f
    old_ifs=$IFS
    IFS=' '
    # shellcheck disable=SC2086
    set -- $command
    IFS=$old_ifs
    [ "$#" -eq 3 ] || die 'scp command must contain exactly one path'
    [ "$1" = 'scp' ] || die 'only scp is allowed for file transfer'
    case "$2" in
        -f|-t) ;;
        *) die 'scp mode is not allowed' ;;
    esac
    path=$(fixed_artifact_path "$3") || die 'scp path is outside the fixed temporary directory'
    exec "$SCP_BIN" "$2" "$path"
}

ORIGINAL_COMMAND=${SSH_ORIGINAL_COMMAND-}
[ -n "$ORIGINAL_COMMAND" ] || die 'interactive shell is disabled'
reject_control_chars "$ORIGINAL_COMMAND" || die 'command contains unsupported control characters'

case "$ORIGINAL_COMMAND" in
    "mkdir -p '$REMOTE_TMP_PATH'")
        exec /bin/mkdir -p -- "$REMOTE_TMP_PATH"
        ;;
    rm\ -f\ *)
        set -f
        old_ifs=$IFS
        IFS=' '
        # shellcheck disable=SC2086
        set -- $ORIGINAL_COMMAND
        IFS=$old_ifs
        [ "$#" -ge 3 ] || die 'rm command is incomplete'
        [ "$1" = 'rm' ] && [ "$2" = '-f' ] || die 'only rm -f is allowed'
        shift 2
        for token in "$@"; do
            path=$(fixed_artifact_path "$token") || die 'rm path is outside the fixed temporary directory'
            /bin/rm -f -- "$path"
        done
        exit 0
        ;;
    scp\ -f\ *|scp\ -t\ *)
        run_scp_command "$ORIGINAL_COMMAND"
        ;;
    *)
        run_runner_command "$ORIGINAL_COMMAND"
        ;;
esac
