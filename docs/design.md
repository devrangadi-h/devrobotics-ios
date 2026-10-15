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
