# Contributing

Thanks for helping improve StoryPress. Small, focused changes are easiest to review.

## Before opening a change

1. Check the open issues and describe the user problem your change addresses.
2. Keep credentials, personal endpoints, generated books, and model files out of the repository.
3. Use synthetic fixtures for tests. Do not add household, family, or other private material.
4. Update the relevant user or development guide when behavior changes.

## Build and test

Install Xcode 26 or later and XcodeGen, then run:

```sh
xcodegen generate
xcodebuild test -scheme StoryPress -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

The tests must not call paid cloud APIs. Local integration checks should use an endpoint you control and should be described in the change.

## Style and scope

Use SwiftUI and the shared `AppModel` for view actions. Keep persistence paths inside core services. Preserve the user’s selected provider, show errors in the interface, and never add automatic local-to-cloud fallback. Keep UI text accessible and free of emoji.

Do not commit an Xcode-generated project, build products, app libraries, provider credentials, or signing materials.
