#!/usr/bin/env bash
# WhatsApp bridge supervisor: keeps exactly one ./whatsapp-bridge-bin running,
# restarts it with backoff when it exits or stays disconnected, and stops
# (writing a needs-login marker) on logout / QR-pairing requests.
# Start/stop it with ctl.sh, not directly.
set -uo pipefail

# Paths default to this script's location (<repo>/supervisor); override with env vars.
# ctl.sh uses the same variables, so set them for both (export them).
SUP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE=${WA_MCP_DIR:-$(dirname -- "$SUP_DIR")}             # repo root
BRIDGE_DIR=${WA_BRIDGE_DIR:-$BASE/whatsapp-bridge}
BIN=${WA_BRIDGE_BIN:-./whatsapp-bridge-bin}              # relative to BRIDGE_DIR
RUN=${WA_SUPERVISOR_RUN_DIR:-$SUP_DIR/run}
LOG_DIR=${WA_BRIDGE_LOG_DIR:-$BRIDGE_DIR/logs}
BRIDGE_LOG=$LOG_DIR/bridge.log
SUP_LOG=$LOG_DIR/supervisor.log
MARKER=${WA_NEEDS_LOGIN_MARKER:-$BASE/sync-state/bridge-needs-login}
LOCK=$RUN/supervisor.lock
PIDFILE=$RUN/supervisor.pid
BRIDGE_PIDFILE=$RUN/bridge.pid
STATUS=$RUN/status
PORT=${WA_BRIDGE_PORT:-8080}  # port the bridge's REST API listens on (only used for health checks)

CHECK_INTERVAL=10          # seconds between health checks
DISCONNECT_GRACE=180       # restart if not (re)connected for this long
PORT_MISS_LIMIT=3          # consecutive checks with port 8080 down (while connected)
BACKOFF_MIN=5
BACKOFF_MAX=300
HEALTHY_RESET=600          # a run connected this long resets the backoff
LOG_MAX_BYTES=$((5 * 1024 * 1024))
LOG_KEEP=3

mkdir -p "$RUN" "$LOG_DIR" "$(dirname "$MARKER")"

ts() { date '+%Y-%m-%d %H:%M:%S %z'; }
log() { printf '[%s] [supervisor %s] %s\n' "$(ts)" "$$" "$*" >>"$SUP_LOG"; }

rotate() { # copytruncate rotation, safe with the bridge's O_APPEND fd
	local f=$1 size i
	size=$(stat -c %s "$f" 2>/dev/null || echo 0)
	((size > LOG_MAX_BYTES)) || return 1
	for ((i = LOG_KEEP - 1; i >= 1; i--)); do
		[ -f "$f.$i" ] && mv -f "$f.$i" "$f.$((i + 1))"
	done
	cp -f "$f" "$f.1" && : >"$f"
	return 0
}

write_status() { # state detail
	{
		echo "state=$1"
		echo "detail=${2:-}"
		echo "updated=$(ts)"
		echo "supervisor_pid=$$"
		echo "bridge_pid=${child:-}"
		echo "bridge_started=${child_started_h:-}"
		echo "restarts=$restarts"
		echo "backoff_s=$backoff"
	} >"$STATUS.tmp" && mv -f "$STATUS.tmp" "$STATUS"
}

nap() { sleep "$1" 9>&- & local p=$!; wait "$p" 2>/dev/null; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 0; }

bridge_pids() { # every running whatsapp-bridge-bin (matched by comm + exe, not cmdline)
	local p exe
	for p in $(pgrep -u "$(id -u)" -x whatsapp-bridge 2>/dev/null); do
		exe=$(readlink "/proc/$p/exe" 2>/dev/null || true)
		case "$exe" in *whatsapp-bridge-bin*) echo "$p" ;; esac
	done
}

port_up() { ss -H -ltn "sport = :$PORT" 2>/dev/null | grep -q .; }
port_owned_by_child() { ss -H -ltnp "sport = :$PORT" 2>/dev/null | grep -q "pid=$child,"; }
# liveness: GET /api/download only answers 405 (POST-only); it never touches WhatsApp
http_alive() { local c; c=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:$PORT/api/download" 2>/dev/null); [ "$c" = 405 ]; }

has_session() { # 0 = saved device present, 1 = definitely none, 0 on unknown
	[ -f "$BRIDGE_DIR/store/whatsapp.db" ] || return 1
	local n
	n=$(python3 - "$BRIDGE_DIR/store/whatsapp.db" 2>/dev/null <<'PY'
import sqlite3, sys
c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=5)
print(c.execute("select count(*) from whatsmeow_device").fetchone()[0])
PY
)
	[ "$n" = "0" ] && return 1
	return 0
}

write_marker() { # reason, evidence
	{
		echo "WhatsApp bridge needs a fresh login (QR pairing) - supervisor stopped restarting it."
		echo "when=$(ts)"
		echo "reason=$1"
		echo "evidence=${2:-}"
		echo "fix: re-pair the bridge by hand (see $SUP_DIR/README.md), then delete this file."
	} >"$MARKER"
	log "NEEDS LOGIN: $1 :: ${2:-} -> wrote $MARKER, not restarting"
}

