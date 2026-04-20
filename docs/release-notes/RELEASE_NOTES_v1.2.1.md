# BOG Tool v1.2.1 Release Notes

Release date: 2026-04-19

## Highlights

- Production step `step_verify_hw_rev` is now **read-only**: it confirms that hardware revision (`2A27`) can be read successfully within timeouts. It no longer compares against a target, auto-writes, or performs write-back verification.
- Regional shipment programming (**US/EU**) remains in `step_hw_rev_shipping_region`, including optional Dev Access write and read-back confirmation against the configured destination-specific HW_REV strings.

## Production Test Behavior

| Step | Role |
|------|------|
| `step_verify_hw_rev` | Read HW_REV until non-empty or timeout; pass on successful read. |
| `step_hw_rev_shipping_region` | Optionally write the HW_REV that encodes shipping region and verify by read-back (unchanged semantics). |

Serial number step `step_read_serial_number` behavior is unchanged: non-empty SN within timeout passes.

## Rule Schema (`step_verify_hw_rev.config`)

Strict validation now requires only:

- `read_timeout_seconds`
- `write_verify_poll_interval_ms` (**used as read polling interval**; key name kept for backward compatibility with existing JSON files.)

The following keys are **no longer used** by this step (ignored if present): `target_hardware_version`, `auto_write_when_mismatch`, `write_verify_timeout_seconds`.

Default bundled rules (`default_production_rules.json`) and the in-app rules editor reflect the simplified HW read configuration.

## Upload Payload Note

Root field `deviceHardwareRevision` reflects the **last cached** hardware revision during the run (typically after regional programming if that step succeeds). Per-step strings in `stepResults` remain **historical snapshots** for each step (for example, read-step value may differ from final `deviceHardwareRevision` after shipment programming).

## Compatibility Notes

- `sendDevAccessChangeHardwareRevision` still applies only where the workflow performs a write (`step_hw_rev_shipping_region`), and depends on firmware support as before.
- Existing rule JSON files that still list obsolete keys under `step_verify_hw_rev` continue to decode; ensure the two required keys above are present for strict loading.

## Suggested Verification Checklist

- `step_verify_hw_rev`: device exposes HW_REV → pass; missing/empty until timeout → fail.
- After a successful `step_hw_rev_shipping_region` write path, final `deviceHardwareRevision` matches the selected region target.
- Imported legacy rules JSON loads when `read_timeout_seconds` and `write_verify_poll_interval_ms` are set for `step_verify_hw_rev`.
