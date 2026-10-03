#!/usr/bin/env bash
# Control the WhatsApp bridge supervisor.
#   ctl.sh start|ensure [--quiet]  start the supervisor if it is not running (idempotent)
#   ctl.sh stop                    stop the supervisor and the bridge it runs
#   ctl.sh restart                 ask the running supervisor to restart the bridge
#                                  (starts the supervisor if it is down)
#   ctl.sh status                  print status; exit 0 healthy, 1 supervisor down,
#                                  2 bridge not connected yet / restarting, 3 needs login
#   ctl.sh wait-healthy [secs]     wait (default 120s) until status is healthy; same exit codes
set -uo pipefail
# Same path defaults / env overrides as bridge-supervisor.sh (see README.md).
SUP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE=${WA_MCP_DIR:-$(dirname -- "$SUP_DIR")}
BRIDGE_DIR=${WA_BRIDGE_DIR:-$BASE/whatsapp-bridge}
RUN=${WA_SUPERVISOR_RUN_DIR:-$SUP_DIR/run}
LOCK=$RUN/supervisor.lock
PIDFILE=$RUN/supervisor.pid
STATUS=$RUN/status
MARKER=${WA_NEEDS_LOGIN_MARKER:-$BASE/sync-state/bridge-needs-login}
DB=$BRIDGE_DIR/store/messages.db
LOG_DIR=${WA_BRIDGE_LOG_DIR:-$BRIDGE_DIR/logs}
SUP_LOG=$LOG_DIR/supervisor.log
PORT=${WA_BRIDGE_PORT:-8080}
mkdir -p "$RUN" "$LOG_DIR"

sup_running() { [ -e "$LOCK" ] && ! flock -n "$LOCK" true 2>/dev/null; }
sup_pid() { cat "$PIDFILE" 2>/dev/null; }
quiet=0; [ "${2:-}" = "--quiet" ] && quiet=1
say() { ((quiet)) || echo "$@"; }

do_start() {
	if sup_running; then say "supervisor already running (pid $(sup_pid))"; return 0; fi
	setsid -f nohup bash "$SUP_DIR/bridge-supervisor.sh" >>"$SUP_LOG" 2>&1 </dev/null
	local i
	for ((i = 0; i < 30; i++)); do sup_running && break; sleep 0.2; done
	if sup_running; then say "supervisor started (pid $(sup_pid))"; return 0; fi
	say "supervisor failed to start; see $SUP_LOG"; return 1
}

do_status() {
	local rc state bpid port=down
	state=$(sed -n 's/^state=//p' "$STATUS" 2>/dev/null)
	bpid=$(sed -n 's/^bridge_pid=//p' "$STATUS" 2>/dev/null)
	ss -H -ltn "sport = :$PORT" 2>/dev/null | grep -q . && port=up
	if sup_running; then echo "supervisor=running pid=$(sup_pid)"; else echo "supervisor=stopped"; fi
	[ -f "$STATUS" ] && sed 's/^/  /' "$STATUS"
	echo "port_$PORT=$port"
	if [ -n "$bpid" ] && kill -0 "$bpid" 2>/dev/null; then echo "bridge_alive=yes pid=$bpid"; else echo "bridge_alive=no"; fi
	echo "messages_db_mtime=$(date -r "$DB" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null)"
	if [ -f "$MARKER" ]; then echo "needs_login=YES ($MARKER)"; sed 's/^/  /' "$MARKER"; else echo "needs_login=no"; fi
	if [ -f "$MARKER" ]; then rc=3
	elif ! sup_running; then rc=1
	elif [ "$state" = connected ] && [ "$port" = up ] && [ -n "$bpid" ] && kill -0 "$bpid" 2>/dev/null; then rc=0
	else rc=2; fi
	echo "health_exit=$rc"
	return $rc
}

case "${1:-status}" in
start | ensure) do_start ;;
stop)
	if ! sup_running; then echo "supervisor not running"; exit 0; fi
	kill -TERM "$(sup_pid)"
	for ((i = 0; i < 60; i++)); do sup_running || break; sleep 0.5; done
	sup_running && { echo "supervisor did not stop"; exit 1; }
	echo "supervisor stopped" ;;
restart)
	if sup_running; then kill -USR1 "$(sup_pid)" && echo "restart requested from supervisor pid $(sup_pid)"; else do_start; fi ;;
status) do_status ;;
wait-healthy)
	t=${2:-120}; end=$(($(date +%s) + t))
	while :; do
		out=$(do_status); rc=$?
		{ ((rc == 0)) || ((rc == 3)) || (($(date +%s) >= end)); } && break
		sleep 5
	done
	echo "$out"; exit $rc ;;
*) sed -n '2,9p' "$0"; exit 64 ;;
esac
