#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

WORK_DIR=""
ATTEMPT_DIR=""

cleanup() {
    [[ -z $WORK_DIR || ! -d $WORK_DIR ]] || rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

restore_uninstall_attempt() {
    local rel snapshot marker target

    for rel in "${MANAGED_FILES[@]}"; do
        snapshot=$ATTEMPT_DIR/files/$rel
        marker=$ATTEMPT_DIR/missing/$rel
        target=$LOCAL_ROOT/$rel

        if [[ -f $snapshot ]]; then
            atomic_copy "$snapshot" "$target" || return 1
        elif [[ -f $marker ]]; then
            rm -f -- "$target" || return 1
        fi
    done
}

stage_uninstall() {
    local generation=$1
    local rel action current installed original staged operation merge_code

    WORK_DIR=$(mktemp -d "$STATE_ROOT/.uninstall.XXXXXX")
    mkdir -p -- "$WORK_DIR/staged" "$WORK_DIR/operations"

    for rel in "${MANAGED_FILES[@]}"; do
        action=$(read_action "$generation" "$rel") || die "Invalid backup action for $rel"
        current=$LOCAL_ROOT/$rel
        installed=$generation/installed/$rel
        original=$generation/original/$rel
        staged=$WORK_DIR/staged/$rel
        operation=leave

        case "$action" in
            replace)
                [[ -f $installed && -f $original ]] || die "Incomplete backup for $rel"
                [[ ! -L $current ]] || die "Managed file became a symlink; refusing to overwrite it: $current"
                mkdir -p -- "$(dirname -- "$staged")"

                if [[ ! -e $current ]]; then
                    cp --preserve=mode,timestamps -- "$original" "$staged"
                elif [[ -f $current ]] && cmp -s -- "$current" "$installed"; then
                    cp --preserve=mode,timestamps -- "$original" "$staged"
                elif [[ -f $current ]]; then
                    if diff3 --merge --show-overlap \
                        --label current --label addon-installed --label pre-addon \
                        "$current" "$installed" "$original" > "$staged"; then
                        :
                    else
                        merge_code=$?
                        if ((merge_code == 1)); then
                            error "Cannot safely remove addon changes from $rel because later user edits conflict. No files were modified."
                        else
                            error "Could not prepare restoration for $rel (diff3 exit $merge_code). No files were modified."
                        fi
                        exit 1
                    fi
                    chmod --reference="$current" "$staged" 2>/dev/null || true
                else
                    die "Managed path is not a regular file: $current"
                fi
                operation=replace
                ;;
            create)
                if [[ ! -e $current ]]; then
                    operation=leave
                elif [[ -L $current ]]; then
                    warn "Keeping user-modified symlink created at $current"
                    operation=leave
                elif [[ -f $current ]] && cmp -s -- "$current" "$installed"; then
                    operation=delete
                else
                    warn "Keeping user-modified file $current; the restored launcher will no longer reference it."
                    operation=leave
                fi
                ;;
            unchanged)
                operation=leave
                ;;
        esac

        mkdir -p -- "$(dirname -- "$WORK_DIR/operations/$rel")"
        printf '%s\n' "$operation" > "$WORK_DIR/operations/$rel"
    done
}

