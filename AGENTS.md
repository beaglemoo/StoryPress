# StoryPress project guide

StoryPress is a native macOS picture-book editor. The Xcode project is generated from `project.yml` and is not committed.

## Source layout

- `StoryPress/Views/` contains SwiftUI screens and reusable view components.
- `StoryPress/ViewModels/` owns app state and UI-facing actions.
- `StoryPress/Models/` contains Codable app data models.
- `StoryPress/Services/` contains provider, image, persistence, and PDF services.
- `StoryPress/Support/` contains shared errors, helpers, and constants.
- `StoryPress/Resources/` contains bundled, non-secret resources such as the optional ComfyUI workflow template.
- `StoryPress/Assets.xcassets/` contains the app icon and appearance assets.
- `StoryPressTests/` contains local synthetic-fixture unit tests.
- `docs/` contains user, provider, privacy, architecture, and development guidance.

## Conventions

- Keep the interface native SwiftUI and support macOS 26 or later.
- Keep page text editable and selectable in the interface and exported PDF.
- Treat local and cloud providers as explicit user choices. Never switch providers automatically.
- Store provider credentials in Keychain. Do not put tokens, private endpoints, user data, or local machine paths in source or logs.
- Preserve the original image file when a page is regenerated; write each attempt to a new library asset.
- Keep generated books, illustrations, build products, local settings, and environment files out of Git.
- Use synthetic fixtures for tests. Do not add private household, family, or RAG material.
- Do not use emojis in source, documentation, or interface strings.

## Build and validation

Run `xcodegen generate`, then `./scripts/build-app.sh` to build a local release app. Run the unit suite with `xcodebuild test -scheme StoryPress -destination 'platform=macOS'`. See `docs/development.md` for signing and local provider setup.
