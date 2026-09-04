#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK_DIR=$(mktemp -d /tmp/caelestia-websearch-qml.XXXXXX)
trap 'rm -rf -- "$WORK_DIR"' EXIT

if ! command -v qs >/dev/null 2>&1; then
    printf 'SKIP: Quickshell is unavailable; WebSearch runtime test not run\n'
    exit 0
fi
command -v timeout >/dev/null 2>&1 || { printf 'SKIP: timeout is unavailable; WebSearch runtime test not run\n'; exit 0; }

mkdir -p -- "$WORK_DIR/config/modules/launcher/services" "$WORK_DIR/runtime" "$WORK_DIR/bin"
chmod 0700 "$WORK_DIR/runtime"
cp -- "$ROOT/tests/qml/WebSearchTest.qml" "$WORK_DIR/config/shell.qml"
cp -- "$ROOT/modules/launcher/services/WebSearch.qml" "$WORK_DIR/config/modules/launcher/services/WebSearch.qml"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''%s\n'\'' "$@" > "$CAELESTIA_WEBSEARCH_XDG_LOG"' \
    > "$WORK_DIR/bin/xdg-open"
chmod 0755 "$WORK_DIR/bin/xdg-open"

export CAELESTIA_WEBSEARCH_XDG_LOG="$WORK_DIR/xdg-open.log"
export PATH="$WORK_DIR/bin:$PATH"
export XDG_RUNTIME_DIR="$WORK_DIR/runtime"
export QT_QPA_PLATFORM=offscreen

set +e
timeout 5 qs --path "$WORK_DIR/config" --no-color > "$WORK_DIR/quickshell.log" 2>&1
qs_status=$?
set -e
if [[ $qs_status -ne 0 && $qs_status -ne 124 ]]; then
    sed -n '1,200p' "$WORK_DIR/quickshell.log" >&2
    printf 'FAIL: WebSearch Quickshell harness failed\n' >&2
    exit 1
fi

if grep -Fq 'WEBSEARCH_TEST_FAIL' "$WORK_DIR/quickshell.log" || ! grep -Fq 'WEBSEARCH_TEST_PASS' "$WORK_DIR/quickshell.log"; then
    sed -n '1,200p' "$WORK_DIR/quickshell.log" >&2
    printf 'FAIL: WebSearch runtime assertions failed\n' >&2
    exit 1
fi

expected='https://www.google.com/search?q=comment%20dessiner%20un%20lapin'
for _ in {1..20}; do
    [[ -f $CAELESTIA_WEBSEARCH_XDG_LOG ]] && break
    sleep 0.05
done
[[ -f $CAELESTIA_WEBSEARCH_XDG_LOG ]] || { printf 'FAIL: xdg-open was not executed\n' >&2; exit 1; }
[[ $(<"$CAELESTIA_WEBSEARCH_XDG_LOG") == "$expected" ]] || { printf 'FAIL: xdg-open received an unexpected URL\n' >&2; exit 1; }

printf 'PASS: WebSearch parsing, encoding, fallback, launcher close, and xdg-open tests\n'