validate_staged_restoration() {
    local rel operation
    local -a files=()

    for rel in "${MANAGED_FILES[@]}"; do
        operation=$(<"$WORK_DIR/operations/$rel")
        [[ $operation == replace ]] && files+=("$WORK_DIR/staged/$rel")
    done

    ((${#files[@]} == 0)) || validate_qml_files "${files[@]}"
}

snapshot_before_uninstall() {
    local generation=$1
    local stamp rel current

    stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
    ATTEMPT_DIR=$generation/uninstalls/$stamp
    mkdir -p -- "$ATTEMPT_DIR/files" "$ATTEMPT_DIR/missing"

    for rel in "${MANAGED_FILES[@]}"; do
        current=$LOCAL_ROOT/$rel
        if [[ -f $current && ! -L $current ]]; then
            mkdir -p -- "$(dirname -- "$ATTEMPT_DIR/files/$rel")"
            cp --preserve=mode,timestamps -- "$current" "$ATTEMPT_DIR/files/$rel"
        elif [[ ! -e $current ]]; then
            mkdir -p -- "$(dirname -- "$ATTEMPT_DIR/missing/$rel")"
            : > "$ATTEMPT_DIR/missing/$rel"
        fi
    done
}

commit_uninstall() {
    local rel operation target

    for rel in "${MANAGED_FILES[@]}"; do
        [[ -f $WORK_DIR/operations/$rel ]] || return 1
        IFS= read -r operation < "$WORK_DIR/operations/$rel" || return 1
        target=$LOCAL_ROOT/$rel

        case "$operation" in
            replace)
                if ! atomic_copy "$WORK_DIR/staged/$rel" "$target"; then
                    error "Could not restore $target; rolling back the uninstall."
                    restore_uninstall_attempt || warn "Automatic rollback was incomplete. Snapshot: $ATTEMPT_DIR"
                    return 1
                fi
                ;;
            delete)
                if ! rm -f -- "$target"; then
                    error "Could not remove $target; rolling back the uninstall."
                    restore_uninstall_attempt || warn "Automatic rollback was incomplete. Snapshot: $ATTEMPT_DIR"
                    return 1
                fi
                ;;
            leave)
                ;;
            *)
                die "Invalid uninstall operation for $rel"
                ;;
        esac
    done
}

main() {
    local generation_id generation stored_root
    local -a previous_instances=()

    init_common_paths

    if [[ ! -f $STATE_ROOT/active ]]; then
        info 'Caelestia WebSearch is not installed by this addon; nothing to do.'
        return 0
    fi

    require_command awk
    require_command cmp
    require_command cp
    require_command diff3
    require_command flock
    require_command mktemp
    require_command sha256sum
    acquire_state_lock

    IFS= read -r generation_id < "$STATE_ROOT/active"
    [[ $generation_id =~ ^[A-Za-z0-9._-]+$ ]] || die 'The addon state contains an invalid active generation id.'
    generation=$STATE_ROOT/generations/$generation_id
    [[ -d $generation && -f $generation/status ]] || die 'The active addon backup is incomplete.'
    [[ $(<"$generation/status") == installed ]] || die 'The addon state is not marked as installed.'
    [[ -f $generation/metadata/local-root ]] || die 'The addon metadata is incomplete.'
    stored_root=$(<"$generation/metadata/local-root")
    [[ $stored_root == "$LOCAL_ROOT" ]] || die "The addon was installed for a different local config: $stored_root"
    [[ -d $LOCAL_ROOT ]] || die "The local Caelestia directory no longer exists: $LOCAL_ROOT"

    if [[ -n ${CAELESTIA_WEBSEARCH_SYSTEM_DIR:-} ]]; then
        SYSTEM_ROOT=$(normalise_path "$CAELESTIA_WEBSEARCH_SYSTEM_DIR")
    elif [[ -d /etc/xdg/quickshell/caelestia ]]; then
        SYSTEM_ROOT=$(realpath -e -- /etc/xdg/quickshell/caelestia)
    fi

    mapfile -t previous_instances < <(list_instances_for_managed_shell)
    stage_uninstall "$generation"
    validate_staged_restoration
    snapshot_before_uninstall "$generation"
    commit_uninstall || die 'Uninstall failed; the pre-uninstall snapshot was restored.'

    if ! atomic_text uninstalled "$generation/status"; then
        restore_uninstall_attempt || warn "Automatic rollback was incomplete. Snapshot: $ATTEMPT_DIR"
        die 'Could not update addon state; the uninstall was rolled back.'
    fi
    if ! rm -f -- "$STATE_ROOT/active"; then
        atomic_text installed "$generation/status" || true
        restore_uninstall_attempt || warn "Automatic rollback was incomplete. Snapshot: $ATTEMPT_DIR"
        die 'Could not clear addon state; the uninstall was rolled back.'
    fi

    restart_if_running "${previous_instances[@]}"

    info 'Caelestia WebSearch was uninstalled.'
    info "Only the three managed launcher files were restored or removed; $LOCAL_ROOT was kept."
    info "Historical backups remain in $generation"
}

main "$@"
