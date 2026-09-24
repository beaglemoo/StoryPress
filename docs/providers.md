# Provider setup

StoryPress keeps story planning and illustration providers in separate settings. Changing one does not change the other. A failed request is shown to the user; StoryPress never switches to another provider automatically.

## Story planning

| Choice | Typical endpoint | Data location |
| --- | --- | --- |
| Local on this Mac (oMLX) | `http://127.0.0.1:8843/v1` | The configured local service |
| Local server (DwarfStar) | `http://127.0.0.1:8001/v1` by default; editable | The configured local network service |
| OpenRouter cloud | `https://openrouter.ai/api/v1` | OpenRouter and the selected model provider |

The model list is discovered from the selected endpoint. Refresh it after starting a local service or changing endpoints. Model IDs can also be typed when they are not in the discovered list. A cloud choice requires a Keychain API key.

## Illustrations

| Choice | Typical endpoint | Notes |
| --- | --- | --- |
| ComfyUI | `http://127.0.0.1:8188` | Use a compatible workflow. Imported workflow JSON is stored in app settings; reference artwork is uploaded to this chosen ComfyUI endpoint when supported by the workflow. |
| OpenRouter cloud | `https://openrouter.ai/api/v1` | Choose an image model from discovery and provide a Keychain API key. Image input support depends on the selected model. |

Both endpoint fields are editable. Use HTTPS for remote services when available, and only connect to services you control or trust. The app's sandbox allows outbound network connections and user-selected file access needed for imports and PDF export.

## Model discovery and errors

Model discovery is an explicit action. A configured endpoint or API key does not imply that a model is available. If refresh or generation fails, the selected provider remains selected and the interface shows the error so you can correct the endpoint, model, or credentials.

StoryPress does not include local models, a DwarfStar runtime, ComfyUI, or a hosted relay service.
