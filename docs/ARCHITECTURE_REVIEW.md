# WeighIn Architecture Review

## Scope
This review is based on a static code walkthrough of the current app composition, data layer, feature layer, and integration boundaries.

## Current architecture snapshot

### What is working well
- The app is already organized into recognizable folders (`Data`, `Models`, `Features`, `Utilities`) and uses SwiftUI + observable state patterns consistently.
- Core flows are local-first and deterministic (SQLite-backed persistence, import/export, note/log linking).
- The repository constructor already supports some dependency injection (`SQLiteStore`, reminder scheduler, `UserDefaults`, optional sync service), which provides a foundation for future modularization.

### Main architectural pressure points
1. **`AppRepository` has become a “god object.”**
   - It currently owns app state, CRUD behavior, import/export, backup orchestration, CloudKit sync loops, CSV key generation, Apple Health ZIP/XML parsing, and chart helper logic.
   - This creates high change-coupling and broad blast radius for regressions.

2. **`SQLiteStore` is also monolithic.**
   - It handles schema/migrations, all SQL operations, sync record state transitions, snapshot/backup support, and merge behaviors in one class.
   - The data access layer is difficult to reason about and harder to unit-test in isolation by use case.

3. **Feature boundaries are soft.**
   - Views access `AppRepository` directly via `@EnvironmentObject`, and business logic is split unevenly between views, `LogViewModel`, and repository methods.
   - `RootTabView` contains onboarding logic and sheet composition directly, and `ChartsView.swift` includes `AIAnalysisView`, suggesting feature packaging drift.

4. **Main-actor concentration may hide performance costs.**
   - `AppRepository` is `@MainActor`, while many operations include disk I/O or heavy transforms (imports, parsing, sync prep).
   - Some background work exists (backup worker), but there is no consistent strategy for moving expensive work off the main actor and returning only UI-safe state updates.

## Suggested simplifications

### 1) Split `AppRepository` by capability (highest ROI)
Create small, focused collaborators and keep one thin facade for UI composition.

Suggested cut lines:
- `LogRepository` / `LogService`: weight+note CRUD and conversion.
- `SettingsService`: app settings/profile/reminder scheduling.
- `SyncCoordinator`: queue/sync loop + retry policy.
- `BackupService`: bookmark storage + daily/manual backup.
- `ImportExportService`: CSV/JSON/SQLite/Apple Health imports and exports.
- `TrendService`: range filtering + moving average.

`AppRepository` can remain as a compatibility facade at first and delegate to these collaborators. That enables incremental migration without breaking existing UI screens.

### 2) Extract Apple Health and ZIP parsing into dedicated files
Move ZIP parsing and XML parsing from `AppRepository.swift` into separate files/types:
- `AppleHealthImportParser.swift`
- `ZIPExportExtractor.swift`

Benefits:
- Smaller compile units.
- Better focused tests.
- Lower cognitive overhead in repository review and maintenance.

### 3) Define narrow protocols at the feature boundary
Introduce protocols consumed by view models, for example:
- `LoggingUseCase`
- `SettingsUseCase`
- `ChartsUseCase`

Then inject concrete implementations in `WeighInApp`. This keeps views and feature VMs independent from full repository surface area and improves test ergonomics.

### 4) Normalize asynchronous work strategy
Adopt a consistent policy:
- disk/network/parsing on background executors/actors,
- publish minimal state mutations on `@MainActor`.

A practical version: keep a `MainActor` view-facing store, but perform import/sync preparation and parsing in dedicated actors (`ImportActor`, `SyncActor`) before updating published state.

### 5) Repackage features by domain
Reorganize into a domain-first layout:
- `Features/Log/*`
- `Features/Trends/*`
- `Features/Analysis/*`
- `Features/Settings/*`
- `Core/Data/*`, `Core/Sync/*`, `Core/Backup/*`, etc.

This should include moving `AIAnalysisView` out of `ChartsView.swift` and extracting onboarding flow from `RootTabView.swift` into its own feature module.

### 6) Unify error modeling
Current error handling mostly maps to user-facing strings on the repository. Introduce typed error channels per domain (`SyncError`, `ImportError`, `BackupError`, etc.) and centralize UI message formatting in one place.

## Recommended phased migration plan

### Phase 1 (safe refactors, no behavior change)
- Extract Apple Health/ZIP code into dedicated files.
- Extract `TrendService` (filter + moving average).
- Introduce use-case protocols and adapt existing repository to conform.

### Phase 2 (moderate change)
- Move sync loop into `SyncCoordinator`.
- Move backup logic/bookmark preference handling into `BackupService`.
- Keep `AppRepository` as orchestrator/facade.

### Phase 3 (bigger simplification)
- Break `SQLiteStore` into focused gateways/DAOs (`LogStore`, `NoteStore`, `SettingsStore`, `SyncStore`).
- Convert high-cost import/sync preparation tasks to background actors.

### Phase 4 (feature modularization)
- Split feature modules and align file ownership (e.g., analysis views under `Features/Analysis`).
- Trim `RootTabView` into navigation shell only.

## Prioritized improvement checklist
- [ ] Create `TrendService` and remove chart math from `AppRepository`.
- [ ] Extract Apple Health + ZIP parsing out of `AppRepository`.
- [ ] Add use-case protocols and inject to feature view models.
- [ ] Move sync orchestration to `SyncCoordinator`.
- [ ] Move backup behavior to `BackupService`.
- [ ] Split `SQLiteStore` by aggregate.
- [ ] Domain-packaging cleanup (`AIAnalysisView`, onboarding flow separation).

## Expected outcomes
If the above is implemented incrementally, you should get:
- smaller files and reduced merge conflict frequency,
- faster onboarding for contributors,
- clearer ownership per feature,
- easier unit/integration testing,
- lower regression risk when changing sync/import/backup logic.
