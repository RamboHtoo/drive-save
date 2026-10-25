> The staged redesign below is a historical implementation record. The subsequent UI simplification keeps its visual system and removes redundant content: Home has no league promotion or recent trips; History opens to the archive; Profile is compact; technical controls are under Advanced Settings; receipt assumptions expand on demand. See README for current navigation.

# Drive Save visual system

## Direction

An automotive instrument panel crossed with an editorial race classification and an itemized financial document. The [Wonder Games site](https://wondermakers.games/) and its [Awwwards entry](https://www.awwwards.com/sites/wonder-games) were inspected in the browser. The reference informed contrast, deliberate typographic scale, and a game-like hierarchy; no reference assets, logo, layouts, or animation sequences are used. All graphic work is native SwiftUI Canvas/Shapes/Charts. System fonts require no added font license or dependency.

## Tokens and accessibility

- Carbon `#0A0A0A`; acid `#D4FB08`; warm white `#F1F0E8`; signal `#777A73`.
- Signal gray is used for graphic marks. Small secondary text uses the brighter `#ADAFA6` companion for contrast.
- Condensed black system display type, semibold financial figures, regular readable body copy, monospaced technical captions.
- Display values scale with Dynamic Type. Rows reflow vertically; long assumptions wrap; plots have accessible sample values. Decorative paths are hidden from VoiceOver.
- Acid identifies an action, selected navigation item, current driver, or plotted data. No gradients, glow, glass, imported art, or card grid.
- Sections are divided by one-point rules. Primary buttons are rectangular and at least 48 points high. No autoplay graphics or looping animations.
- Springs/number transitions are confined to review screens and controls, respect Reduce Motion, and never animate live recording measurements.

## Verified stages

1. **Home and reusable tokens — passed build/UI checks before stage 2:** one dominant explicitly simulated/pending financial value; record action; original lane illustration or timestamped GPS sample chart; real league position when known; recent trip links.
2. **Navigation and Leagues — passed build/UI checks before stage 3:** safe-area bottom rail on root destinations only; championship standings with large rank numbers, current-driver stripe and reflowing rows; all existing create/join/copy/share/refresh and under-four-member states preserved.
3. **Receipt — passed build/UI checks before final regression review:** itemized editorial document with a large cost/pending state, provenance, readable financial assumptions, measurement quality, and a timestamped event timeline only when records exist. Server placeholder pricing is disclosed above its amount.

Each stage is built and checked before the next. Recording, authentication, API contracts, scoring, persistence, vehicle selection, and trip serialization remain owned by their existing services/models.

## Data honesty

Home's financial aggregate remains based on the app's sample trips and is never presented as measured waste or achieved savings. Missing financial data uses an em dash or pending state. A lane illustration is labeled as artwork without live data. GPS charts plot observations as points without joining gaps. Simulated GPS keeps its simulation label. Demo standings are fictional; remote standings and current position come from the existing backend models. Walking tests do not receive driving events or costs.

## Scope

Home, Leagues and Trip Receipt receive composed layouts. History, onboarding, Profile, vehicle/settings and recording inherit the shared palette, type and ruled sections, but their complete layouts are not redesigned in this pass. Live recording remains stationary and safety-focused.

## Modified files

Added:
- `DriveAndSave/Components/PrimaryNavigation.swift` — intrinsic-height root rail with full-width accessibility-size navigation.
- `DriveAndSave/Components/TelemetryGraphic.swift` — original Canvas lane study and actual timestamped GPS observations.
- `DriveAndSave/Components/ReceiptDocument.swift` — notched receipt paper, responsive ledger rows, and the existing backend receipt rendered with all response fields.
- `DriveAndSave/Components/TripTimeline.swift` — observed speed and candidate-event timelines, with explicit missing-data states.
- `DriveAndSaveUITests/DesignFlowTests.swift` — Home, Leagues, receipt and accessibility-size checks with screenshots.
- `Docs/VisualDesign.md` — this design and implementation record.

Updated:
- `DriveAndSave/Components/DesignSystem.swift` — palette, scaled display/financial typography, contrast-safe button style, ruled surfaces, compact trip rows.
- `DriveAndSave/DriveAndSaveApp.swift` — one navigation stack, root destinations and safe-area rail; authentication restoration remains unchanged.
- `DriveAndSave/Views/HomeView.swift` — instrument-panel composition and opaque intrinsic-height masthead.
- `DriveAndSave/Views/CrewLeaderboardView.swift` — championship composition/current driver/member qualification; form and invite functionality preserved.
- `DriveAndSave/Views/TripReceiptView.swift` — local document and observation timelines, retaining quality notes, fuel assumptions and upload/export actions.
- `DriveAndSave/Views/APISettingsView.swift` — uses the extracted backend receipt document and contrast-safe primary button styling.
- `DriveAndSave/Views/ProfileView.swift` — explicit Done-key dismissal and shared primary-button styling.
- `DriveAndSave/Views/TripHistoryView.swift` — stable accessible trip-link identifiers only; layout remains for a later pass.
- `DriveAndSave/Views/TripRecordingView.swift` — shared high-contrast primary buttons and safety copy consistent with focused navigation. The sensor service is unchanged. Saved-trip state is separated from the receipt navigation binding so Back returns to Trip saved and then Home without trapping the user.
- `DriveAndSaveUITests/RecordingFlowTests.swift`, `DriveAndSaveUITests/OnboardingTests.swift` — root-navigation helpers, exact control scrolling, focused recording checks and screenshot attachments.
- `README.md` — current navigation/design guidance.

No model, service, API contract, scoring, backend, or analytics source files changed.

## Remaining visual scope and test limits

History, welcome onboarding, Profile, vehicle settings and developer tools retain their previous compositions while inheriting the palette, ruled sections and button styling. Some of their older rounded display fonts and native control styles remain. They are not represented as fully redesigned. The current pass does not validate physical driving-event accuracy, financial-model accuracy, or uninterrupted background recording. Home financial totals remain simulated. Live API mutation tests are unnecessary for a presentation-only change and are not rerun here; mocked contract/auth/upload tests cover the unchanged clients.

## Final verification

- Each of the three implementation stages compiled and passed its focused UI checks before the next stage began.
- Final signed simulator builds succeeded on iPhone 17e and iPhone 17 Pro Max (iOS 26.4 runtime; iOS 17+ deployment target).
- The full 11-test offline UI suite passed on iPhone 17e. The additional accessibility XXXL test passed on Pro Max with adaptive full-width navigation labels, a sticky opaque Home masthead, and the full footer above navigation: 12 distinct UI checks in total.
- The saved-receipt return path and Walking Test persistence/filtering were rechecked on Pro Max after the navigation-state fix and passed.
- 34 model/GPS/persistence checks and 34 backend contract/auth/serialization/invitation checks passed.
- Checked screenshots of Home, championship standings/current-driver state, local and placeholder server receipts, observation timelines and largest-size navigation. Native prominent buttons were replaced with the shared dark-on-lime style where needed for contrast. Reduce Motion is respected by the custom spring/number transitions; a physical-device VoiceOver/Reduce Motion audit remains a manual follow-up.
- Root-only navigation, create/invite, registration persistence/confirmed reset, vehicle/replay upload, receipt assumptions, simulated recording/local history, denied location, interruption safety, and Walking Test exclusion remain covered.

## Preview files

These are app screenshots from isolated offline test accounts. Financial values and standings in them are explicitly demo/placeholder data. The timeline uses the app’s simulated recording source, not real driving.

- [Home](DesignPreviews/home.png)
- [Leagues](DesignPreviews/leagues.png)
- [Current driver / under four members](DesignPreviews/current-driver.png)
- [Local receipt](DesignPreviews/receipt.png)
- [Placeholder server receipt](DesignPreviews/placeholder-receipt.png)
- [Simulated observation timeline](DesignPreviews/timeline.png)

The PNGs under `Docs/DesignPreviews` are documentation artifacts, outside the app target. They are not bundled app assets.

## UI simplification verification (2026-10-24)

- Final signed simulator build and all 12 offline UI tests passed on iPhone 17 Pro Max (iOS 26.4), including accessibility XXXL scrolling, registration/Keychain persistence/confirmed reset, league creation/invites, vehicle/replay/placeholder receipt, receipt disclosures and advanced details, simulated trip persistence, denied location, foreground interruptions, Walking Test filtering/persistence and unchanged standings.
- iPhone 17e also passed Home, league, account, vehicle/replay, all four recording, footer-clearance, and walking flows. An initial receipt test incorrectly expected export from a legacy demo without upload metadata; the corrected test verifies that no fabricated export is offered and passed in the final suite.
- 34 model/GPS/persistence checks and 34 backend contract/auth/serialization/invitation checks passed.
- Reviewed final Home, Leagues, History, local receipt, placeholder pricing, and footer screenshots. Updated documentation previews, including [History](DesignPreviews/history.png).
- No model, sensor service, API client, scoring, backend, or analytics source changed. No production mutations were run for this UI cleanup. Physical-device driving accuracy remains outside these simulator UI checks.
