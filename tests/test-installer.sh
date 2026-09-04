#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE="$ROOT/tests/fixtures/caelestia-2.4.0"
WORK_DIR=$(mktemp -d /tmp/caelestia-websearch-installer.XXXXXX)
ORIGINAL_PATH=$PATH
trap 'rm -rf -- "$WORK_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

make_fake_commands() {
    local fake_bin=$WORK_DIR/fake-bin
    mkdir -p -- "$fake_bin"
    printf '%s\n' '#!/usr/bin/env bash' 'if [[ ${1:-} == --version ]]; then printf "Quickshell test-double 0.3.1\\n"; fi' 'exit 0' > "$fake_bin/qs"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fake_bin/xdg-open"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'case "${1:-} ${2:-}" in' \
        '    "-Q caelestia-shell") printf "caelestia-shell 2.4.0-1\\n" ;;' \
        '    "-Q caelestia-cli") printf "caelestia-cli 1.1.2-1\\n" ;;' \
        '    *) exit 1 ;;' \
        'esac' > "$fake_bin/pacman"
    chmod 0755 "$fake_bin/qs" "$fake_bin/xdg-open" "$fake_bin/pacman"
    printf '%s\n' "$fake_bin"
}

copy_fixture() {
    local destination=$1
    mkdir -p -- "$destination"
    cp -R --preserve=mode,timestamps -- "$FIXTURE/." "$destination/"
}

run_install() {
    "$ROOT/install.sh" "$@"
}

run_uninstall() {
    "$ROOT/uninstall.sh" "$@"
}

fake_bin=$(make_fake_commands)
export PATH="$fake_bin:$ORIGINAL_PATH"
export CAELESTIA_WEBSEARCH_SKIP_RESTART=1

# Official v2.4.0 regression fixture: this exact Content.qml was rejected by v1.0.0.
(
    case_dir=$WORK_DIR/fresh
    system_root=$case_dir/system
    export HOME=$case_dir/home
    export XDG_CONFIG_HOME=$HOME/.config
    export XDG_STATE_HOME=$HOME/.local/state
    export CAELESTIA_WEBSEARCH_SYSTEM_DIR=$system_root
    copy_fixture "$system_root"
    mkdir -p -- "$HOME"

    run_install > "$case_dir/install-1.log" 2>&1
    local_root=$XDG_CONFIG_HOME/quickshell/caelestia
    state_root=$XDG_STATE_HOME/caelestia-websearch
    cmp -s "$ROOT/modules/launcher/AppList.qml" "$local_root/modules/launcher/AppList.qml" || fail 'fresh AppList install differs'
    cmp -s "$ROOT/modules/launcher/Content.qml" "$local_root/modules/launcher/Content.qml" || fail 'official Content regression fixture was not patched correctly'
    cmp -s "$ROOT/modules/launcher/services/WebSearch.qml" "$local_root/modules/launcher/services/WebSearch.qml" || fail 'WebSearch service differs'
    first_generation=$(<"$state_root/active")
    first_count=$(find "$state_root/generations" -mindepth 1 -maxdepth 1 -type d | wc -l)

    run_install > "$case_dir/install-2.log" 2>&1
    second_count=$(find "$state_root/generations" -mindepth 1 -maxdepth 1 -type d | wc -l)
    [[ $first_count -eq $second_count ]] || fail 'idempotent reinstall created another generation'
    [[ $(<"$state_root/active") == "$first_generation" ]] || fail 'idempotent reinstall changed the active generation'

    run_uninstall > "$case_dir/uninstall-1.log" 2>&1
    cmp -s "$system_root/modules/launcher/AppList.qml" "$local_root/modules/launcher/AppList.qml" || fail 'fresh uninstall did not restore AppList'
    cmp -s "$system_root/modules/launcher/Content.qml" "$local_root/modules/launcher/Content.qml" || fail 'fresh uninstall did not restore Content'
    [[ ! -e $local_root/modules/launcher/services/WebSearch.qml ]] || fail 'fresh uninstall kept package-created WebSearch.qml'
    [[ -f $local_root/shell.qml ]] || fail 'fresh uninstall removed the local shell'
    run_uninstall > "$case_dir/uninstall-2.log" 2>&1
)

