# Changelog

All notable changes to Caelestia WebSearch are documented in this file.

## [1.1.0] - 2026-09-04

### Fixed

- Replaced whole-file launcher hashes with validation of the structural anchors
  required by the addon.
- Built the three-way merge input from the detected system launcher files so
  compatible downstream and local customizations are preserved.
- Accept the official Caelestia Shell v2.4.0 `Content.qml`, which version 1.0.0
  incorrectly rejected.

### Added

- Regression fixtures for the official Caelestia Shell v2.4.0 launcher.
- Tests for provider parsing and encoding, compatible byte-different files,
  fresh install, reinstall, uninstall, custom local changes, merge conflicts,
  partial integrations, and incompatibility refusals.

## [1.0.0] - 2026-09-04

- Initial public release with Google fallback and explicit Google, YouTube,
  French Wikipedia, GitHub, Reddit, and Google Maps providers.
