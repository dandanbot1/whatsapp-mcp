# WhatsApp bridge supervisor

Keeps exactly one `whatsapp-bridge/whatsapp-bridge-bin` running on the box, using
the existing `store/` session. It never deletes `store/` and never starts a QR login.
The box has no systemd or cron (PID 1 is tini), so this is a plain bash supervisor.

## Paths and configuration
All paths are derived from where the scripts live (`<repo>/supervisor/`), so the defaults
below need no setup. Each can be overridden with an env var; `ctl.sh` and
`bridge-supervisor.sh` read the same ones, so export them before calling `ctl.sh`.

| Env var | Default | Used for |
|---|---|---|
| `WA_MCP_DIR` | parent of `supervisor/` (repo root) | base for the defaults below |
| `WA_BRIDGE_DIR` | `$WA_MCP_DIR/whatsapp-bridge` | where the bridge runs; `store/` lives here |
| `WA_BRIDGE_BIN` | `./whatsapp-bridge-bin` | bridge binary, relative to `WA_BRIDGE_DIR` |
| `WA_BRIDGE_LOG_DIR` | `$WA_BRIDGE_DIR/logs` | `bridge.log`, `supervisor.log` |
| `WA_SUPERVISOR_RUN_DIR` | `supervisor/run` | lock, pid and status files |
| `WA_NEEDS_LOGIN_MARKER` | `$WA_MCP_DIR/sync-state/bridge-needs-login` | needs-login marker file |
| `WA_BRIDGE_PORT` | `8080` | port probed by the health checks (the bridge itself listens on 8080) |

Requires bash, flock, setsid, pgrep, ss, curl and python3 (sqlite3 module).
`supervisor/run/`, `store/` and `logs/` are runtime state and are not committed.

## Files
- `bridge-supervisor.sh`: the supervisor loop. Don't start it directly; use `ctl.sh`.
- `ctl.sh`: `start|ensure`, `stop`, `restart`, `status`, `wait-healthy [secs]`.
- `run/supervisor.lock`: flock held by the running supervisor (single instance).
- `run/supervisor.pid`, `run/bridge.pid`: current PIDs.
- `run/status`: state (`starting|connected|reconnecting|backoff|needs-login|stopped`), PIDs, restart count.
- `../whatsapp-bridge/logs/supervisor.log`: timestamped supervisor events (start, exit, restart, rotation).
- `../whatsapp-bridge/logs/bridge.log`: bridge stdout/stderr. Each launch is marked with
  `=== [time] supervisor: starting bridge ===`.
- `../sync-state/bridge-needs-login`: marker written when a fresh QR login is needed.

## What it does
- Starts the bridge from `whatsapp-bridge/`. If another bridge process is already running,
  it stops that one with SIGTERM first, so only one instance ever runs. If an extra bridge
  shows up later (for example started by hand), it stops the extra one and reconnects its own,
  because the extra client takes over the WhatsApp session.
- Every 10 s it checks:
  - the process is still alive
  - the bridge log since launch: a disconnect (websocket error, stream error, stream end,
    "Disconnecting...", keepalive timeout) that isn't followed by "Connected to WhatsApp"
    within 180 s triggers a restart
  - while connected, port 8080 belongs to the bridge and `GET /api/download` answers 405
    (read-only probe; a hang or a lost port for 3 checks triggers a restart)
- Restarts use backoff: 5 s, 10, 20, 40, 80, 160, then capped at 300 s. The backoff resets
  after a run stays up 10 min, or after a manual `ctl.sh restart`.
- Logout or QR request ("Device logged out", "scan QR code", "device removed",
  "Client outdated", a QR code printed, or no device row in `store/whatsapp.db`):
  it stops the bridge, writes `sync-state/bridge-needs-login`, and goes idle without
  restarting. Delete the marker once the bridge has been re-paired by hand, and the
  supervisor resumes within about a minute.
- Logs are size-capped: `bridge.log` and `supervisor.log` rotate at 5 MB using copytruncate
  (`.1` to `.3` are kept).
- `/api/send` stays disabled in the binary (HTTP 403). The supervisor never sends anything.

## Reboot
Nothing on this box runs user services at boot. A short hook at the top of `~/.bashrc`
(not part of this repo) runs `ctl.sh ensure --quiet` in the background, so the first shell
after a reboot brings the supervisor back. That covers agent Shell sessions and desktop
terminals. The scheduled sync's step 0 also runs `ctl.sh ensure`, so even without the hook
the bridge comes back by the next sync at the latest. Remove the hook by deleting the block between the
`whatsapp-bridge supervisor autostart` markers in `~/.bashrc`.
Backup: `~/.bashrc.bak.before-bridge-supervisor`.

## Common commands
    S=./supervisor/ctl.sh   # from the repo root (on the box: /home/box/whatsapp-mcp)
    $S status          # exit 0 healthy, 1 supervisor down, 2 not connected yet, 3 needs login
    $S ensure          # start it if it isn't running (safe to call any time)
    $S restart         # supervisor restarts the bridge (never start a 2nd bridge by hand)
    $S wait-healthy 120
    $S stop            # stops supervisor and bridge
