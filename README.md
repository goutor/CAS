# CAS

Codex Account Switcher.

## Repository Layout

- [`MacOS`](MacOS) - macOS app source and build scripts.
- [`Windows`](Windows) - Windows app source, scripts, and Windows build output.

There is only one Windows folder by design (`Windows`). Standalone release archives/binaries should be published via GitHub Releases, not as extra top-level directories.

Local account profiles are stored outside the repository and are intentionally ignored by git.
