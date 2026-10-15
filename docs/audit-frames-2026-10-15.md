# Frames consistency audit, 2026-10-15

Looks and flow only. No behaviour, data, networking, parsing, text-view or drag-and-drop changes.

| File | Deviation | Fix |
|---|---|---|
| EditorParts.swift (FilesSection) | Swipe "Remove" deleted a file with no confirmation; 12 pt thumbnail radius | Confirmation dialog "Remove this file?"; radius `DS.Radius.chip` |
| EditorParts.swift (DateRow) | Detents set outside `SetDateSheet`, fighting its own | Removed outer override; sheet owns its detents |
| StoryEditorView.swift | Problem-badge and unused-tray "Remove file" / "Remove block" fixes acted immediately | Route through confirmation (`request`): file dialog, existing block dialog |
| StoryEditorView.swift | Problems sheet and set-date sheet detents overridden by the caller (`.medium/.large`) | Removed overrides; one source of truth per sheet |
| StoryEditorView.swift | 4 pt thumbnail radius in preview markers | `DS.Radius.chip`, continuous |
| Problems/ProblemsUI.swift (ProblemsSheet) | No Close; Remove file / Remove block fix buttons unconfirmed | Close top-leading; confirmation dialog before destructive fixes |
| Problems/ProblemsUI.swift (SetDateSheet) | Custom heading, no Close | NavigationStack with inline title "Set a date" and Close top-leading; Save stays the one primary action |
| StoryEditor/Sheets.swift | Details sheets used Done trailing, writer used Close trailing, YouTube used Cancel; no drag indicator; ad-hoc 4/20/12 paddings | Close top-leading everywhere (Insert / Save stays primary), drag indicator, `DS.Space` |
| Formatting/LinkSheet.swift | "Cancel", no drag indicator | "Close", drag indicator |
| Publish/PublishSheetView.swift | 10 pt radius on change icon plate; warning plate stroke used circular corners vs continuous fill | `DS.Radius.chip`; both continuous |
| List/PhotoFocusPicker.swift | 4 pt crop frame radius | `DS.Radius.chip`, continuous |
| DraftPreview/DraftPreviewView.swift | `.bordered` Cancel; 10/12/20 raw spacing | `.secondaryAction`; `DS.Space` |
| StoryEditorChrome.swift, UnusedMediaTray.swift, ProblemsPill | At accessibility text sizes floating bar labels truncated ("Write..."), tray and pill swallowed the screen | `.dynamicTypeSize(...xxxLarge)` on the floating chrome only |

## Flows checked (demo screens, light, dark, accessibility-XXXL)
frames, photo, story, storyproblems, publish, setdate. Modals now dismiss the same way (Close top-leading, drag
indicator, swipe down); destructive actions always confirm (delete entry, delete block, remove file from list, tray,
problems sheet, details files).

## Deliberately left
- Cover plate outer radius `DS.Radius.card + 4`: it is the concentric outer of a card plate inset by 4 pt, so the +4 is intentional.
- LiveTextView accessory `cornerRadius = 10` and `MarkdownStyler` 1.5 pt bar: UIKit text-view danger zone.
- LinkSheet "Remove link": inline edit of text, undoable, not a data deletion.
- "Dismiss draft" context action (only offered on unmodified drafts).
- PublishSheet "Done" after success and "Close" while working: different states, both consistent with the rules.
- "Replace" (cover/photo) vs "Choose photo" (empty state) kept: matches empty vs filled state.
- Demo storyproblems layout: the unused tray sits over a block's drag handle in the fixture; real use scrolls.
- Accessibility sizes after cap were not re-screenshotted; only build verified.
