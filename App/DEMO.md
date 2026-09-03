# Coal Mine Inspector - demo runbook

The demo proves the **offline -> online sync moment**: an inspector logs a
geo-tagged, photographed observation with no network, then everything lands on
the governance dashboard the instant connectivity returns.

## One-time setup

1. **Flutter toolchain** (already installed on this machine at
   `C:\Users\User\Downloads\flutter_windows_3.47.2-stable\flutter\bin`). Add it
   to PATH for the session:
   ```powershell
   $env:Path = "C:\Users\User\Downloads\flutter_windows_3.47.2-stable\flutter\bin;" + $env:Path
   ```
2. **Phone**: enable Developer Options -> USB debugging, plug in over USB, accept
   the "Allow USB debugging?" prompt. Confirm it is seen:
   ```powershell
   flutter devices
   ```
3. **Same Wi-Fi**: the phone and this laptop must be on the same network so the
   phone can reach the mock backend.

## Running the demo

### 1. Start the mock backend (laptop)

```powershell
python mock_backend/server.py
```

- Dashboard (project it on screen): <http://localhost:8080/>
- Note the LAN IP it prints for the phone (or run `ipconfig` and take the IPv4
  of your Wi-Fi adapter), e.g. `192.168.1.34`.

### 2. Launch the app on the phone (laptop, second terminal)

```powershell
$env:Path = "C:\Users\User\Downloads\flutter_windows_3.47.2-stable\flutter\bin;" + $env:Path
flutter run --release --dart-define=API_BASE_URL=http://<LAN-IP>:8080
```

Use `--release` for a smooth demo (no debug jank). Grant the location and camera
permissions when prompted.

### 3. The script (~2.5 min)

1. **Cut the network.** Put the phone in **airplane mode** before you start.
   "Our inspector is 200 m underground. No signal, no bars."
2. Tap **Log observation**. GPS chips fill in (lat / lng / accuracy). Take a
   photo of something as the "site". Pick seam / shift / hazard. Set severity to
   **High**. Save.
   "Saved locally in one atomic transaction - instantly. The outbox now holds
   this record plus its photo."
3. Show the app bar: **Offline** chip is red, the **outbox badge** shows `1`.
   Add one or two more observations so the badge climbs.
4. Show the dashboard on screen - still empty. "Nothing has left the phone."
5. **Restore the network.** Turn airplane mode off.
   - The connectivity listener fires a sync automatically, **or** tap the
     **Sync now** button in the app bar.
   - Watch the badge drain to `0`, the chip flip to green **Online**, and the
     "Sync complete - N sent" snackbar.
6. **Cut to the dashboard.** The inspections appear on the map at their captured
   coordinates, colour-coded by severity, each with its photo, server id, mine,
   and inspector. "No paper. No re-keying. Timestamped, geo-tagged, and routed
   the moment a connection came back."
7. Optional kicker: kill the backend, log another observation offline, restart
   the backend - it still syncs. Re-run a sync - the dashboard shows
   `re-synced x1`, not a duplicate (idempotent on the client-generated UUID).

## Fallbacks (venue Wi-Fi is always hostile)

- Use your **phone's hotspot**; run the laptop on it and point `API_BASE_URL` at
  the laptop's hotspot IP.
- Keep a **screen recording** of a clean run as backup.
- The **Sync now** button means you never depend on the OS firing the
  connectivity event on stage - you control the moment.

## What the judges should take away

| Capability in the problem statement | Where it shows |
|---|---|
| Geo-tagged, time-stamped field reporting, offline | Every observation: lat/lng/accuracy + GNSS timestamp, captured in airplane mode |
| Photo / document evidence | Up to 3 photos per observation, stored locally, uploaded on sync |
| Works offline underground, syncs on reconnect | The whole script |
| No data loss / no duplication | Transactional outbox + idempotent UUID upsert (`re-synced xN`) |
| Tamper signal | Mock-GPS detection flag surfaced on device and dashboard |
| Dashboard for officials | The control-room view (mock stand-in for the real platform) |
| Scalable across mines / subsidiaries | `mine_code` + `inspector_id` on every record; backend is stateless per request |
