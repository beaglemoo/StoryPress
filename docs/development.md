# Development

StoryPress is a Swift 6 SwiftUI app for macOS 26 or later. `project.yml` is the source for the generated Xcode project; do not commit the generated `.xcodeproj` or DerivedData.

## Local build and tests

Install Xcode 26 or later and XcodeGen, then run:

```sh
xcodegen generate
xcodebuild test -project StoryPress.xcodeproj -scheme StoryPress -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
./scripts/build-app.sh
```

The app build targets both Apple Silicon and Intel and is unsigned unless signing variables are provided. The script copies `StoryPress.app` and creates `StoryPress-macos.zip` under `dist/`.

## Developer ID signing and notarization

Keep certificates and credentials in macOS Keychain. Do not add a certificate, key, team ID, or notarization credential to repository files. To sign a release build, set the local environment variable `STORYPRESS_SIGNING_IDENTITY` to an installed Developer ID Application identity. Optionally set `STORYPRESS_TEAM_ID` if the local Xcode signing setup requires it, then run:

```sh
STORYPRESS_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
```

For notarization, first store a notarytool credential profile in Keychain, then set `STORYPRESS_NOTARY_PROFILE` to that profile name for the build. The script submits the app archive, waits for the result, staples a successful ticket, and recreates the ZIP. It does not publish or upload a release.

For Release builds, Xcode's injected base entitlements are disabled. Signed builds request a secure timestamp and the packaging script checks that `get-task-allow` is absent or false and that the signature includes a timestamp. When notarization is requested, the script saves the JSON receipt under the ignored `build/` directory and continues to stapling only when the reported status is exactly `Accepted`; a failed or invalid submission stops packaging and preserves the receipt for diagnosis.

## Architecture

SwiftUI views call the observable `AppModel`. Core services own provider requests, Keychain access, book persistence, workflow substitution, image files, and PDF export. Views use the model's resolved asset URLs and never create storage paths. Story and illustration providers are independent and explicitly selected.

Tests use synthetic books and stub services. Do not use paid live APIs in automated tests or add private books, endpoints, credentials, or model files to fixtures.
