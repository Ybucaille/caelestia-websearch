#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

"$ROOT/tests/test-compatibility.sh"
"$ROOT/tests/test-websearch.sh"
"$ROOT/tests/test-installer.sh"
