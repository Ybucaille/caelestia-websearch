#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

WORK_DIR=""
INIT_DIR=""
GENERATION_TMP=""

cleanup() {
    [[ -z $WORK_DIR || ! -d $WORK_DIR ]] || rm -rf -- "$WORK_DIR"
    [[ -z $INIT_DIR || ! -d $INIT_DIR ]] || rm -rf -- "$INIT_DIR"
    [[ -z $GENERATION_TMP || ! -d $GENERATION_TMP ]] || rm -rf -- "$GENERATION_TMP"
}
trap cleanup EXIT

show_existing_install() {
    [[ -f $STATE_ROOT/active ]] || return 1

    local generation_id generation stored_root stored_digest rel
    IFS= read -r generation_id < "$STATE_ROOT/active"
    [[ $generation_id =~ ^[A-Za-z0-9._-]+$ ]] || die 'The addon state contains an invalid active generation id.'

    generation=$STATE_ROOT/generations/$generation_id
    [[ -d $generation && -f $generation/status ]] || die 'The active addon backup is incomplete; refusing to overwrite it.'
    [[ $(<"$generation/status") == installed ]] || die 'The previous addon transaction is incomplete; inspect the backup directory before retrying.'
    [[ -f $generation/metadata/local-root ]] || die 'The active addon metadata is incomplete.'
    stored_root=$(<"$generation/metadata/local-root")
    [[ $stored_root == "$LOCAL_ROOT" ]] || die "The addon was installed for a different local config: $stored_root"

    stored_digest=""
    if [[ -f $generation/metadata/payload-digest ]]; then
        IFS= read -r stored_digest < "$generation/metadata/payload-digest"
    fi
    if [[ $stored_digest != "$PAYLOAD_DIGEST" ]]; then
        die 'A different addon release is installed. Run ./uninstall.sh before installing this release.'
    fi

    for rel in "${MANAGED_FILES[@]}"; do
        [[ -f $generation/installed/$rel && -f $LOCAL_ROOT/$rel ]] || die 'Managed files changed after installation. Run ./uninstall.sh before reinstalling.'
        cmp -s -- "$generation/installed/$rel" "$LOCAL_ROOT/$rel" || die 'Managed files changed after installation. Run ./uninstall.sh before reinstalling.'
    done

    info "Caelestia WebSearch $ADDON_VERSION is already installed; no files or backups were changed."
    print_backup_location
    return 0
}

initialise_local_copy() {
    local parent
    parent=$(dirname -- "$LOCAL_ROOT")
    mkdir -p -- "$parent"

    INIT_DIR=$(mktemp -d "$parent/.caelestia-websearch-init.XXXXXX")
    info "Creating a user-local Caelestia copy from $SYSTEM_ROOT"
    cp -R --preserve=mode,timestamps -- "$SYSTEM_ROOT/." "$INIT_DIR/"
    chmod --reference="$SYSTEM_ROOT" "$INIT_DIR" 2>/dev/null || true

    [[ ! -e $LOCAL_ROOT ]] || die "The local Caelestia directory appeared during installation: $LOCAL_ROOT"
}

prepare_generation() {
    local current_root=$1
    local local_created=$2
    local stamp rel current base payload staged action merge_code

    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p -- "$STATE_ROOT/generations"
    GENERATION_TMP=$(mktemp -d "$STATE_ROOT/generations/.pending-${stamp}-XXXXXX")
    mkdir -p -- "$GENERATION_TMP/metadata" "$GENERATION_TMP/actions" "$GENERATION_TMP/original" "$GENERATION_TMP/installed" "$GENERATION_TMP/staged"
    printf '%s\n' pending > "$GENERATION_TMP/status"
    printf '%s\n' "$LOCAL_ROOT" > "$GENERATION_TMP/metadata/local-root"
    printf '%s\n' "$local_created" > "$GENERATION_TMP/metadata/local-created"
    printf '%s\n' "$ADDON_VERSION" > "$GENERATION_TMP/metadata/addon-version"
    printf '%s\n' "$PAYLOAD_DIGEST" > "$GENERATION_TMP/metadata/payload-digest"

    for rel in "${MANAGED_FILES[@]}"; do
        current=$current_root/$rel
        payload=$PACKAGE_ROOT/$rel
        staged=$GENERATION_TMP/staged/$rel

        [[ ! -L $current ]] || die "Refusing to replace a symlinked managed file: $current"
        mkdir -p -- "$(dirname -- "$staged")"

        case "$rel" in
            modules/launcher/AppList.qml | modules/launcher/Content.qml)
                [[ -f $current ]] || die "Expected local launcher file not found: $current"
                base=$SYSTEM_ROOT/$rel
                if cmp -s -- "$current" "$payload" || \
                    [[ $rel == modules/launcher/AppList.qml && $(file_digest "$current") == "$KNOWN_MANUAL_APPLIST_DIGEST" ]]; then
                    cp --preserve=mode,timestamps -- "$payload" "$staged"
                elif diff3 --merge --show-overlap \
                    --label current --label "Caelestia-$SUPPORTED_CAELESTIA_VERSION" --label addon \
                    "$current" "$base" "$payload" > "$staged"; then
                    :
                else
                    merge_code=$?
                    if ((merge_code == 1)); then
                        error "The addon conflicts with existing custom changes in $rel. No Caelestia files were modified."
                    else
                        error "Could not merge $rel (diff3 exit $merge_code). No Caelestia files were modified."
                    fi
                    exit 1
                fi
                ;;
            *)
                cp --preserve=mode,timestamps -- "$payload" "$staged"
                ;;
        esac

        if [[ -f $current ]]; then
            chmod --reference="$current" "$staged" 2>/dev/null || true
            if cmp -s -- "$current" "$staged"; then
                action=unchanged
            else
                action=replace
                mkdir -p -- "$(dirname -- "$GENERATION_TMP/original/$rel")"
                cp --preserve=mode,timestamps -- "$current" "$GENERATION_TMP/original/$rel"
            fi
        elif [[ -e $current ]]; then
            die "Managed path is not a regular file: $current"
        else
            action=create
            chmod 0644 -- "$staged"
        fi

        mkdir -p -- "$(dirname -- "$GENERATION_TMP/actions/$rel")" "$(dirname -- "$GENERATION_TMP/installed/$rel")"
        printf '%s\n' "$action" > "$GENERATION_TMP/actions/$rel"
        cp --preserve=mode,timestamps -- "$staged" "$GENERATION_TMP/installed/$rel"
    done

    validate_qml_files \
        "$GENERATION_TMP/staged/modules/launcher/AppList.qml" \
        "$GENERATION_TMP/staged/modules/launcher/Content.qml" \
        "$GENERATION_TMP/staged/modules/launcher/services/WebSearch.qml"
}

