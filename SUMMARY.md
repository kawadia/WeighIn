# WeighIn / Weight & Reflect - Project Summary (Parallel Handoff)

## 1) Product Snapshot
- App purpose: local-first iOS weight tracking plus reflection notes for later AI-style analysis.
- Current in-app branding: **"Weigh & Reflect"** (title on main screen).
- Tabs:
  - `Log`
  - `AI Analysis` (renamed from Charts)
  - `Settings`
- Visual style: dark background + green accent theme.

## 2) Implemented UX and Behavior

### Log tab (`WeighIn/Features/Log/LogView.swift`)
- Header with brand icon (`BrandMark`) + gradient "Weigh & Reflect" title.
- Weight entry card:
  - Numeric keypad entry (`NumericKeypad`)
  - Save button beside weight display
  - Unit label uses `lbs`/`kg` (pluralized `lbs`)
- Date/time chips are shown below keypad and are editable (single flow for now/past entries).
- Notes section title: **Reflections & Notes**.
- Note saving is independent from weight saving.
- "Save Note" is explicit (no autosave), and is change-aware:
  - If unchanged from last save, it reports "No changes to save".
  - Saves by upserting the same standalone note ID during the session.
- Voice note input:
  - Hold-to-talk gesture on mic label.
  - Release ends recording automatically.
  - Live transcription preview.
- Recent Logs shows **5 most recent** entries.
- "MANUAL" source tag removed for manual entries (source tag still appears for non-manual like CSV).
- Keyboard dismissal for notes:
  - On `Save Note`
  - On tap outside text editor (`@FocusState`).

### AI Analysis tab (`WeighIn/Features/Charts/ChartsView.swift`)
- Zoomable/scrollable weight chart with selectable ranges.
- Optional 7-day trend overlay.
- Selected-point details panel with linked note text.
- "AI Analysis" section with "Coming soon" placeholder.
- Tip moved here: export JSON in Settings and analyze with a chatbot.

### Settings tab (`WeighIn/Features/Settings/SettingsView.swift`)
- Profile fields:
  - Photo
  - Birthday (set/remove control)
  - Gender
  - Height (ft/in)
- Preferences:
  - Default unit toggle (lbs default)
  - Daily reminder toggle + time (7:00 AM default)
- Data transfer:
  - Import format picker: CSV / JSON / SQLite
  - Export format picker: CSV / JSON / SQLite
- Autosave design in settings/profile:
  - Changes persist immediately via `.onChange` (no Save buttons).
- iCloud sync controls are present, but disabled in this build (see section 6).

## 3) Data & Architecture

### App layers
- Entry point: `WeighIn/WeighInApp.swift`
- Tab shell and onboarding gate: `WeighIn/RootTabView.swift`
- State + business logic: `WeighIn/Data/AppRepository.swift`
- Persistence: `WeighIn/Data/SQLiteStore.swift`
- Sync transport (currently inactive): `WeighIn/Data/CloudKitSyncService.swift`

### SQLite persistence
- Database path: `Application Support/WeighIn/weighin.sqlite`
- Core tables:
  - `weight_logs`
  - `notes`
  - `app_settings`
  - `user_profile`
- Sync-ready columns exist (e.g., `sync_state`, soft-delete flags, sync timestamps/errors).

### Import/export behavior
- CSV import is deterministic/idempotent:
  - Uses hashed key from timestamp+weight+unit to generate stable IDs.
  - Reimporting same row updates existing record rather than duplicating.
  - Empty note in reimport clears linked deterministic note.
- JSON import merges by ID through `INSERT ... ON CONFLICT` semantics in store methods.
- SQLite import performs DB-level backup/replace from chosen file.
- Export supported for CSV/JSON/SQLite.

### Notes model behavior
- Weight saves and note saves are independent.
- Standalone note save from Log tab upserts one evolving note ID during the current editing session.

## 4) Notifications
- Daily reminder scheduling via `UNUserNotificationCenter` in `WeighIn/Data/NotificationScheduler.swift`.
- Triggered by settings changes (hour/minute, enabled flag).

