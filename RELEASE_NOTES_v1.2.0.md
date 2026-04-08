# BOG Tool v1.2.0 Release Notes

Release date: 2026-04-08

## Highlights

- Added a new JSON-driven production SOP step: `step_verify_hw_rev`.
- Hardware revision verification is now decoupled from firmware verification to avoid duplicate failure decisions.
- Improved HW revision write/read-back workflow and validation behavior in related debug and production paths.
- Synced production rules documentation for the new HW revision verification step.

## Production Test Changes

- Introduced `step_verify_hw_rev` execution flow:
  - read current HW revision
  - compare with target value
  - optionally auto-write when mismatch
  - read-back confirmation with timeout and polling
- Added strict JSON config validation for required HW revision step fields.
- Updated default production rules to include `step_verify_hw_rev` right after `step_verify_firmware`.

## Rule Schema Additions

`step_verify_hw_rev.config` now supports:

- `target_hardware_version`
- `auto_write_when_mismatch`
- `read_timeout_seconds`
- `write_verify_timeout_seconds`
- `write_verify_poll_interval_ms`

## Documentation

- Updated production rules guide to include:
  - required step list with `step_verify_hw_rev`
  - required config keys for the new step
  - updated authoring checklist references

## Compatibility Notes

- `sendDevAccessChangeHardwareRevision` behavior depends on device firmware capability. Older firmware may reject HW revision write commands.
- If device does not expose HW revision characteristic (`2A27`) or read-back is delayed, timeout/polling configuration should be adjusted in rules JSON.

## Suggested Verification Checklist

- Match path: device HW equals target -> pass
- Mismatch + auto-write disabled -> fail
- Mismatch + auto-write enabled + read-back match -> pass
- Mismatch + auto-write enabled + read-back mismatch/timeout -> fail