# Same package version, byte-different but structurally compatible system Content.qml.
(
    case_dir=$WORK_DIR/compatible-variant
    system_root=$case_dir/system
    export HOME=$case_dir/home
    export XDG_CONFIG_HOME=$HOME/.config
    export XDG_STATE_HOME=$HOME/.local/state
    export CAELESTIA_WEBSEARCH_SYSTEM_DIR=$system_root
    copy_fixture "$system_root"
    sed '1a\// Compatible downstream customization.' "$system_root/modules/launcher/Content.qml" > "$case_dir/Content.tmp"
    mv -- "$case_dir/Content.tmp" "$system_root/modules/launcher/Content.qml"
    cp --preserve=mode,timestamps -- "$system_root/modules/launcher/Content.qml" "$case_dir/Content.before"
    mkdir -p -- "$HOME"

    run_install > "$case_dir/install.log" 2>&1
    local_content=$XDG_CONFIG_HOME/quickshell/caelestia/modules/launcher/Content.qml
    assert_contains "$local_content" '// Compatible downstream customization.'
    assert_contains "$local_content" 'typeof currentItem.modelData?.onClicked === "function"'
    run_uninstall > "$case_dir/uninstall.log" 2>&1
    cmp -s "$case_dir/Content.before" "$local_content" || fail 'compatible downstream Content customization was not restored'
)

# Existing local tree with unrelated customizations.
(
    case_dir=$WORK_DIR/custom-local
    system_root=$case_dir/system
    local_root=$case_dir/home/.config/quickshell/caelestia
    export HOME=$case_dir/home
    export XDG_CONFIG_HOME=$HOME/.config
    export XDG_STATE_HOME=$HOME/.local/state
    export CAELESTIA_WEBSEARCH_SYSTEM_DIR=$system_root
    copy_fixture "$system_root"
    copy_fixture "$local_root"
    sed '1a\// User AppList customization.' "$local_root/modules/launcher/AppList.qml" > "$case_dir/AppList.tmp"
    mv -- "$case_dir/AppList.tmp" "$local_root/modules/launcher/AppList.qml"
    sed '1a\// User Content customization.' "$local_root/modules/launcher/Content.qml" > "$case_dir/Content.tmp"
    mv -- "$case_dir/Content.tmp" "$local_root/modules/launcher/Content.qml"
    cp --preserve=mode,timestamps -- "$local_root/modules/launcher/AppList.qml" "$case_dir/AppList.before"
    cp --preserve=mode,timestamps -- "$local_root/modules/launcher/Content.qml" "$case_dir/Content.before"

    run_install > "$case_dir/install.log" 2>&1
    assert_contains "$local_root/modules/launcher/AppList.qml" '// User AppList customization.'
    assert_contains "$local_root/modules/launcher/Content.qml" '// User Content customization.'
    sed '2a\// Post-install user customization.' "$local_root/modules/launcher/Content.qml" > "$case_dir/Content.after-install.qml"
    mv -- "$case_dir/Content.after-install.qml" "$local_root/modules/launcher/Content.qml"
    sed '2a\// Post-install user customization.' "$case_dir/Content.before" > "$case_dir/Content.expected"
    run_uninstall > "$case_dir/uninstall.log" 2>&1
    cmp -s "$case_dir/AppList.before" "$local_root/modules/launcher/AppList.qml" || fail 'custom local AppList was not restored'
    cmp -s "$case_dir/Content.expected" "$local_root/modules/launcher/Content.qml" || fail 'custom local Content and later edit were not preserved'
)

# A real merge conflict must stop before changing the local launcher.
(
    case_dir=$WORK_DIR/merge-conflict
    system_root=$case_dir/system
    local_root=$case_dir/home/.config/quickshell/caelestia
    export HOME=$case_dir/home
    export XDG_CONFIG_HOME=$HOME/.config
    export XDG_STATE_HOME=$HOME/.local/state
    export CAELESTIA_WEBSEARCH_SYSTEM_DIR=$system_root
    copy_fixture "$system_root"
    copy_fixture "$local_root"
    sed '/        return "apps";/i\        if (text === "custom-mode")\n            return "actions";\n' "$local_root/modules/launcher/AppList.qml" > "$case_dir/AppList.tmp"
    mv -- "$case_dir/AppList.tmp" "$local_root/modules/launcher/AppList.qml"
    app_before=$(sha256sum "$local_root/modules/launcher/AppList.qml" | awk '{print $1}')
    content_before=$(sha256sum "$local_root/modules/launcher/Content.qml" | awk '{print $1}')

    if run_install > "$case_dir/install.log" 2>&1; then
        fail 'deliberate three-way merge conflict was accepted'
    fi
    [[ $(sha256sum "$local_root/modules/launcher/AppList.qml" | awk '{print $1}') == "$app_before" ]] || fail 'AppList changed after merge refusal'
    [[ $(sha256sum "$local_root/modules/launcher/Content.qml" | awk '{print $1}') == "$content_before" ]] || fail 'Content changed after merge refusal'
    [[ ! -e $local_root/modules/launcher/services/WebSearch.qml ]] || fail 'WebSearch was created after merge refusal'
    [[ ! -e $XDG_STATE_HOME/caelestia-websearch/active ]] || fail 'refused merge was marked installed'
    assert_contains "$case_dir/install.log" 'conflicts with existing custom changes'
)

