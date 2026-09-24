# User guide

## Library

Books are saved in StoryPress's local app library. The sidebar selects a book or starts a new story. **Open sample book** adds an explicitly labelled offline example; it does not contact a model service. The sample can be removed like any other book.

## Create and edit

Start a new story with a theme, target age range, page count, and visual style. StoryPress asks the selected story provider for a structured text plan. The plan includes a title, a character description, page narration, and an illustration prompt for each page.

The page editor keeps narration and illustration prompts separate. Edit the title, character description, page text, or prompt directly. StoryPress saves changes automatically and shows the save state. Your prose remains text in the app and in exported PDFs.

## Illustrations

Choose **Generate illustrations** to fill pages that do not have finished artwork. The progress area reports completed pages and includes a cancel action. If a page fails, its error is shown and the other pages remain available. Use **Regenerate** on a single page to try again; previous artwork is retained by the library.

You can import reference artwork for a book. StoryPress copies it into the local library and sends it only to an explicitly selected image provider that supports reference input. ComfyUI receives reference artwork when the active workflow supports the configured image input. OpenRouter reference support depends on the selected model.

## Export

Choose **Export PDF** in the book header (or press **Command-Shift-E**) to choose a destination file. Text stays selectable. Export requires artwork for every page; the app reports missing illustrations or layout problems instead of silently clipping content.

## Errors and interrupted work

Provider errors stay visible in the interface. Fix the selected endpoint or model, refresh model discovery if needed, then retry. Cancelling generation stops StoryPress's active request or job polling; it does not issue a global interrupt to your ComfyUI service. After relaunch, unfinished pages can be generated again.

For setup and recovery steps, see [Troubleshooting](troubleshooting.md).
