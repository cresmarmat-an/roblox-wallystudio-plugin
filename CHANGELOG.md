# Changelog

All notable changes to Wally Studio are recorded here.

GitHub Releases are built automatically when a version tag such as `v1.0.0` is pushed. Before tagging a release, update `Constants.PLUGIN_VERSION` in `src/Modules/Config/Constants.lua` and add a matching version section below. The release workflow can also be run manually with an existing version tag.

## [1.0.0] - 2026-10-29

### Added

- Browse and search the Wally registry directly inside Roblox Studio.
- Select package versions and install their dependencies with a dependency preview.
- Manage shared, server, and development packages in their respective package folders.
- Check for updates, update compatible packages, remove packages, and clean up unused dependencies.
- Import and export `wally.toml` manifest text, including storing manifests in the place.
- Follow Studio's light and dark themes, save plugin preferences, and configure the registry URL.
- Undo support for package installation, removal, and cleanup.
- A package-box icon featuring the Wally and Studio emblems.
- Automated GitHub Releases containing `WallyStudio.rbxm`, `WallyStudio.rbxmx`, and `SHA256SUMS`.