# A cross-file partial integration is incompatible and must not create state.
(
    case_dir=$WORK_DIR/partial-local
    system_root=$case_dir/system
    local_root=$case_dir/home/.config/quickshell/caelestia
    export HOME=$case_dir/home
    export XDG_CONFIG_HOME=$HOME/.config
    export XDG_STATE_HOME=$HOME/.local/state
    export CAELESTIA_WEBSEARCH_SYSTEM_DIR=$system_root
    copy_fixture "$system_root"
    copy_fixture "$local_root"
    python3 "$ROOT/scripts/patch_launcher.py" \
        --kind app-list \
        --input "$local_root/modules/launcher/AppList.qml" \
        --output "$case_dir/AppList.patched.qml" >/dev/null
    mv -- "$case_dir/AppList.patched.qml" "$local_root/modules/launcher/AppList.qml"
    app_before=$(sha256sum "$local_root/modules/launcher/AppList.qml" | awk '{print $1}')
    content_before=$(sha256sum "$local_root/modules/launcher/Content.qml" | awk '{print $1}')

    if run_install > "$case_dir/install.log" 2>&1; then
        fail 'partial local WebSearch integration was accepted'
    fi
    [[ $(sha256sum "$local_root/modules/launcher/AppList.qml" | awk '{print $1}') == "$app_before" ]] || fail 'partial local AppList changed after refusal'
    [[ $(sha256sum "$local_root/modules/launcher/Content.qml" | awk '{print $1}') == "$content_before" ]] || fail 'partial local Content changed after refusal'
    [[ ! -e $XDG_STATE_HOME/caelestia-websearch ]] || fail 'addon state was created after partial local refusal'
    assert_contains "$case_dir/install.log" 'Partial WebSearch integration in Local launcher files'
)

# Missing required dispatch structure must be rejected before any user-local write.
(
    case_dir=$WORK_DIR/incompatible
    system_root=$case_dir/system
    export HOME=$case_dir/home
    export XDG_CONFIG_HOME=$HOME/.config
    export XDG_STATE_HOME=$HOME/.local/state
    export CAELESTIA_WEBSEARCH_SYSTEM_DIR=$system_root
    copy_fixture "$system_root"
    sed 's/currentItem\.modelData\.onClicked(list\.currentList);/currentItem.modelData.runCustomAction();/' "$system_root/modules/launcher/Content.qml" > "$case_dir/Content.tmp"
    mv -- "$case_dir/Content.tmp" "$system_root/modules/launcher/Content.qml"
    system_before=$(sha256sum "$system_root/modules/launcher/Content.qml" | awk '{print $1}')
    mkdir -p -- "$HOME"

    if run_install > "$case_dir/install.log" 2>&1; then
        fail 'incompatible system Content.qml was accepted'
    fi
    [[ $(sha256sum "$system_root/modules/launcher/Content.qml" | awk '{print $1}') == "$system_before" ]] || fail 'system file changed after incompatibility refusal'
    [[ ! -e $XDG_CONFIG_HOME/quickshell/caelestia ]] || fail 'local config was created after incompatibility refusal'
    [[ ! -e $XDG_STATE_HOME/caelestia-websearch ]] || fail 'addon state was created after incompatibility refusal'
    assert_contains "$case_dir/install.log" 'Detected caelestia-shell version: 2.4.0-1'
    assert_contains "$case_dir/install.log" 'Incompatible launcher structure in modules/launcher/Content.qml'
    assert_contains "$case_dir/install.log" 'existing action dispatch'
)

printf 'PASS: fresh, regression, reinstall, uninstall, customization, conflict, partial-state, and refusal tests\n'
