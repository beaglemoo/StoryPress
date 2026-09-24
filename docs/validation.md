# Validation status

This page records the current community-release evidence and its limits. Provider and visual-quality results apply to the tested setup and sample content; they are not guarantees for every model, Mac, workflow, or book.

## Build and app checks

- The core unit suite passed: 23 tests. The suite uses local synthetic data and does not call paid APIs.
- The focused PDF polish checks passed: 2 of 2, after the core unit suite.
- The final Developer ID signed app is universal arm64 and x86_64. Signature verification passed, notarization was accepted, the ticket was stapled and validated, and Gatekeeper accepted the app as Notarized Developer ID. On-device UI validation was performed on arm64 only, on a Mac with an M5 Pro running macOS 27.
- In the signed app, editing the offline sample and quitting/reopening preserved the edits.
- A completed three-page book was planned with oMLX, illustrated with ComfyUI and Qwen Image 2.1, and exported from the final notarized app. All three illustration states reached complete; existing artwork remained available and export was enabled.
- The exported PDF has four A4 pages. Extracted text matched the exact narration and remained selectable. All four rendered pages passed visual review with serif text and no clipping or overlap.
Useful local checks are:

```sh
xcodebuild test -project StoryPress.xcodeproj -scheme StoryPress -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
lipo -archs dist/StoryPress.app/Contents/MacOS/StoryPress
codesign --verify --deep --strict --verbose=2 dist/StoryPress.app
stapler validate dist/StoryPress.app
spctl --assess --type execute --verbose dist/StoryPress.app
```

The first command runs the local unit suite. The remaining commands inspect the signature, stapled ticket, and Gatekeeper assessment of a notarized release app; signing setup and packaging are documented in [Development](development.md).

## Provider checks

| Provider or workflow | Evidence | Limit |
| --- | --- | --- |
| oMLX story planning | Live three-page story planning completed. | This verifies the tested local endpoint and model only. |
| DwarfStar | A live three-page synthetic story plan completed in 21.7 seconds through the compiled `StoryProviderClient`. | This verifies planning for the tested local endpoint and model only; image generation was not part of this check. |
| OpenRouter | Live model-catalog discovery and mocked payload, authentication, and reference-image tests passed. | No paid live text or image generation was performed. |
| ComfyUI with Qwen Image 2.1 | A balanced-profile sample produced a 1024 × 1024 image using 25 steps in about 120 seconds. A one-step reference-image wiring check passed. The signed app completed all three images for the live oMLX story and exported the book. | The one-step check verifies wiring, not illustration quality or character consistency. The completed batch confirms the tested path, not quality or consistency guarantees for other stories, workflows, or systems. |

## Current limits

StoryPress connects to model services installed and managed separately; it includes no model weights or hosted model service. It does not unload models or release memory held by those external services. The tested workflow relies on a person to review and edit the story, supply reference art when useful, and regenerate pages as needed. There is no autonomous visual review, OCR-based proofing, or automatic character-consistency check.

Model availability, speed, memory use, output quality, reference-image behavior, and provider charges depend on the selected model, service, workflow, hardware, and provider policies. See [Provider setup](providers.md), [Privacy and data handling](privacy.md), and [Troubleshooting](troubleshooting.md) before choosing a cloud service or workflow.
