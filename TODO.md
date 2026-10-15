# DevRobotics: future improvements

Last updated 2026-10-14. Items are grouped by theme, roughly in priority order within each group.
Legend: **[agreed]** = decided with the owner but not built yet, **[unverified]** = built but never run on a device.

## 1. Verify on a real device (built, never tested)

- [ ] **[unverified]** Keyboard accessory bar: do the 7 formatting icons plus Done fit on a small phone?
- [ ] **[unverified]** Drag-to-reorder of story blocks (drop onto a text block, long stories).
- [ ] **[unverified]** Caret stays visible in the non-scrolling text blocks while the keyboard is up.
- [ ] **[unverified]** Typing performance on a very long story (every keystroke re-serialises the body).
- [ ] **[unverified]** Video trimmer: 10 s cap, output extension (`.mov`), upload and pipeline accept it.
- [ ] **[unverified]** PhotosPicker really returns the original HEIC bytes and keeps the "date taken" metadata
      (if not, uploads fail with "no date taken").
- [ ] **[unverified]** Real-page preview in the WKWebView: `polaris_token` and `polaris_preview` cookies, lightbox opening from `#slug`.
- [ ] **[unverified]** Live Photos use only the still.

## 2. Agreed but not built

- [ ] **[agreed]** Settings: "Polaris cache: 61 MB / 2 GB" with a **Clear now** button (server endpoints `GET /v1/cache` and `POST /v1/cache/clear` already exist).
- [ ] **[agreed]** Use the shared `ConnectionBanner` (with the "Open Tailscale" button) on Lights and Frames; today they show their own plain hint.
- [ ] **[agreed]** Frames list badge: "Edited, not published". Today "Published" only means the slug was published once.

## 3. Frames: publishing

- [ ] Per-entry publish (the pipeline always publishes the whole inbox; today the app lists every pending change first).
- [ ] Unpublish / rollback of the last publish from the app.
- [ ] Progress for large uploads is per file, not per byte.
- [ ] Re-upload automatically when the server purged a blob between upload and build ("has not been uploaded").
- [ ] Show which entries changed on the Pi since a draft was started (edit conflicts between phone and Pi).
- [ ] Professional-mode switch: hide the Frames nav link on the public site from the app (from the site's own TODO).
- [ ] Share-sheet extension: "Send to DevRobotics" from Photos.

## 4. Story editor

- [ ] Undo / redo buttons.
- [ ] Per-photo `place=` inside side-by-side blocks (model keeps these as raw text today).
- [ ] Sub-headings (`###`): needs a site change (renderer + `story.css`), then an editor button.
- [ ] Cover focus point (crop) for stories, like photos have.
- [ ] Paste formatted text / images straight into the body.
- [ ] Search across stories and photos; reorder or pin entries.
- [ ] Duplicate a story as a template.
- [ ] Bring the block editor's polish to the photo editor (same details sheet, issues, preview).

## 5. Preview

- [ ] Preview for photos (opens the grid with the lightbox on that photo; stories only today).
- [ ] Faster first preview (client-side downscaling is not possible, so cache originals and show per-photo progress).
- [ ] Keep the last good build visible, dimmed, while a new build runs or fails.
- [ ] DELETE of a draft that is currently building returns 409; the client should retry.

## 6. Lights

- [ ] Per-lamp control, colour, custom colour temperature, saved presets (needs new lights API routes).
- [ ] Show the real current state (the API has no "get state" endpoint; the app only knows what it last sent).
- [ ] Scenes / schedules, and a widget or Shortcuts action for quick on/off.

## 7. Status and alerts

- [ ] Push notification or widget when Polaris goes offline or a service fails (needs the paid Apple Developer Program for push).
- [ ] Longer temperature/load history and a chart per metric.
- [ ] Service actions (restart a service, view recent logs).
- [ ] Surface the purge timer and last purge result.

## 8. Distribution and the 7-day limit

- [ ] Weekly reinstall is manual (`xtool dev`). Options: pay for the Apple Developer Program, or automate re-signing over Wi-Fi from Polaris.
- [ ] TestFlight / App Store only if the app ever becomes public (needs the paid program).
- [ ] App icon: the favicon is only 240 px; make a proper 1024 px mark.

## 9. Security and hygiene

- [ ] Rotate the shared token; consider a separate token for the app API vs the lights API, and per-device tokens.
- [ ] Optional Face ID lock before the app shows Frames/Lights.
- [ ] Rate-limit failed auth on the server.
- [ ] Public repo: commits carry a personal school email; switch to a GitHub noreply address.
- [ ] Remove unused `MarkdownTextView.swift`; the old `StoryPreview` stays only as the offline fallback.
- [ ] Replace the `@unchecked Sendable` shims (`Core/APISendable.swift`, `nonisolated(unsafe)`) with proper isolation; clear the build warnings.

## 10. Quality and operations

- [ ] Unit tests for `FrameFormat`, `StoryBlocks` and job polling (today only `Tools/blockcheck.swift` runs by hand).
- [ ] A `server/deploy.sh` (copy, restart, smoke test) so deploys aren't manual scp.
- [ ] Server tests in CI; keep `docs/draft-preview-contract.md` in sync with the code.
- [ ] Structured logs for `polaris-app-api` and a health check the Status tab can use.
- [ ] Unverified server paths: purge skipping while a job holds the lock, and last-resort eviction of `preview-site`.
- [ ] Offline mode: queue Lights commands? (probably not; lights need the network by definition).
