# WeighIn iOS App

Local-first SwiftUI app for weight tracking plus contextual notes.

## Included
- 3-tab architecture: Log, Charts, Settings
- Large numeric keypad logging flow
- Notes linked to entries (or standalone)
- Past-entry logging
- CSV import/export
- Zoomable charts with trend line
- Local SQLite storage (`Application Support/WeighIn/weighin.sqlite`)
- Profile fields: birthday, gender, height, avatar path
- Daily reminder scheduling (default 7:00 AM)

## Open In Xcode
This repository contains source code in `WeighIn/`.

1. Create a new **iOS App** project in Xcode named `WeighIn`.
2. Replace generated Swift files with this repository's `WeighIn/` files.
3. Ensure these frameworks are available to target:
   - `SwiftUI`
   - `Charts`
   - `PhotosUI`
   - `UserNotifications`
   - `SQLite3` (imported in code)
4. Add `NSPhotoLibraryUsageDescription` in Info settings.
5. Run on iOS 17+ simulator/device.

## Data Schema (SQLite)
- `weight_logs(id, timestamp, weight, unit, source, note_id)`
- `notes(id, timestamp, text)`
- `app_settings(id=1, default_unit, reminder_enabled, reminder_hour, reminder_minute)`
- `user_profile(id=1, birthday, gender, height_cm, avatar_path)`
