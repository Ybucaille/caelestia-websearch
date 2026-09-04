# Caelestia WebSearch

Caelestia WebSearch is an unofficial community addon that adds web search actions to the existing [Caelestia](https://github.com/caelestia-dots/shell) launcher. It keeps normal application launching intact and opens searches with the system browser through `xdg-open`.

## Features

- Google, YouTube, French Wikipedia, GitHub, Reddit, and Google Maps providers
- normal application launching remains unchanged
- automatic Google fallback when no application matches
- URLs encoded with `encodeURIComponent()`, including spaces, accents, Unicode, and special characters
- system default browser through `xdg-open`; no browser is hardcoded
- user-local installation with backups and clean uninstall support

## Usage

Open your existing Caelestia launcher shortcut and type a query:

```text
google linux kernel
youtube lofi music
wiki Arch Linux
github caelestia
gh caelestia
reddit archlinux
maps Paris
firefox
```

`firefox` remains a normal application search. If no application matches and no explicit provider is present, the entire query is offered as a Google search.

Provider prefixes require a non-empty query. Typing `google` by itself is therefore not treated as an explicit empty provider search: application matching still runs first, followed by the normal fallback for the word `google` when nothing matches.

## Installation

```bash
git clone https://github.com/Ybucaille/caelestia-websearch.git
cd caelestia-websearch
./install.sh
```

Running `bash install.sh` is also supported. The installer:

1. detects Linux, Caelestia, Quickshell, `xdg-open`, and the launcher structure;
2. creates `~/.config/quickshell/caelestia` from the installed system shell only when no local copy exists;
3. three-way merges the two patched launcher files and installs the WebSearch service, preserving non-conflicting local customizations;
4. stores package-specific backups under `${XDG_STATE_HOME:-$HOME/.local/state}/caelestia-websearch`;
5. restarts only a currently running Caelestia shell, using its exact Quickshell instance id.

The system shell under `/etc/xdg/quickshell/caelestia` is read as a merge base and is never modified.

## Uninstall

From the cloned repository:

```bash
./uninstall.sh
```

The uninstaller restores the recorded pre-addon versions, uses a reverse three-way merge to preserve later non-conflicting edits, and removes a package-created `WebSearch.qml` only when it is still unchanged. It never removes the complete local Caelestia directory.

Running the uninstaller when the addon is not installed is safe.

## Requirements

- Linux
- Caelestia Shell and its launcher
- Quickshell (`qs`)
- `xdg-open`
- standard command-line tools: Bash, GNU coreutils, `diff3`, and `flock`

Arch Linux with the `caelestia-shell` package is the primary supported environment.

## Compatibility

This release targets `caelestia-shell 2.4.0-1`. The installer displays the package version when `pacman` can determine it. If the version is unavailable or differs, installation is allowed only when the two patched upstream launcher files match the known 2.4.0 structure; otherwise it stops before modifying the user configuration.

Because Caelestia's launcher internals can change, update this addon before using it with a new incompatible Caelestia release.

Quickshell's deprecated `manifest.conf` mechanism and a top-level `~/.config/quickshell/shell.qml` can override named configuration discovery. The installer detects these cases and stops without changing them instead of installing an addon that the normal `caelestia shell` command would not load.

## How it works

The addon keeps Caelestia's launcher and delegates in place. It adds a small singleton service, `WebSearch.qml`, and minimal integrations in `AppList.qml` and `Content.qml`.

The evaluation order is:

1. existing Caelestia commands;
2. an explicit web provider;
3. matching applications;
4. Google fallback when no application matches.

Web actions close the launcher and execute `xdg-open` with the encoded URL as a separate argument.

## Safety and configuration

- does not write to `/etc/xdg/quickshell/caelestia`
- does not edit Hyprland configuration or keybinds
- does not change the user's launcher shortcut
- does not hardcode a username, home directory, or browser
- installs only under the user's XDG config and state directories
- preserves unrelated files in an existing local Caelestia configuration
- aborts before writing if a three-way merge has conflicts
- is idempotent: a second unchanged install creates no replacement or backup

## Relationship to Caelestia

This is an independent community addon and is not affiliated with the official Caelestia project. `AppList.qml` and `Content.qml` are modified files derived from Caelestia Shell 2.4.0; credit for the original shell belongs to the [Caelestia contributors](https://github.com/caelestia-dots/shell).

## License

This project is licensed under the [GNU General Public License v3.0 only](LICENSE), matching the `GPL-3.0-only` license of the modified Caelestia Shell files it redistributes.