commit_to_existing_local_copy() {
    local rel action target

    for rel in "${MANAGED_FILES[@]}"; do
        action=$(read_action "$GENERATION_TMP" "$rel") || return 1
        [[ $action != unchanged ]] || continue
        target=$LOCAL_ROOT/$rel
        if ! atomic_copy "$GENERATION_TMP/installed/$rel" "$target"; then
            error "Could not install $target; restoring files already changed."
            if ! rollback_generation "$GENERATION_TMP"; then
                local failed_backup=$GENERATION_TMP
                GENERATION_TMP=""
                warn "Automatic rollback was incomplete. Backups remain in $failed_backup"
            fi
            return 1
        fi
    done
}

commit_new_local_copy() {
    local rel action

    for rel in "${MANAGED_FILES[@]}"; do
        action=$(read_action "$GENERATION_TMP" "$rel") || return 1
        [[ $action != unchanged ]] || continue
        atomic_copy "$GENERATION_TMP/installed/$rel" "$INIT_DIR/$rel" || return 1
    done

    if ! mv -T -- "$INIT_DIR" "$LOCAL_ROOT"; then
        error "Could not activate the new local Caelestia copy at $LOCAL_ROOT"
        return 1
    fi
    INIT_DIR=""
}

finalise_generation() {
    local basename_part generation_id final_path
    basename_part=$(basename -- "$GENERATION_TMP")
    generation_id=${basename_part#.pending-}
    final_path=$STATE_ROOT/generations/$generation_id

    if ! printf '%s\n' installed > "$GENERATION_TMP/status"; then
        if ! rollback_generation "$GENERATION_TMP"; then
            local failed_backup=$GENERATION_TMP
            GENERATION_TMP=""
            warn "Automatic rollback was incomplete. Backups remain in $failed_backup"
        fi
        return 1
    fi
    if ! mv -T -- "$GENERATION_TMP" "$final_path"; then
        if ! rollback_generation "$GENERATION_TMP"; then
            local failed_backup=$GENERATION_TMP
            GENERATION_TMP=""
            warn "Automatic rollback was incomplete. Backups remain in $failed_backup"
        fi
        return 1
    fi
    GENERATION_TMP=""

    if ! atomic_text "$generation_id" "$STATE_ROOT/active"; then
        error 'Could not record the active addon generation; rolling back.'
        rollback_generation "$final_path" || warn "Automatic rollback was incomplete. Backups remain in $final_path"
        return 1
    fi
}

main() {
    local local_created=0 current_root rel action changed_count=0
    local -a previous_instances=()

    init_common_paths
    require_command uname
    require_command awk
    require_command sha256sum
    require_command cmp
    require_command cp
    require_command diff3
    require_command flock
    require_command mktemp
    require_command qs
    require_command xdg-open

    detect_versions
    discover_system_root
    verify_payload
    verify_supported_launcher
    check_quickshell_selection
    acquire_state_lock

    if show_existing_install; then
        return 0
    fi

    mapfile -t previous_instances < <(list_instances_for_managed_shell)

    if [[ -e $LOCAL_ROOT ]]; then
        assert_local_layout
        current_root=$LOCAL_ROOT
    else
        initialise_local_copy
        local_created=1
        current_root=$INIT_DIR
        [[ -f $current_root/shell.qml ]] || die 'The system Caelestia copy did not contain shell.qml.'
    fi

    prepare_generation "$current_root" "$local_created"

    for rel in "${MANAGED_FILES[@]}"; do
        action=$(read_action "$GENERATION_TMP" "$rel") || die "Invalid action metadata for $rel"
        [[ $action == unchanged ]] || ((changed_count += 1))
    done

    if ((local_created)); then
        commit_new_local_copy || die 'Installation failed before the local copy could be activated.'
    else
        commit_to_existing_local_copy || die 'Installation failed and the previous files were restored.'
    fi

    if ! finalise_generation; then
        die 'Installation state could not be recorded; previous launcher files were restored.'
    fi

    if ((changed_count > 0)); then
        restart_if_running "${previous_instances[@]}"
    else
        info 'The managed files were already identical; no shell restart was needed.'
    fi

    info "Installed Caelestia WebSearch $ADDON_VERSION in $LOCAL_ROOT"
    info 'Providers: google, youtube, wiki, gh, github, reddit, maps'
    info 'Queries without an application match fall back to Google.'
    print_backup_location
}

main "$@"
