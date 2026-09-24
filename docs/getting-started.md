# Getting started

StoryPress is an editor and provider client. It does not install or bundle language models, ComfyUI, or cloud accounts. Choose the setup that fits your workflow; story planning and illustration providers are selected separately.

## Explore without connecting a provider

Open StoryPress and choose **Open sample book**. The sample is clearly marked and can be edited and exported without contacting a model or spending cloud credits. It is not a generated story.

## Use local services

Install and start a compatible service on the Mac running StoryPress. In Settings, select **Local on this Mac** for story planning (oMLX) or **Local server** (DwarfStar), refresh the model list, and choose an available model. Confirm that the service is listening on its displayed endpoint before creating a story.

For illustrations, select **ComfyUI** and set its endpoint. Import a compatible workflow JSON or use the bundled workflow when it fits your ComfyUI setup. The workflow must expose the supported prompt and seed inputs; optional reference artwork is uploaded only to the selected ComfyUI service.

Local services must be installed, running, and reachable from the Mac. StoryPress does not download model weights or start those services.

## Use OpenRouter

In Settings, explicitly select **OpenRouter cloud** for story planning or illustrations. Enter your API key in the secure field and save it; StoryPress stores the key in macOS Keychain. Refresh models and select the model you want to use. Story and illustration settings are independent, so choose each cloud path explicitly.

OpenRouter requests send the selected model, the story brief or illustration prompt, and the minimum request data needed by that provider. See [Privacy and data handling](privacy.md) before using cloud models.

## Create and export a book

Choose **New Story**, set the theme, age range, page count, and art style, then create the text plan. Review the character description and edit each page's narration and illustration prompt. StoryPress saves edits to the local library. Choose **Generate illustrations** when ready; generation can be cancelled, and a failed or unwanted page can be retried on its own. Export the completed book as PDF from the book header or press **Command-Shift-E**.

See the [User guide](user-guide.md) for editing and recovery details.
