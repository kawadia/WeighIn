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
The repository includes `WeighIn.xcodeproj`.

1. Open `WeighIn.xcodeproj` in Xcode.
2. Select the `WeighIn` scheme.
3. Run on iOS 17+ simulator/device.

## Data Schema (SQLite)
- `weight_logs(id, timestamp, weight, unit, source, note_id)`
- `notes(id, timestamp, text)`
- `app_settings(id=1, default_unit, reminder_enabled, reminder_hour, reminder_minute)`
- `user_profile(id=1, birthday, gender, height_cm, avatar_path)`
