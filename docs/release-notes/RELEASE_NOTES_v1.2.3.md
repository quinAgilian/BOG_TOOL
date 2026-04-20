# BOG Tool v1.2.3 Release Notes

Release date: 2026-04-19

## Highlights

- **Production session traceability**: Each production run carries an optional **`clientRunId`** (generated when starting a test), aligned with server persistence and CSV/query fields for end-to-end correlation (`client_run_id` / `clientRunId`).
- **BLE workflow**: **Double-click** a row in the BLE scan list to **connect** without using the Connect button.
- **Bundled server submodule**: Dashboard and production UX updates from `bog-test-server` (including production table UX such as select-all behavior), extended production rules/BLE wiring, and API documentation alignment (`API_SPEC.md`, audit notes).

## Production Test / Upload

- Payload may include **`clientRunId`** alongside existing fields; older servers ignore unknown fields.
- Recommend pairing with server builds that persist `client_run_id` when regression-testing traceability.

## Documentation (repository)

- Parent README / project index cross-reference **`server/API_SPEC.md`** and **`server/docs/API_SPEC_AUDIT.md`**.
- Submodule bumped to commits that document **`clientRunId`** and clarify reserved **`GET /api/production_rules/versions`** behavior.

## Compatibility Notes

- **`clientRunId`** is optional; installs that do not upload or use older backends are unaffected.
- Server behavior for optional payload fields follows **`server/API_SPEC.md`**; verify your deployed API version if uploads fail validation.

## Suggested Verification Checklist

- BLE: scan → **double-click** row → device connects as expected.
- Production: complete one run with upload enabled → confirm **`clientRunId`** appears in server records/export when backend supports it.
- Regression: single-click Connect path still works.
