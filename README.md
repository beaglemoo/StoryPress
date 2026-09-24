# StoryPress

<img src="docs/assets/storypress-app-icon-original.png" alt="StoryPress icon: an open book beneath a crescent moon" width="132">

StoryPress is a native macOS app for making editable picture books. Draft a story with a chosen provider, revise the narration and illustration prompts page by page, generate artwork only when you are ready, then export a printable PDF.

The app does not bundle a model or image server. You can connect to a local model service, a local server, OpenRouter for story planning, ComfyUI for illustrations, or OpenRouter for illustrations. You choose story and illustration providers separately; StoryPress never silently switches between local and cloud services. Books and imported artwork are stored in your local app library.

## First run

See [Getting started](docs/getting-started.md) for local-only and cloud setup paths. You can open the clearly marked sample book to explore the editor without connecting a provider or generating anything.

## Requirements

- macOS 26 or later
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

Generate the Xcode project and open it:

```sh
xcodegen generate
open StoryPress.xcodeproj
```

Or build a universal Apple Silicon and Intel app bundle with `./scripts/build-app.sh`. The default build is unsigned. See [Development](docs/development.md) for signing, packaging, testing, and provider setup.

## Guides

- [User guide](docs/user-guide.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Validation status and current limits](docs/validation.md)
- [Provider setup](docs/providers.md)
- [Privacy and data handling](docs/privacy.md)
- [Development and signing](docs/development.md)
- [Contributing](CONTRIBUTING.md)

## Project status

StoryPress is an early community project. Provider behavior depends on the service you configure and the selected model. See the guides for setup and current limits. No hosted backend or model is included.

## License

StoryPress is available under the [MIT License](LICENSE). The original app icon artwork is included in [docs/assets](docs/assets/storypress-app-icon-original.png); see [asset provenance](docs/assets/README.md).
