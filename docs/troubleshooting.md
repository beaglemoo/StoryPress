# Troubleshooting

## A model is unavailable

Open Settings and confirm the intended story or illustration provider is selected. Story and illustration providers are independent. For a local provider, start its service, confirm the configured endpoint is reachable from this Mac, and use **Refresh** to discover models. Check that the selected model ID is available in that service. For OpenRouter, confirm the API key is saved in Keychain and that the selected model supports the requested task. StoryPress keeps the selected provider when a request fails; it does not switch to a cloud provider for you.

For ComfyUI, open the ComfyUI interface and confirm it is running at the configured endpoint. A custom workflow must be a supported API-format JSON workflow containing the prompt and seed placeholders. If reference artwork is attached, the workflow must also accept the reference image. The workflow controls its output dimensions; StoryPress does not infer or resize custom workflow output dimensions from the standard illustration size setting.

## A local model runs out of memory or is very slow

Model memory needs depend on the model, its quantization, context length, image size, and the other workloads on the Mac. Check the model service's own logs and resource status, close other memory-heavy applications if appropriate, and try a smaller model or shorter request in that service. For OpenRouter, check the provider's current model limits and availability. StoryPress cannot free memory held by another service or guarantee a model will fit.

## Import or PDF export fails

Use **Import JSON…** in ComfyUI settings for a workflow file, or **Add reference art** in the book editor for an image. macOS asks for access to the selected file. Choose a readable file in a supported format and retry if the access panel was cancelled. Imported reference art is copied into the local book library; the source file is not edited.

PDF export is available when each page has artwork. Finish or regenerate missing illustrations, then choose **Export PDF** in the book header. If export reports a missing asset or layout problem, keep the book open, restore or regenerate the affected page artwork, and retry. Export writes to the destination chosen in the save panel.

## Cancelling generation and preserving work

The Cancel button stops StoryPress's active request or job polling. Completed pages and saved text edits remain in the book. A request already accepted by a provider may continue on that provider; for ComfyUI, check its own queue or history if needed. After cancelling, retry incomplete pages with **Generate illustrations** or use **Regenerate** on a page. Each regeneration is saved as a new attempt, so earlier artwork remains available.

If a request times out after submission, check the provider's job history before retrying. The app may not know whether the remote service accepted work when the connection ended.

## Local and cloud choices

Local providers send requests to the endpoint you configure and require the service and model to be installed and running separately. OpenRouter sends prompts or images to OpenRouter and the selected model provider. Provider terms and charges vary; review them before using cloud models. StoryPress does not include a hosted relay and never changes from your selected local provider to cloud automatically. See [Privacy and data handling](privacy.md) and [Provider setup](providers.md) for more detail.
