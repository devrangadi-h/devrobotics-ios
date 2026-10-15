# Problems system, formatting and clip playback: shared contract

Decisions (owner-approved, don't re-ask):
- Problems have a severity: **error** (blocks sending that draft; others still send) and **warning** (never blocks).
- Story editor (Write and Preview): a **pill pinned under the navigation bar** ("1 error · 1 warning"); tapping opens a
  **compact bottom sheet** listing problems with fix buttons; tapping a problem scrolls to its block and highlights it.
  Blocks also carry inline badges. The old stacked banners are removed.
- Messages are rewritten into plain English with the file name (`FrameProblemEngine.fromPipeline`); unknown messages stay raw.
- Fix actions on every kind: noDate -> Set a date; unusedFile -> Insert as photo / Remove file; missingFile -> Remove block;
  invalidMarker -> Show text.
- **Set a date** opens a small sheet with a graphical calendar and one Save button (no "Override date" toggle in this flow);
  starts on the file's creation date when known, otherwise today. Details shows a "Date" row: "From the photo" /
  "Set manually: 14 Oct 2026" that opens the same sheet. Also available from the photo editor.
- **Local instant checks** (no network): no date taken (ImageIO metadata at pick time), unused file, marker -> missing file.
  The Pi's build stays the final authority.
- **Unused media tray**: horizontal thumbnails above the floating bar, only when unused files exist; tap -> Insert here
  (at the focused text block's caret, else end) or Remove; drag into the story to place.
- **Photo editor and Frames list** use the same system: problem pill/sheet in the photo editor, "N errors" pill on a tile
  with a blocked draft, and the Send bar disables only that draft ("Fix 1 error first").
- **Bottom Write/Preview/+ bar** collapses to a small pill when scrolling down, expands on scroll up or tap; it never covers
  the last block's caption.
- **Clips**: duration badge, "Trimmed" mark, tap to play inline muted/looping, tap again to expand; no autoplay.
  Server: `GET /v1/frames/<kind>/<slug>/clip/<name>` returns a small streamed H.264 preview (Range supported) and
  `GET .../clipinfo/<name>` (or include `durationSeconds` in the entries' file metadata) reports duration.
- **Formatting**: Markdown stays the stored format. Inline syntax (`**`, `*`, `[](url)`) is hidden except around the caret;
  block syntax (`## `, `- `, `1. `, `> `) is shown as real styling (larger heading, bullets, number, quote bar).
  Buttons light up when the selection/caret is already formatted. Bold/Italic wrap the selection, or the word under the
  caret when nothing is selected; tapping again removes. Link opens a sheet (Text + URL, Add / Cancel, edit/remove existing).
- **Launch**: logo flies in (spring + glow, ~1.2 s, tap to skip, Reduce Motion = fade, fresh launch only), then the app.
  Settings gets "Open on launch" (Status / Lights / Frames / Settings), default Lights.
