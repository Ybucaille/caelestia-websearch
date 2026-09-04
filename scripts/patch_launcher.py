#!/usr/bin/env python3
"""Apply the minimal Caelestia WebSearch launcher integration.

The transformer intentionally recognises only the structural anchors used by
the addon. It preserves every unrelated byte in compatible launcher variants
and rejects partial or ambiguous integrations.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


class IncompatibleStructure(ValueError):
    """Raised when a launcher file cannot be patched unambiguously."""


CONTENT_ORIGINAL = re.compile(
    r'^(?P<indent>[ \t]*)\} else if \(text\.startsWith\(GlobalConfig\.launcher\.actionPrefix\)\) \{$',
    re.MULTILINE,
)
CONTENT_PATCHED = re.compile(
    r'^(?P<indent>[ \t]*)\} else if \(text\.startsWith\(GlobalConfig\.launcher\.actionPrefix\) '
    r'\|\| typeof currentItem\.modelData\?\.onClicked === "function"\) \{$',
    re.MULTILINE,
)

APP_STATE_INSERT = '''        // Explicit web provider: "google foo", "youtube foo", etc.
        if (WebSearch.parse(text))
            return "web";

        // Normal application search first.
        // If nothing matches, offer Google as a fallback.
        if (text.trim() && Apps.search(text).length === 0)
            return "web";

'''

APP_RESULTS_INSERT = '''        case "web": {
            const result = WebSearch.parse(text) ?? WebSearch.fallback(text);
            return result ? [result] : [];
        }
'''

VARIANT_STATE = '''        State {
            name: "variant"

            PropertyChanges {
                root.delegate: variantItem
            }
        }'''

WEB_STATE = '''        State {
            name: "web"

            PropertyChanges {
                root.delegate: actionItem
            }
        }'''


def require_exact_count(text: str, token: str, count: int, label: str) -> None:
    actual = text.count(token)
    if actual != count:
        raise IncompatibleStructure(
            f"expected {count} occurrence(s) of {label}, found {actual}"
        )


def unique_region(text: str, start_token: str, end_token: str, label: str) -> tuple[int, int]:
    require_exact_count(text, start_token, 1, f"{label} start")
    require_exact_count(text, end_token, 1, f"{label} end")
    start = text.index(start_token)
    end = text.index(end_token, start)
    if end <= start:
        raise IncompatibleStructure(f"invalid {label} boundaries")
    return start, end


def content_status(text: str) -> str:
    required = {
        "the SearchBar acceptance handler": "onAccepted: {",
        "the selected-item lookup": "const currentItem = list.currentList?.currentItem;",
        "the existing action dispatch": "currentItem.modelData.onClicked(list.currentList);",
        "normal application launch": "Apps.launch(currentItem.modelData);",
        "calculator command dispatch": "text.startsWith(`${GlobalConfig.launcher.actionPrefix}calc `)",
        "launcher services import": "import qs.modules.launcher.services",
    }
    for label, token in required.items():
        require_exact_count(text, token, 1, label)

    original_count = len(CONTENT_ORIGINAL.findall(text))
    patched_count = len(CONTENT_PATCHED.findall(text))

    if original_count == 1 and patched_count == 0:
        return "compatible-unpatched"
    if original_count == 0 and patched_count == 1:
        return "compatible-patched"

    raise IncompatibleStructure(
        "expected exactly one original or WebSearch-enabled action condition "
        f"(original={original_count}, patched={patched_count})"
    )


def patch_content(text: str) -> tuple[str, str]:
    status = content_status(text)
    if status == "compatible-patched":
        return text, status

    def replacement(match: re.Match[str]) -> str:
        return (
            f'{match.group("indent")}}} else if '
            '(text.startsWith(GlobalConfig.launcher.actionPrefix) '
            '|| typeof currentItem.modelData?.onClicked === "function") {'
        )

    patched, substitutions = CONTENT_ORIGINAL.subn(replacement, text)
    if substitutions != 1:
        raise IncompatibleStructure(
            f"could not apply the action condition exactly once (applied={substitutions})"
        )
    content_status(patched)
    return patched, status


def app_list_status(text: str) -> str:
    required = {
        "stateForText()": "function stateForText(text: string): string {",
        "resultsForText()": "function resultsForText(text: string): var {",
        "application search": "return Apps.search(text);",
        "variant result": 'case "variant":',
        "variant state": 'name: "variant"',
        "launcher services import": "import qs.modules.launcher.services",
    }
    for label, token in required.items():
        require_exact_count(text, token, 1, label)

    marker_counts = {
        "provider parser": text.count("if (WebSearch.parse(text))"),
        "web result case": text.count('case "web": {'),
        "web delegate state": text.count('name: "web"'),
    }

    if all(count == 0 for count in marker_counts.values()):
        return "compatible-unpatched"

    if all(count == 1 for count in marker_counts.values()):
        require_exact_count(text, "WebSearch.fallback(text)", 1, "Google fallback")
        require_exact_count(text, "return result ? [result] : [];", 1, "web result return")
        return "compatible-patched"

    details = ", ".join(f"{name}={count}" for name, count in marker_counts.items())
    raise IncompatibleStructure(f"partial or ambiguous WebSearch integration ({details})")


def patch_app_list(text: str) -> tuple[str, str]:
    status = app_list_status(text)
    if status == "compatible-patched":
        return text, status

    state_start, state_end = unique_region(
        text,
        "    function stateForText(text: string): string {",
        "\n    function resultsForText(text: string): var {",
        "stateForText()",
    )
    state_region = text[state_start:state_end]
    return_apps = '        return "apps";'
    require_exact_count(state_region, return_apps, 1, 'stateForText() app return')
    state_region = state_region.replace(return_apps, APP_STATE_INSERT + return_apps)
    text = text[:state_start] + state_region + text[state_end:]

    results_start, results_end = unique_region(
        text,
        "    function resultsForText(text: string): var {",
        "\n    model: ScriptModel {",
        "resultsForText()",
    )
    results_region = text[results_start:results_end]
    default_case = "        default:\n"
    require_exact_count(results_region, default_case, 1, "resultsForText() default case")
    results_region = results_region.replace(default_case, APP_RESULTS_INSERT + default_case)
    text = text[:results_start] + results_region + text[results_end:]

    states_start, states_end = unique_region(
        text,
        "    states: [",
        "\n\n    transitions: Transition {",
        "launcher states",
    )
    states_region = text[states_start:states_end]
    require_exact_count(states_region, VARIANT_STATE, 1, "canonical variant state")
    states_region = states_region.replace(VARIANT_STATE, VARIANT_STATE + ",\n" + WEB_STATE)
    text = text[:states_start] + states_region + text[states_end:]

    app_list_status(text)
    return text, status


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate and patch compatible Caelestia launcher QML files."
    )
    parser.add_argument("--kind", choices=("app-list", "content"), required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check == (args.output is not None):
        parser.error("use exactly one of --check or --output")
    return args


def main() -> int:
    args = parse_args()
    try:
        source = args.input.read_text(encoding="utf-8")
        if args.kind == "app-list":
            patched, status = patch_app_list(source)
        else:
            patched, status = patch_content(source)
    except (OSError, UnicodeError) as error:
        print(f"cannot read {args.input}: {error}", file=sys.stderr)
        return 2
    except IncompatibleStructure as error:
        print(f"{args.input.name}: {error}", file=sys.stderr)
        return 1

    if args.check:
        print(status)
        return 0

    try:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(patched, encoding="utf-8")
    except (OSError, UnicodeError) as error:
        print(f"cannot write {args.output}: {error}", file=sys.stderr)
        return 2

    print(status)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
