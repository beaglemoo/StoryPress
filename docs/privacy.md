# Privacy and data handling

StoryPress stores the book library, page text, prompts, illustration files, and imported reference artwork on the Mac in its app-managed library. These files are needed to reopen books and export them. The sample book is local bundled fixture content and is labelled as a sample.

Provider traffic follows the selection in Settings. Story planning sends the theme, age range, page count, and art style to the configured story provider. Illustration requests send the selected page prompt, seed where configured, and any explicitly selected reference artwork to the configured illustration provider. ComfyUI workflows and image requests go to the configured ComfyUI endpoint. OpenRouter requests go to OpenRouter and the selected model provider. Local selections send requests to the local endpoint the user configured.

StoryPress does not automatically forward a failed local request to a cloud provider. A cloud provider is used only after you select it. Model discovery also contacts only the endpoint currently selected for that provider.

OpenRouter credentials are stored in macOS Keychain and are not part of the saved settings file. The app does not put API keys into generated books. Errors shown in the interface are intended to avoid echoing credentials; when reporting a problem, remove private book text, reference images, and service addresses.

The app needs outbound network access for configured providers and user-selected read/write access for importing workflow/reference files and saving a PDF. No separate hosted StoryPress backend is included. A provider may retain or process requests under its own policies; review those policies before sending content to a cloud service.
