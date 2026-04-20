# BOG Tool v1.2.5 Release Notes

Release date: _TBD (after archive / notarization)_

## Highlights

- Repository layout cleanup: documentation under `docs/`, helper scripts under `scripts/`, reference assets under `tools/`.
- GATT source workbooks consolidated under `BOG_TOOL/Config/GattServicesSources/` (still synced to `GattServices.json` for the app).
- Removed bundled firmware binaries from the repo root and simplified local firmware handling (no separate firmware manager UI entry point in the app bundle layout described by this release).
- Documentation index and cross-links updated (`docs/PROJECT_INDEX.md`, `README.md`).

## Notes for distributors

- Build and version stamping continue to use the root `VERSION` file plus `scripts/update_version.sh` (Run Script phase) as described in `docs/dev/VERSION_AND_RELEASE.md`.
- After you archive and notarize, add the final release date above and create the git tag (for example `v1.2.5`) on the commit that ships this build.
