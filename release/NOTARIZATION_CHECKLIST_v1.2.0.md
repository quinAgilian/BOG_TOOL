# v1.2.0 Sign and Notarize Checklist

## Artifact
- App: `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Release/BOG Tool.app`
- Zip: `release/BOG-Tool-v1.2.0-macOS.zip`

## Preflight
1. Verify code signature:
   - `codesign --verify --deep --strict --verbose=2 "<APP_PATH>"`
2. Verify notarization tool:
   - `xcrun notarytool --version`
3. Ensure credentials profile exists (create once if needed):
   - `xcrun notarytool store-credentials "AC_PASSWORD" --apple-id "<APPLE_ID>" --team-id "38V6W364PW" --password "<APP_SPECIFIC_PASSWORD>"`

## Submit for notarization
- `xcrun notarytool submit "release/BOG-Tool-v1.2.0-macOS.zip" --keychain-profile "AC_PASSWORD" --wait`

## Staple and validate (if submitting .app workflow)
1. `xcrun stapler staple "<APP_PATH>"`
2. `xcrun stapler validate "<APP_PATH>"`

## Gatekeeper check
- `spctl -a -t exec -vv "<APP_PATH>"`

## Notes
- Current Release build is signed with Apple Development identity.
- For external distribution, export/sign with Developer ID Application before notarization.
