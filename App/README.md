# Coal Mine Inspector — offline-first field data engine

Smart India Hackathon. Flutter (Android) mobile app for statutory coal-mine
inspections. Built on the **Transactional Outbox** pattern over SQLite so field
inspectors can capture GPS + photo evidence with no network, and everything
syncs automatically once a connection returns.

## What is in this folder

```
pubspec.yaml                                  dependencies
analysis_options.yaml                         lints
android/app/src/main/AndroidManifest.xml      permissions (location, camera, net)
lib/
  main.dart                                   entry point: warm DB, start sync, run app
  models/
    inspection.dart                           inspection record
    inspection_media.dart                     photo attached to an inspection
    sync_queue_item.dart                      outbox entry
  core/
    database/database_helper.dart             SQLite schema + atomic saveInspectionWithSync()
    services/
      location_service.dart                   GPS, permissions, mock-location detection
      camera_service.dart                     photo capture -> persistent local storage
      sync_service.dart                       background uploader (connectivity, retries, dio multipart)
  screens/
    dashboard_screen.dart                     home list + online/offline + outbox badge
    create_inspection_screen.dart             capture form (GPS chips, up to 3 photos, dropdowns)
```

## This is source only — not a runnable project yet

The surrounding Flutter project shell (Gradle files, `MainActivity`, launcher
icons, iOS folder, etc.) is **not** included. Generate it once, then keep these
files.

### One-time setup

1. Install Flutter SDK (3.19+) and Android tooling. Verify:
   ```
   flutter doctor
   ```

2. From a temp location, generate a project shell, then copy this folder's
   contents over it:
   ```
   flutter create --org in.gov.coal --project-name coal_mine_inspector coal_mine_inspector_shell
   ```
   Copy `coal_mine_inspector_shell/*` into this folder (do not overwrite the
   files listed above — keep ours), OR copy our `lib/`, `pubspec.yaml`,
   `analysis_options.yaml` and the `AndroidManifest.xml` into the generated
   shell.

3. In `android/app/build.gradle` (or `build.gradle.kts`) set:
   ```
   minSdkVersion 23        // geolocator requirement
   ```

4. Install packages:
   ```
   flutter pub get
   ```

5. Run on an emulator or a connected phone:
   ```
   flutter run
   ```

## What works after setup

- App launches to the dashboard
- Log an inspection: auto GPS fix (lat/lng/accuracy chips, mock-GPS warning),
  up to 3 camera photos, seam / shift / hazard dropdowns, severity selector
- Save commits locally in one atomic transaction and returns instantly
- Records persist and list on the dashboard with a per-row sync status
- Live online/offline indicator, outbox pending-count badge, pull-to-refresh

## What does not work yet

- **Actual upload.** There is no backend. `SyncService` POSTs a multipart
  bundle to `API_BASE_URL` (default `https://api.coalgov.example`) and will keep
  the items queued/retrying until a real endpoint exists. Point it at your API:
  ```
  flutter run --dart-define=API_BASE_URL=https://your-api.example
  ```
  Expected endpoint: `POST /api/v1/inspections/sync` accepting
  `multipart/form-data` (inspection fields + `media[]` files), returning JSON
  `{ "server_id": "...", "media": [ { "client_id": "...", "remote_url": "..." } ] }`.
- No login / auth screen (token hook in `main.dart` returns null)
- No inspection detail/edit screen, no map view
- No supervisor / regulator dashboards, no analytics
- iOS not configured; Android only
- No automated tests
