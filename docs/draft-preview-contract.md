# Draft preview + story editor: shared contract

Goal: the in-app story Preview is the REAL site page, rendered on the Pi by the real pipeline
(`~/devrobotics-site/_tools/frames/frames.py` + story.template.html), from an UNSENT local draft,
without touching `~/frames-inbox`. Server: `server/polaris_app_api.py` (Flask, bearer token or `polaris_token` cookie).
All routes below are on the app server (https://<host>:8443). JSON errors are `{"error": "..."}`.

## 1. Blob cache (uploaded originals, content-addressed)

- `POST /v1/blobs/missing`  body `{"hashes": ["<sha256 hex>", ...]}` -> `{"missing": [...]}`
- `PUT /v1/blobs/<sha256>`  raw request body = file bytes; header `X-File-Name: <name>` (informational).
  Server streams to a temp file, verifies sha256 == path, then stores `blobs/<sha256>` (idempotent). 400 on mismatch.

## 2. Draft preview

- `POST /v1/frames/draft-preview`  JSON:
  ```json
  {"draftId": "<uuid>", "kind": "story", "slug": "my-story",
   "fields": {"title": "...", "place": "...", "cover": "IMG_1.HEIC", "gps": "show", "date": "...", "summary": "...", "alt": "..."},
   "body": "<markdown body>",
   "files": [{"name": "IMG_1.HEIC", "sha256": "<hex>"}, {"name": "IMG_2.HEIC", "remote": true}]}
  ```
  `remote:true` = the file already exists in `~/frames-inbox/stories/<slug>/` (editing a sent story): reference, don't upload.
  Returns 202 `{id, state, log, result}` (job protocol identical to /v1/frames/preview; 409 when busy).
  Job result on done:
  ```json
  {"url": "/frames/<slug>.html", "draftId": "...", "builtAt": 1792000000,
   "bodyStartLine": 9,
   "issues": [{"level": "error|warning", "line": 14, "file": "story.md", "message": "...", "kind": "no-date|missing-file|marker|other", "name": "IMG_2.HEIC"}]}
  ```
  `line` = 1-based line in the generated story.md (the server writes `---` front matter then body; `bodyStartLine` is the
  line number of the first body line, so body-relative line = line - bodyStartLine + 1).
  On a pipeline/validation failure the job state is `failed` and `result` still carries `issues` (+ `error` summary).
- `DELETE /v1/frames/draft-preview/<draftId>` -> `{ok:true}` (idempotent; frees the draft's folder).
- Serving: static preview pages are served at the ORIGIN ROOT (site pages use root-absolute /assets/..., /_media/...).
  The server picks the site root from cookie `polaris_preview=<draftId>` if that draft folder exists, else the default
  inbox preview site. Draft pages are therefore loaded as `https://<host>:8443<url>` with BOTH cookies set
  (`polaris_token`, `polaris_preview`). Cookie ids must be validated (uuid/hex only; no path traversal).

How a draft is built (server, isolated): own folder `STATE/drafts/<draftId>/` containing a site copy (hardlink/rsync
--link-dest from the current default preview-site to stay cheap), a scratch inbox made of symlinks to every real inbox
entry EXCEPT the draft's own slug, plus the draft story folder (story.md written with the same `render_md`, remote files
symlinked from the real inbox, new files hardlinked from the blob cache under their given names). Then
`frames.py build --repo <draft site> --inbox <scratch inbox>` so the grid/pager match "published set + this draft".
Never write into `~/frames-inbox` or `~/devrobotics-site`. Never publish.

## 3. Purge / cache (global cap 2 GB)

Counted together: draft folders, blob cache, thumbnail cache, default inbox preview site (`preview-site`).
- Delete a draft's folder immediately on DELETE; keep at most 3 draft folders (LRU by last preview); expire after 24 h.
- If total > 2 GB evict LRU: first expired/old drafts, then blobs not referenced by a kept draft (oldest access first),
  then thumbs. Never evict the default `preview-site` below what the inbox preview needs; it can be rebuilt, so it may be
  dropped last. Purge runs at the start of every draft-preview build AND from a daily systemd timer
  (`polaris-app-purge.timer` + `.service`, running `polaris_app_api.py purge` or a sibling script).
- `GET /v1/cache` -> `{"usedBytes":..., "capBytes": 2147483648, "parts": {"drafts":..., "blobs":..., "thumbs":..., "previewSite":...}, "draftCount": n}`
- `POST /v1/cache/clear` -> frees everything evictable (all drafts, blobs, thumbs; keeps preview-site) -> same shape as GET.

## 4. Client types (Swift) shared between editor and preview

`StoryBlocks.swift` (blocks <-> Markdown) and `DraftPreviewController.swift` (preview state) are stubs owned by
different agents; see their headers. The editor embeds `DraftPreviewView`, shows `issues` as badges on blocks via
`StoryBlocks.serialize(...).lineRanges` (body-relative lines).
