# Roon Bridge on CoreELEC

One-shot installer for [Roon Bridge](https://www.roon.com/endpoints/roon-b/) on
**CoreELEC / LibreELEC (Kodi) ARM set-top boxes** — Ugoos, Mecool, Amlogic
S905x / S912 / S922 / S928, etc.

Roon's official installer
(`roonbridge-installer-linuxarmv8.sh`) does **not** work on CoreELEC out of the
box. This script adapts the installation to CoreELEC's three hard constraints:

| Constraint | Why it breaks the official installer | This script's fix |
|---|---|---|
| `/opt`, `/usr`, `/etc` are read-only squashfs | Installer hard-codes `/opt/RoonBridge` and `/etc/systemd/system` | Program → `/storage/RoonBridge`, unit → `/storage/.config/system.d/` (CoreELEC maps it into systemd) |
| `/var` is tmpfs, wiped on reboot | Official `ROON_DATAROOT=/var/roon` loses the device identity every boot | `ROON_DATAROOT` / `ROON_ID_DIR` → `/storage/var/roon` (persistent) |
| No `libicu` packages | .NET runtime `check.sh` reports libicu FAILED | `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` (supported natively by Roon's check; fine for a pure-audio endpoint) |

## Quick start

Run **on the box, as root**:

```sh
scp install-roonbridge-coreelec.sh root@<BOX-IP>:/tmp/
ssh root@<BOX-IP> 'sh /tmp/install-roonbridge-coreelec.sh armv8'
```

Architecture argument (first arg):

- `armv8` — default; use this on 64-bit Amlogic (S922X/S905X4/S928X …). Verified: `RoonBridge_linuxarmv8.tar.bz2`, version 207101683 (2.71).
- `armv7hf` — 32-bit ARM hard-float boxes (S905/S912 with 32-bit userland).
- `aarch64` — accepted for completeness; as of 2026-10 there is no aarch64 build on Roon's download host, and the armv8 build is the correct one for 64-bit Amlogic.

## What the script does

1. Preflight: root, systemd, `/storage` writable, CoreELEC unit dir writable.
2. Downloads `https://download.roonlabs.net/builds/RoonBridge_linux<arch>.tar.bz2` (skipped if already present).
3. Extracts to `/storage/RoonBridge`, runs Roon's own `check.sh --preflight` with invariant globalization.
4. Creates persistent data dirs under `/storage/var/roon`.
5. Writes `/storage/.config/system.d/roonbridge.service` (mirrors Roon's official unit, with CoreELEC paths and env).
6. `daemon-reload` → `enable` → `start`, waits, verifies `active` and that the bridge registered with Roon's cloud (`discovery.roonlabs.net` → 200, `registered 1 devices`).
7. Prints the device `unique_id` and next steps.

Idempotent: re-running reuses the existing `unique_id` and does not re-register a
duplicate device.

## Verifying success

Beyond `systemctl is-active roonbridge` == `active`, the logs must show cloud
registration (not just "process started"):

```
POST to https://discovery.roonlabs.net/1/register ... status code: 200
registered 1 devices, 1 services
connected to push2 connector at ws://push-connector-...
```

Check:

```sh
systemctl status roonbridge
journalctl -u roonbridge --no-pager | tail -40
tail -40 /storage/var/roon/RoonBridge/Logs/RoonBridge_log.txt
```

Then open the Roon app → Settings → Devices and the box should appear.
Reboot once to confirm the service comes back automatically with the same
`unique_id`.

## Uninstall

```sh
systemctl disable --now roonbridge
rm -f /storage/.config/system.d/roonbridge.service
systemctl daemon-reload
rm -rf /storage/RoonBridge /storage/var/roon /storage/RoonBridge_linux*.tar.bz2
```

## Notes

- Boxes typically reach `download.roonlabs.net` directly (no proxy needed), ~1–1.5 MB/s.
- Clean up the ~13 MB tarball after install if you want space back:
  `rm -f /storage/RoonBridge_linux*.tar.bz2`
- The unit runs `ExecStart=/storage/RoonBridge/start.sh` (not the raw binary) —
  start.sh performs Roon's preflight and self-update re-exec.

## License

MIT
