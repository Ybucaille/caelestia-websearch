#!/usr/bin/env bash

# Shared, side-effect-free helpers for the installer and uninstaller.
# shellcheck shell=bash

ADDON_ID="caelestia-websearch"
ADDON_VERSION="1.0.0"
SUPPORTED_CAELESTIA_VERSION="2.4.0-1"
KNOWN_MANUAL_APPLIST_DIGEST="6d3c6c902ede43a923e448593e17d91300e7406e048559bc0b0e6d7537d8a93a"

MANAGED_FILES=(
    "modules/launcher/AppList.qml"
    "modules/launcher/Content.qml"
    "modules/launcher/services/WebSearch.qml"
)

PACKAGE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PAYLOAD_DIGEST=""
LOCAL_ROOT=""
STATE_ROOT=""
SYSTEM_ROOT=""

info() {
    printf '[caelestia-websearch] %s\n' "$*"
}

warn() {
    printf '[caelestia-websearch] WARNING: %s\n' "$*" >&2
}

error() {
    printf '[caelestia-websearch] ERROR: %s\n' "$*" >&2
}

die() {
    error "$*"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

normalise_path() {
    realpath -m -- "$1"
}

assert_safe_write_root() {
    local path=$1
    local label=$2

    case "$path" in
        "" | / | /etc | /etc/* | /usr | /usr/* | /boot | /boot/* | /dev | /dev/* | /proc | /proc/* | /sys | /sys/*)
            die "Refusing unsafe $label path: $path"
            ;;
    esac
}

init_common_paths() {
    require_command realpath

    [[ -n ${HOME:-} && $HOME != / ]] || die 'HOME is unset or unsafe.'

    local config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
    local state_home=${XDG_STATE_HOME:-"$HOME/.local/state"}
    local local_input=${CAELESTIA_WEBSEARCH_LOCAL_DIR:-"$config_home/quickshell/caelestia"}
    local state_input=${CAELESTIA_WEBSEARCH_STATE_DIR:-"$state_home/$ADDON_ID"}

    [[ ! -L $local_input ]] || die "The local Caelestia root is a symlink; refusing to modify it: $local_input"
    [[ ! -L $state_input ]] || die "The addon state root is a symlink; refusing to use it: $state_input"

    LOCAL_ROOT=$(normalise_path "$local_input")
    STATE_ROOT=$(normalise_path "$state_input")

    assert_safe_write_root "$LOCAL_ROOT" 'local configuration'
    assert_safe_write_root "$STATE_ROOT" 'state'
    [[ $LOCAL_ROOT != "$STATE_ROOT" ]] || die 'The local configuration and state paths must be different.'
    case "$STATE_ROOT/" in
        "$LOCAL_ROOT/"*) die 'The addon state directory must not be inside the Caelestia configuration.' ;;
    esac
    case "$LOCAL_ROOT/" in
        "$STATE_ROOT/"*) die 'The Caelestia configuration must not be inside the addon state directory.' ;;
    esac
}

discover_system_root() {
    local candidate=""

    if [[ -n ${CAELESTIA_WEBSEARCH_SYSTEM_DIR:-} ]]; then
        candidate=$CAELESTIA_WEBSEARCH_SYSTEM_DIR
    else
        local xdg_dirs=${XDG_CONFIG_DIRS:-/etc/xdg}
        local base
        local old_ifs=$IFS
        IFS=:
        for base in $xdg_dirs; do
            [[ -n $base ]] || base=/etc/xdg
            if [[ -f $base/quickshell/caelestia/shell.qml ]]; then
                candidate=$base/quickshell/caelestia
                break
            fi
        done
        IFS=$old_ifs

        if [[ -z $candidate && -f /etc/xdg/quickshell/caelestia/shell.qml ]]; then
            candidate=/etc/xdg/quickshell/caelestia
        fi
    fi

    [[ -n $candidate ]] || die 'Could not find the system Caelestia shell configuration.'
    SYSTEM_ROOT=$(realpath -e -- "$candidate") || die "Could not resolve the system Caelestia path: $candidate"
    [[ $SYSTEM_ROOT != "$LOCAL_ROOT" ]] || die 'System and local Caelestia paths unexpectedly resolve to the same directory.'
    case "$LOCAL_ROOT/" in
        "$SYSTEM_ROOT/"*) die 'The local Caelestia path must not be inside the read-only system installation.' ;;
    esac
}

expected_base_digest() {
    case "$1" in
        modules/launcher/AppList.qml)
            printf '%s\n' '11b85781e9a35e372f0266658419bea5d2cb297006208f90c6a0a27d57b42b9e'
            ;;
        modules/launcher/Content.qml)
            printf '%s\n' '45c2df8d52bc3a8c301d27a75685b1f3813a2db4b01204dc8bdd84c574e57182'
            ;;
        *)
            return 1
            ;;
    esac
}

file_digest() {
    sha256sum -- "$1" | awk '{print $1}'
}

verify_payload() {
    require_command sha256sum

    [[ -f $PACKAGE_ROOT/SHA256SUMS ]] || die 'SHA256SUMS is missing from the addon directory.'
    if ! (cd -- "$PACKAGE_ROOT" && sha256sum --check --strict SHA256SUMS); then
        die 'Payload verification failed. Download a clean copy of the addon.'
    fi

    PAYLOAD_DIGEST=$(file_digest "$PACKAGE_ROOT/SHA256SUMS")
}

detect_versions() {
    [[ $(uname -s) == Linux ]] || die 'This addon supports Linux only.'

    if [[ -f /etc/arch-release ]]; then
        info 'Operating system: Arch Linux'
    else
        warn 'Arch Linux was not detected. Installation will continue only if the launcher structure is compatible.'
    fi

    local shell_version=""
    if command -v pacman >/dev/null 2>&1; then
        shell_version=$(pacman -Q caelestia-shell 2>/dev/null | awk 'NR == 1 {print $2}' || true)
    fi

    if [[ -n $shell_version ]]; then
        info "Detected caelestia-shell version: $shell_version"
        if [[ $shell_version != "$SUPPORTED_CAELESTIA_VERSION" ]]; then
            warn "This release targets caelestia-shell $SUPPORTED_CAELESTIA_VERSION; checking file compatibility before continuing."
        fi
    else
        warn 'Could not determine the caelestia-shell package version; checking file compatibility instead.'
    fi

    if command -v caelestia >/dev/null 2>&1; then
        local cli_version=""
        if command -v pacman >/dev/null 2>&1; then
            cli_version=$(pacman -Q caelestia-cli 2>/dev/null | awk 'NR == 1 {print $2}' || true)
        fi
        if [[ -z $cli_version ]]; then
            cli_version=$(caelestia --version 2>/dev/null | awk '$1 == "caelestia-cli" {print $2; exit}' || true)
        fi
        [[ -n $cli_version ]] && info "Detected Caelestia CLI: $cli_version"
    else
        warn 'The Caelestia CLI was not found; Quickshell will be used directly for a running-shell restart.'
    fi

    if command -v qs >/dev/null 2>&1; then
        local qs_version
        qs_version=$(qs --version 2>/dev/null | head -n 1 || true)
        [[ -n $qs_version ]] && info "Detected Quickshell: $qs_version"
    fi
}

verify_supported_launcher() {
    local rel expected actual

    [[ -f $SYSTEM_ROOT/shell.qml ]] || die "Expected shell.qml not found below $SYSTEM_ROOT"

    for rel in "${MANAGED_FILES[@]:0:2}"; do
        [[ -f $SYSTEM_ROOT/$rel ]] || die "Expected launcher file not found: $SYSTEM_ROOT/$rel"
        expected=$(expected_base_digest "$rel")
        actual=$(file_digest "$SYSTEM_ROOT/$rel")
        if [[ $actual != "$expected" ]]; then
            die "Unsupported launcher structure in $rel. This release targets Caelestia Shell $SUPPORTED_CAELESTIA_VERSION and made no changes."
        fi
    done

    info "Launcher structure is compatible with Caelestia Shell $SUPPORTED_CAELESTIA_VERSION."
}

check_quickshell_selection() {
    local quickshell_home
    quickshell_home=$(dirname -- "$LOCAL_ROOT")

    if [[ -e $quickshell_home/shell.qml ]]; then
        die "Quickshell's default config exists at $quickshell_home/shell.qml and prevents named configs from being selected. It was not modified."
    fi

    if [[ -e $quickshell_home/manifest.conf ]]; then
        die "A legacy Quickshell manifest exists at $quickshell_home/manifest.conf and may redirect the caelestia config. It was not modified."
    fi
}

assert_local_layout() {
    [[ -d $LOCAL_ROOT ]] || die "Local Caelestia directory not found: $LOCAL_ROOT"
    [[ -f $LOCAL_ROOT/shell.qml && ! -L $LOCAL_ROOT/shell.qml ]] || die "A regular local shell.qml is required at $LOCAL_ROOT/shell.qml"

    local rel target
    for rel in "${MANAGED_FILES[@]:0:2}"; do
        target=$LOCAL_ROOT/$rel
        [[ -f $target && ! -L $target ]] || die "Expected regular launcher file not found: $target"
    done

    [[ ! -L $LOCAL_ROOT/modules/launcher/services ]] || die 'The launcher services directory is a symlink; refusing to modify it.'
}

acquire_state_lock() {
    require_command flock
    mkdir -p -- "$STATE_ROOT"
    chmod 700 -- "$STATE_ROOT" 2>/dev/null || true
    exec 9>"$STATE_ROOT/lock"
    flock -n 9 || die "Another $ADDON_ID operation is already running."
}

find_qt6_qmlformat() {
    local tool version
    for tool in /usr/lib/qt6/bin/qmlformat qmlformat6 qmlformat; do
        if [[ $tool == */* ]]; then
            [[ -x $tool ]] || continue
        else
            tool=$(command -v "$tool" 2>/dev/null || true)
            [[ -n $tool ]] || continue
        fi

        version=$($tool --version 2>&1 || true)
        if [[ $tool == /usr/lib/qt6/* || $version == *' 6.'* || $version == *'Qt 6'* ]]; then
            printf '%s\n' "$tool"
            return 0
        fi
    done

    return 1
}

validate_qml_files() {
    local validator file
    if ! validator=$(find_qt6_qmlformat); then
        warn 'Qt 6 qmlformat was not found; merged QML syntax could not be checked locally.'
        return 0
    fi

    for file in "$@"; do
        if ! "$validator" "$file" >/dev/null; then
            error "QML syntax validation failed: $file"
            return 1
        fi
    done

    info "QML syntax validated with $validator."
}

atomic_copy() {
    local source=$1
    local target=$2
    local target_dir temp

    target_dir=$(dirname -- "$target")
    mkdir -p -- "$target_dir"
    temp=$(mktemp "$target_dir/.caelestia-websearch.XXXXXX") || return 1

    if ! cp --preserve=mode,timestamps -- "$source" "$temp"; then
        rm -f -- "$temp"
        return 1
    fi

    if ! mv -fT -- "$temp" "$target"; then
        rm -f -- "$temp"
        return 1
    fi
}

atomic_text() {
    local text_value=$1
    local target=$2
    local target_dir temp

    target_dir=$(dirname -- "$target")
    mkdir -p -- "$target_dir"
    temp=$(mktemp "$target_dir/.caelestia-websearch.XXXXXX") || return 1
    if ! printf '%s\n' "$text_value" > "$temp"; then
        rm -f -- "$temp"
        return 1
    fi
    if ! mv -fT -- "$temp" "$target"; then
        rm -f -- "$temp"
        return 1
    fi
}

read_action() {
    local generation=$1
    local rel=$2
    local action_file=$generation/actions/$rel
    local action=""

    [[ -f $action_file ]] || return 1
    IFS= read -r action < "$action_file"
    case "$action" in
        replace | create | unchanged)
            printf '%s\n' "$action"
            ;;
        *)
            return 1
            ;;
    esac
}

rollback_generation() {
    local generation=$1
    local rel action target

    for rel in "${MANAGED_FILES[@]}"; do
        action=$(read_action "$generation" "$rel") || continue
        target=$LOCAL_ROOT/$rel
        case "$action" in
            replace)
                atomic_copy "$generation/original/$rel" "$target" || return 1
                ;;
            create)
                rm -f -- "$target" || return 1
                ;;
            unchanged)
                ;;
        esac
    done
}

list_instances_for_managed_shell() {
    command -v qs >/dev/null 2>&1 || return 0

    local system_shell=""
    [[ -n $SYSTEM_ROOT ]] && system_shell=$SYSTEM_ROOT/shell.qml

    qs list --all 2>/dev/null | awk -v local_shell="$LOCAL_ROOT/shell.qml" -v system_shell="$system_shell" '
        /^Instance [^:]+:/ {
            id = $2
            sub(/:$/, "", id)
        }
        /^  Config path: / {
            path = $0
            sub(/^  Config path: /, "", path)
            if (path == local_shell || (system_shell != "" && path == system_shell))
                print id
        }
    '
}

local_shell_is_running() {
    local id
    while IFS= read -r id; do
        [[ -n $id ]] && return 0
    done < <(list_instances_for_managed_shell)
    return 1
}

restart_if_running() {
    local -a instance_ids=("$@")
    local id attempt

    if [[ ${CAELESTIA_WEBSEARCH_SKIP_RESTART:-0} == 1 ]]; then
        info 'Shell restart skipped by CAELESTIA_WEBSEARCH_SKIP_RESTART=1.'
        return 0
    fi

    if ((${#instance_ids[@]} == 0)); then
        info 'No active Caelestia instance was found; the local config will be used on the next launch.'
        return 0
    fi

    for id in "${instance_ids[@]}"; do
        if ! qs kill --id "$id" >/dev/null 2>&1; then
            warn "Could not stop Caelestia instance $id. Restart it manually after installation."
            return 0
        fi
    done

    for attempt in {1..20}; do
        sleep 0.25
        local still_running=0
        local running_id
        while IFS= read -r running_id; do
            for id in "${instance_ids[@]}"; do
                [[ $running_id == "$id" ]] && still_running=1
            done
        done < <(list_instances_for_managed_shell)
        ((still_running == 0)) && break
    done

    if ! qs --path "$LOCAL_ROOT" --no-duplicate --daemonize >/dev/null 2>&1; then
        warn "Could not restart Caelestia. Run: qs -p '$LOCAL_ROOT' -n -d"
        return 0
    fi

    for attempt in {1..40}; do
        sleep 0.25
        if local_shell_is_running; then
            info "Caelestia restarted from $LOCAL_ROOT/shell.qml"
            return 0
        fi
    done

    warn "Caelestia did not report a running local instance. Run: qs -p '$LOCAL_ROOT' -n -d"
}

print_backup_location() {
    info "Backups and install state: $STATE_ROOT"
}