stop_child() { # reason
	[ -n "${child:-}" ] || return 0
	if kill -0 "$child" 2>/dev/null; then
		log "stopping bridge pid=$child ($1)"
		kill -TERM "$child" 2>/dev/null
		local i
		for ((i = 0; i < 30; i++)); do kill -0 "$child" 2>/dev/null || break; sleep 0.5; done
		if kill -0 "$child" 2>/dev/null; then
			log "bridge pid=$child ignored SIGTERM, sending SIGKILL"
			kill -KILL "$child" 2>/dev/null
		fi
	fi
	wait "$child" 2>/dev/null
	child=""
	rm -f "$BRIDGE_PIDFILE"
}

kill_strays() { # make sure no other bridge instance is running before we launch ours
	local p i
	for p in $(bridge_pids); do
		[ "$p" = "${child:-}" ] && continue
		log "found bridge not started by this supervisor (pid=$p); stopping it with SIGTERM so only one instance runs"
		kill -TERM "$p" 2>/dev/null
		for ((i = 0; i < 30; i++)); do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
		kill -0 "$p" 2>/dev/null && { log "pid=$p still alive, SIGKILL"; kill -KILL "$p" 2>/dev/null; sleep 1; }
	done
	for ((i = 0; i < 20; i++)); do port_up || return 0; sleep 0.5; done
	log "WARNING: port $PORT still in use by another process after stopping strays"
}

scan_log() { # parse bridge.log lines written since our launch
	local size chunk line
	size=$(stat -c %s "$BRIDGE_LOG" 2>/dev/null || echo 0)
	((size < offset)) && offset=0
	((size == offset)) && return 0
	chunk=$(tail -c +"$((offset + 1))" "$BRIDGE_LOG" | head -c "$((size - offset))" | sed 's/\x1b\[[0-9;]*m//g')
	offset=$size
	while IFS= read -r line; do
		# only look at whatsmeow/bridge status lines, never at message text
		case "$line" in
		"Scan this QR code"* | "QR code string written"* | *"Timeout waiting for QR"*)
			fatal="QR pairing requested"; fatal_line=$line; continue ;;
		"Disconnecting..."*) [ -z "$disc_since" ] && disc_since=$(date +%s); connected=0; continue ;;
		"✓ Connected to WhatsApp"*) connected=1; disc_since=""; ever_connected=1; continue ;;
		"REST API server error"*) rest_error=$line; continue ;;
		esac
		[[ "$line" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}\ \[ ]] || continue
		case "$line" in *"Stored message"* | *"Message content"* | *"Using "*name* | *"Getting name"*) continue ;; esac
		case "$line" in
		*"Device logged out"* | *"scan QR code"* | *"device removed"* | *"Client outdated"* | *"TemporaryBan"* | *"temporarily banned"* | *"logging out"* | *"LoggedOut"*)
			fatal="logged out"; fatal_line=$line ;;
		*"] Connected to WhatsApp"* | *"Keepalive restored"*)
			connected=1; disc_since=""; ever_connected=1 ;;
		*"replaced stream error"* | *"StreamReplaced"*)
			log "WARNING: WhatsApp says the session was replaced by another client: $line"
			connected=0; [ -z "$disc_since" ] && disc_since=$(date +%s) ;;
		*"Error reading from websocket"* | *"stream error"* | *"stream end frame"* | *"Failed to connect"* | *"Failed to establish stable connection"* | *"Keepalive timed out"* | *"Error sending close"* | *"websocket"*closed* | *"Disconnected"*)
			connected=0; [ -z "$disc_since" ] && disc_since=$(date +%s) ;;
		esac
	done <<<"$chunk"
}

# ---------------------------------------------------------------- main
exec 9>"$LOCK"
if ! flock -n 9; then
	echo "bridge supervisor already running (pid $(cat "$PIDFILE" 2>/dev/null))" >&2
	exit 0
fi
echo $$ >"$PIDFILE"

stopping=0 restart_req=0
trap 'stopping=1' TERM INT
trap 'restart_req=1' USR1
child="" child_started=0 child_started_h="" restarts=0 backoff=$BACKOFF_MIN
offset=0 connected=0 ever_connected=0 disc_since="" fatal="" fatal_line="" rest_error=""
first_launch=1

log "supervisor started (lock $LOCK)"

