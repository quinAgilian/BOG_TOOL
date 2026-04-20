# BOG Tool v1.2.4 Release Notes

Release date: 2026-04-20

## Highlights

- Fixed a production/FQC rule mismatch where `step_disable_diag` could accept gas status `1 (ok)` while `step_gas_system_status` still failed due to a narrower allowed set.
- Updated rule evaluation so gas status validation uses a union of both step expectations at runtime.
- Refined CN/EN rule descriptions to match the new allowed-set semantics (instead of hardcoding `1=ok` as the only pass condition).

## Production Test Changes

- `step_gas_system_status` now validates against:
  - `step_gas_system_status.config.expected_gas_status_values`
  - unioned with `step_disable_diag.config.expected_gas_status_values`
- Values are clamped to `0...9`, deduplicated, and sorted before validation.
- When the union expands the original gas-status step set, a debug log entry is emitted to aid troubleshooting.

## Why This Matters

- Avoids false failures in FQC when SOP config between `disable_diag` and `gas_system_status` is inconsistent (for example, `[0,1]` vs `[0]`).
- Preserves backward compatibility while making rule interpretation safer in production.

## Rule UI / Text Updates

- Updated localized descriptions in:
  - `en.lproj/Localizable.strings`
  - `zh-Hans.lproj/Localizable.strings`
- Updated wording from “must be 1 (ok)” to “must be in allowed set” and documented union behavior with Disable diag expectations.

## Suggested Verification Checklist

- Configure:
  - `step_disable_diag.expected_gas_status_values = [0,1]`
  - `step_gas_system_status.expected_gas_status_values = [0]`
- Verify device reporting `1 (ok)`:
  - `step_disable_diag` passes
  - `step_gas_system_status` also passes after union logic
- Confirm debug logs show merged allowed set when expansion occurs.

