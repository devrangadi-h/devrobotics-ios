# DevRobotics design guide (Liquid Glass)

Target: iOS 26+ (Liquid Glass). Brand: keep the site's blue accent and Inter / JetBrains Mono (`Theme`). Everything below is
implemented in `Sources/DevRobotics/Core/Design/DesignSystem.swift`; use it instead of inventing styles.

## What glass is for
- **Glass = things that float above content**: navigation bars, tab bar, toolbars, sheets, floating buttons, banners,
  status chips, and a few hero surfaces (status header, metric tiles). The system already glasses nav/tab/toolbars/sheets
  because the app is built against SDK 26: don't fight it.
- **Content is not glass.** Long text, the story editor body, form rows and lists use plain/grouped backgrounds.
- **Never put glass on glass.** Group neighbouring glass in one `GlassEffectContainer(spacing:)`.
- Tappable glass gets `.interactive()` (the shared button styles do). Only the single primary action is tinted/prominent.

## Do not block the system glass
Don't add: opaque `.toolbarBackground`, solid backgrounds behind a `NavigationStack`, custom `UINavigationBarAppearance` /
`UITabBarAppearance`, `.presentationBackground(solid)`. Use `.dsPage()` on the scroll view/list (clear background + `AppBackground` mesh).

## Building blocks
`AppBackground`, `GlassCard`, `GlassPill`, `MetricTile`, `SectionTitle`, `.dsPage()`, `PressableStyle`/`.pressable`,
`.primaryAction`, `.secondaryAction`, `DS.Space`, `DS.Radius`, `Animation.dsSpring/.dsSnappy/.dsSmooth`, `.dsAnimation(value:)`.
`ConnectionBanner` is the one "not connected" banner (Lights/Frames should use it).

## Motion and feedback
- Press: spring scale via the shared styles. State changes: `withAnimation(.dsSpring)` / `.dsAnimation(value:)`.
- SF Symbols: `.symbolEffect(.bounce, value:)` on success, `.symbolEffect(.pulse)` while working.
- Numbers: `.contentTransition(.numericText())`. Lists: `.transition(.opacity.combined(with: .scale(0.96)))` for insert/remove.
- Use `matchedGeometryEffect` / `glassEffectID` + `@Namespace` only where morphing is the point (e.g. expanding a control).
- **Reduce Motion**: every custom animation goes through `dsAnimation` or checks `accessibilityReduceMotion`.
- Haptics: `.sensoryFeedback(.success|.error|.selection|.impact, trigger:)`. No raw UIKit feedback generators.
- Also respect Reduce Transparency (system glass does), Dynamic Type (`Theme.font(... relativeTo:)`), VoiceOver labels on icon-only buttons.

## Layout
8-pt grid via `DS.Space`; card radius `DS.Radius.card` (28), controls 20, chips 14. Page margin 16. Large titles on
top-level tabs. Keep hit targets ≥ 44 pt. Prefer system controls (Toggle, Picker, DatePicker, ShareLink, ContentUnavailableView).

## Don't change behaviour while restyling
Looks only. Danger zones: the UIKit live-formatting text view and its keyboard accessory (Done button), cursor/scroll
handling, issue badge line mapping, `DraftPreviewView` web content (must keep mirroring the real site), upload/publish logic.

## Reviewing your work
`Tools/screenshots.sh <simulator-udid>` builds for the simulator and saves every screen in light and dark to
`/tmp/devrobotics-shots/<udid>/` using demo data (`-demo -screen <name>`). Read the PNGs. A passing build is not enough.
Screens: status, lights, frames, settings, story, photo, publish, storyproblems (story editor with sample problems). Animations/haptics can only be judged on a device.

## Consistency rules (audit 2026-10-15)
These are binding for every screen; `docs/audit-2026-10-15.md` lists what was fixed against them.

**Corner radii: one scale, `DS.Radius` only.** chip 14 (icon tiles, small badges), control 20 (buttons, tappable tiles, plain
content surfaces such as grouped info/fan/service cards), card 28 (glass containers and hero cards). Never write a numeric
`cornerRadius:`. Capsule for pills, switches and timer buttons. **Concentric nesting:** a shape inside another has
radius = outer radius - padding between them (card 28 with 14 pt padding holds a chip 14; control 20 with 16 pt padding
holds nothing rounder than 4: use a plain row or `.rect(cornerRadius: DS.Radius.chip)` only with <= 6 pt inset). Exceptions
that are fixed by something else: the splash tile mirrors the app icon mask (33 pt continuous).

**Cards.** Container = `GlassCard` (28). Tappable tile = control (20). Plain content surface on pages = `Theme.surface.opacity(0.7)`
at control radius with 16 pt padding. Skeleton blocks use card radius.

**Modals (sheets).** `NavigationStack` with an inline centred title. Dismiss-only sheets: `Close` at the top-leading
(`.cancellationAction`). Sheets that edit: `Cancel` top-leading and the single committing action (`Save`/`Done`) top-trailing
(`.confirmationAction`). At most ONE primary action (`.primaryAction` button style, in the bottom safe area, or the toolbar
confirmation item, never both). Sheets use `.presentationDetents` + the system glass; no custom backgrounds.

**Destructive actions** always go through a `confirmationDialog` (`titleVisibility: .visible`):
title `Delete X?` / `Clear X?`, message says what is lost and ends with "This can't be undone." when true, one
destructive button named for the action (`Delete scene`), system Cancel. Swipe/context-menu items only set the pending target;
the dialog performs the delete. Danger colour is `Theme.danger` (never `.red`).

**Success and failure feedback.** One pattern: `.sensoryFeedback(.success|.error, trigger:)` plus a small symbol that
`.symbolEffect(.bounce, value:)` (checkmark.circle.fill / exclamationmark.triangle.fill or xmark.octagon.fill), tinted
`Theme.ok` / `Theme.warn` or `Theme.danger`. Transient results use `GlassPill`. Errors say what happened in a sentence and carry
a fix action where one exists (`Try again`, `Retry`, `Connect Tailscale` via `ConnectionBanner`).

**Loading / empty / offline.** First load of a whole screen: skeleton blocks at card radius, pulsing unless Reduce Motion.
Inline section loading: `ProgressView` in its card. Nothing to show: `ContentUnavailableView` (icon, title, description, action).
Not connected: `ConnectionBanner` at the top of the page, content below stays visible and dimmed (`.opacity(0.6)`).
Text uses a typographic ellipsis ("Sending…", never "...").

**Spacing.** Only `DS.Space` (hair 2, xs 4, s 8, m 12, l 16, xl 24, xxl 32). Page margins `l`; scrolling tab roots end with
`.padding(.bottom, DS.Space.tabBar)` so the floating tab bar never covers the last control. No bare numbers in `padding`/`spacing`.

**Icons.** SF Symbols, hierarchical rendering for decorative glyphs, `.semibold` for glyphs inside tiles, `.regular` in rows.
Fixed `.font(.system(size:))` is allowed only for symbols inside a fixed-size tile; all text uses `Theme.font(_:relativeTo:)`.

**Capitalisation.** Sentence case everywhere: buttons ("Test connection", "Save scene"), titles, section titles (the
`SectionTitle` view upper-cases visually), dialogs. Proper nouns keep capitals (Polaris, Tailscale).

**Large text.** Rows with two or more text items use `AdaptiveStack` (stacks vertically at accessibility sizes); chips are
`lineLimit(1)` + `fixedSize`; never let a word break mid-word.

**Colour.** Only `Theme.*` tokens (and the lamp colour data). `Theme.danger` replaces `.red`; data colours (lamp swatches,
kelvin gradient) are the only literal colours.