## 5) Testing Status
- Test target: `WeighInTests`
- Current test count: **17** tests.
- Coverage includes:
  - repository CRUD and note-link behavior
  - conversions/moving average filters
  - onboarding persistence
  - CSV parse/export
  - log view model keypad + save flows
  - newly added idempotency/roundtrip tests:
    - CSV idempotent import + note clearing
    - JSON idempotent repeated import
    - SQLite export/import roundtrip

Key test files:
- `WeighInTests/AppRepositoryTests.swift`
- `WeighInTests/CSVCodecTests.swift`
- `WeighInTests/LogViewModelTests.swift`
- `WeighInTests/ModelDefaultsTests.swift`
- `WeighInTests/TestSupport.swift`

## 6) CloudKit Status (Important)
- CloudKit sync code is implemented and modernized (iOS 15+ API blocks).
- Entitlements file includes CloudKit keys: `WeighIn/Resources/WeighIn.entitlements`.
- **Runtime feature is intentionally off by default**:
  - `AppRepository(... cloudKitSyncFeatureEnabled: Bool = false ...)`
  - `SettingsView` hard-codes `cloudSyncAvailable = false`.
- Result: app builds/runs locally without requiring active CloudKit sync flow.

## 7) Build / Run Notes

### Verified working commands
- Build:
  - `xcodebuild -project WeighIn.xcodeproj -scheme WeighIn -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug build`
- Test:
  - `xcodebuild -project WeighIn.xcodeproj -scheme WeighIn -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug test`

### Simulator caveat
- Some environments do not have `iPhone 16` runtime installed.
- Use an installed device (currently validated with `iPhone 17`).

## 8) Git / Timeline
- Branch: `main`
- Remote: `origin git@github.com:kawadia/WeighIn.git`
- Latest pushed commit: `e19b85c` (`Add repository import/export idempotency tests`)

Recent milestone commits (high signal):
- `a0c8049` CloudKit service migrated to modern APIs
- `514b353` Home layout polish + centered header
- `ff0393c` Keyboard dismiss improvements in Log notes UI
- `e19b85c` Import/export idempotency tests

## 9) Current Local Working Tree (Not Committed)
At handoff time, local uncommitted files are:
- Modified: `WeighIn.xcodeproj/project.pbxproj`
- Untracked: `WeighIn.xcodeproj/project.xcworkspace/`
- Untracked: `weigh-icon.png`
- Untracked: `weighin-icon.png`

Notes:
- `project.pbxproj` contains local signing/project ordering changes (including `DEVELOPMENT_TEAM` and reordered config blocks).
- Treat these as user-local/Xcode-generated changes; do not blindly revert unless requested.

## 10) Known Gaps / Parallel Work Opportunities
1. Clean up project metadata diffs:
- Decide whether to keep or discard current `project.pbxproj` local edits.
- Keep workspace user files out of commits if possible.

2. README refresh:
- `README.md` still says "Charts" and older feature wording; align with current "AI Analysis" and latest import/export behavior.

3. Potential dead code cleanup:
- `WeighIn/Features/Log/PastEntrySheet.swift` appears legacy after inline date/time chips flow; confirm and remove if unused.

4. Optional CloudKit activation path (future):
- Add build/config flag for `cloudKitSyncFeatureEnabled`.
- Enable `cloudSyncAvailable` conditionally.
- Verify entitlement + signing + container setup for paid Apple Developer flow.

5. UX polish candidates:
- Refine note section spacing around status/transcript.
- Add explicit confirmation toast/snackbar style feedback for saves/import/export.

## 11) Quick Orientation For Another Codex Thread
If you are starting parallel work now:
1. Run `git status --short` first and preserve user-local uncommitted project/icon files.
2. Use `iPhone 17` simulator destination for CLI runs unless user runtime set differs.
3. Start from these core files for behavior changes:
- `WeighIn/Features/Log/LogView.swift`
- `WeighIn/Features/Log/LogViewModel.swift`
- `WeighIn/Features/Settings/SettingsView.swift`
- `WeighIn/Data/AppRepository.swift`
- `WeighIn/Data/SQLiteStore.swift`
4. Extend tests in `WeighInTests/AppRepositoryTests.swift` for data-flow changes.