while ((stopping == 0)); do
	# ---- needs-login: idle until the marker is removed
	if [ -f "$MARKER" ]; then
		write_status needs-login "marker present: $MARKER"
		nap 60
		if [ ! -f "$MARKER" ]; then log "needs-login marker cleared, resuming"; backoff=$BACKOFF_MIN; first_launch=1; fi
		continue
	fi
	if ! has_session; then
		write_marker "no saved WhatsApp session in store/whatsapp.db (starting would only show a QR code)" ""
		continue
	fi

	# ---- backoff before a relaunch
	if ((first_launch == 0)); then
		write_status backoff "waiting ${backoff}s before restart"
		log "restarting bridge in ${backoff}s"
		nap "$backoff"
		((stopping)) && break
		backoff=$((backoff * 2)); ((backoff > BACKOFF_MAX)) && backoff=$BACKOFF_MAX
	fi
	first_launch=0
	restart_req=0

	# ---- launch
	kill_strays
	rotate "$BRIDGE_LOG" && log "rotated bridge.log"
	offset=$(stat -c %s "$BRIDGE_LOG" 2>/dev/null || echo 0)
	connected=0 ever_connected=0 disc_since=$(date +%s) fatal="" fatal_line="" rest_error="" port_miss=0
	printf '=== [%s] supervisor: starting bridge (restart #%s) ===\n' "$(ts)" "$restarts" >>"$BRIDGE_LOG"
	offset=$(stat -c %s "$BRIDGE_LOG" 2>/dev/null || echo 0)
	cd "$BRIDGE_DIR" || { log "cannot cd $BRIDGE_DIR"; nap 60; continue; }
	"$BIN" >>"$BRIDGE_LOG" 2>&1 </dev/null 9>&- &
	child=$!
	child_started=$(date +%s)
	child_started_h=$(ts)
	echo "$child" >"$BRIDGE_PIDFILE"
	log "launched bridge pid=$child"
	write_status starting "launched pid=$child"

	# ---- monitor
	while ((stopping == 0)); do
		nap "$CHECK_INTERVAL"
		((stopping)) && break
		rotate "$SUP_LOG" && log "rotated supervisor.log"
		if rotate "$BRIDGE_LOG"; then offset=0; log "rotated bridge.log"; fi

		if ! kill -0 "$child" 2>/dev/null; then
			wait "$child" 2>/dev/null; rc=$?
			scan_log
			log "bridge pid=$child exited (status $rc) after $(($(date +%s) - child_started))s"
			child=""; rm -f "$BRIDGE_PIDFILE"
			break
		fi
		scan_log
		now=$(date +%s)
		for sp in $(bridge_pids); do # someone started a 2nd bridge by hand: stop it, keep ours
			[ "$sp" = "$child" ] && continue
			log "WARNING: extra bridge instance pid=$sp found while pid=$child runs; stopping the extra one (use ctl.sh restart instead of starting the binary)"
			kill -TERM "$sp" 2>/dev/null
			restart_req=1 # the extra client has probably replaced our session; reconnect ours now
		done

		if [ -n "$fatal" ]; then
			stop_child "fatal: $fatal"
			write_marker "$fatal" "$fatal_line"
			break
		fi
		if ((restart_req)); then
			log "restart requested (ctl.sh restart or extra-instance cleanup)"
			stop_child "restart requested"; backoff=$BACKOFF_MIN; first_launch=1
			break
		fi
		if [ -n "$rest_error" ] && port_owned_by_child; then
			rest_error="" # that error came from some other process sharing bridge.log; ours serves the port
		fi
		if [ -n "$rest_error" ]; then
			log "REST server failed to start: $rest_error"
			stop_child "REST API not serving"
			break
		fi
		if ((connected == 0)) && [ -n "$disc_since" ] && ((now - disc_since > DISCONNECT_GRACE)); then
			log "bridge pid=$child not connected to WhatsApp for $((now - disc_since))s (> ${DISCONNECT_GRACE}s), restarting"
			stop_child "stuck disconnected"
			break
		fi
		if ((connected == 1)); then
			if port_owned_by_child && http_alive; then
				port_miss=0
			else
				port_miss=$((port_miss + 1))
				if ((port_miss >= PORT_MISS_LIMIT)); then
					log "port $PORT not served/answering by bridge pid=$child for $port_miss checks, restarting"
					stop_child "port $PORT down"
					break
				fi
			fi
			if ((now - child_started >= HEALTHY_RESET)) && ((backoff != BACKOFF_MIN)); then
				backoff=$BACKOFF_MIN
				log "bridge healthy for ${HEALTHY_RESET}s, backoff reset to ${BACKOFF_MIN}s"
			fi
			write_status connected "pid=$child port=$PORT"
		else
			write_status reconnecting "pid=$child disconnected for $((now - ${disc_since:-$now}))s"
		fi
	done

	((stopping)) && break
	[ -f "$MARKER" ] && continue
	# a run that was connected for a long time restarts quickly
	if ((child_started > 0)) && (($(date +%s) - child_started >= HEALTHY_RESET)) && ((ever_connected)); then backoff=$BACKOFF_MIN; fi
	restarts=$((restarts + 1))
done

stop_child "supervisor stopping"
write_status stopped "supervisor exited"
log "supervisor stopped"
rm -f "$PIDFILE"
exit 0
