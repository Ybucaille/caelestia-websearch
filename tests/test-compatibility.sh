#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PATCHER="$ROOT/scripts/patch_launcher.py"
FIXTURE="$ROOT/tests/fixtures/caelestia-2.4.0/modules/launcher"
WORK_DIR=$(mktemp -d /tmp/caelestia-websearch-compat.XXXXXX)
trap 'rm -rf -- "$WORK_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

app_fixture=$FIXTURE/AppList.qml
content_fixture=$FIXTURE/Content.qml

[[ $(sha256sum "$app_fixture" | awk '{print $1}') == 11b85781e9a35e372f0266658419bea5d2cb297006208f90c6a0a27d57b42b9e ]] || fail 'unexpected upstream AppList fixture'
[[ $(sha256sum "$content_fixture" | awk '{print $1}') == 7bd0e6ab9c64a75c3796ad37e98672801ffb2dd36ae7b4e83e06944c934aa53f ]] || fail 'unexpected upstream Content fixture'
[[ $(sha256sum "$content_fixture" | awk '{print $1}') != 45c2df8d52bc3a8c301d27a75685b1f3813a2db4b01204dc8bdd84c574e57182 ]] || fail 'regression fixture unexpectedly matches the old restrictive digest'

python3 "$PATCHER" --kind app-list --input "$app_fixture" --output "$WORK_DIR/AppList.qml" >/dev/null
python3 "$PATCHER" --kind content --input "$content_fixture" --output "$WORK_DIR/Content.qml" >/dev/null
cmp -s "$WORK_DIR/AppList.qml" "$ROOT/modules/launcher/AppList.qml" || fail 'canonical AppList payload differs from structural patch output'
cmp -s "$WORK_DIR/Content.qml" "$ROOT/modules/launcher/Content.qml" || fail 'canonical Content payload differs from structural patch output'

action_line=$(grep -nF '            return "actions";' "$WORK_DIR/AppList.qml" | cut -d: -f1)
provider_line=$(grep -nF '        if (WebSearch.parse(text))' "$WORK_DIR/AppList.qml" | cut -d: -f1)
fallback_line=$(grep -nF '        if (text.trim() && Apps.search(text).length === 0)' "$WORK_DIR/AppList.qml" | cut -d: -f1)
apps_line=$(grep -nF '        return "apps";' "$WORK_DIR/AppList.qml" | cut -d: -f1)
((action_line < provider_line && provider_line < fallback_line && fallback_line < apps_line)) || fail 'launcher priority order changed'

python3 "$PATCHER" --kind app-list --input "$WORK_DIR/AppList.qml" --output "$WORK_DIR/AppList-twice.qml" >/dev/null
python3 "$PATCHER" --kind content --input "$WORK_DIR/Content.qml" --output "$WORK_DIR/Content-twice.qml" >/dev/null
cmp -s "$WORK_DIR/AppList.qml" "$WORK_DIR/AppList-twice.qml" || fail 'AppList patch is not idempotent'
cmp -s "$WORK_DIR/Content.qml" "$WORK_DIR/Content-twice.qml" || fail 'Content patch is not idempotent'

sed '1a\// Compatible distributor customization outside WebSearch.' "$content_fixture" > "$WORK_DIR/Content-compatible.qml"
python3 "$PATCHER" --kind content --input "$WORK_DIR/Content-compatible.qml" --output "$WORK_DIR/Content-compatible-patched.qml" >/dev/null
assert_contains "$WORK_DIR/Content-compatible-patched.qml" '// Compatible distributor customization outside WebSearch.'
assert_contains "$WORK_DIR/Content-compatible-patched.qml" 'typeof currentItem.modelData?.onClicked === "function"'

sed 's/currentItem\.modelData\.onClicked(list\.currentList);/currentItem.modelData.runCustomAction();/' "$content_fixture" > "$WORK_DIR/Content-incompatible.qml"
incompatible_before=$(sha256sum "$WORK_DIR/Content-incompatible.qml" | awk '{print $1}')
if python3 "$PATCHER" --kind content --input "$WORK_DIR/Content-incompatible.qml" --output "$WORK_DIR/should-not-exist.qml" >"$WORK_DIR/incompatible.log" 2>&1; then
    fail 'an incompatible Content.qml was accepted'
fi
[[ $(sha256sum "$WORK_DIR/Content-incompatible.qml" | awk '{print $1}') == "$incompatible_before" ]] || fail 'incompatible input was modified'
[[ ! -e $WORK_DIR/should-not-exist.qml ]] || fail 'output was created for an incompatible Content.qml'
assert_contains "$WORK_DIR/incompatible.log" 'existing action dispatch'

sed '/        return "apps";/i\        if (WebSearch.parse(text))\n            return "web";' "$app_fixture" > "$WORK_DIR/AppList-partial.qml"
if python3 "$PATCHER" --kind app-list --input "$WORK_DIR/AppList-partial.qml" --check >"$WORK_DIR/partial.log" 2>&1; then
    fail 'a partial AppList WebSearch integration was accepted'
fi
assert_contains "$WORK_DIR/partial.log" 'partial or ambiguous WebSearch integration'

if grep -Eq '"yt"[[:space:]]*:' "$ROOT/modules/launcher/services/WebSearch.qml"; then
    fail 'the unsupported yt provider was reintroduced'
fi
assert_contains "$ROOT/modules/launcher/services/WebSearch.qml" '"youtube": {'

printf 'PASS: structural compatibility, rejection, idempotence, and provider tests\n'
