#!/bin/bash
# OpenClaw skill lifecycle: status
# Read-only status summary for the deployed runtime service.

DEPLOY_DIR="${1:-${DEPLOY_DIR:-$HOME/dingtalk-auto-approve}}"
ENV_FILE="$DEPLOY_DIR/.env"
OS_NAME="$(uname -s)"

if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

SERVICE="${SERVICE_NAME:-dingtalk-bot.service}"
LAUNCHD_LABEL="${LAUNCHD_LABEL:-com.gomoai.dingtalk-auto-approve}"
HEARTBEAT_FILE="${HEARTBEAT_FILE:-$DEPLOY_DIR/.bot_heartbeat}"
HEARTBEAT_MAX_AGE="${HEARTBEAT_MAX_AGE:-180}"

section() {
    echo ""
    echo "== $1 =="
}

heartbeat_age() {
    python3 - "$HEARTBEAT_FILE" << 'PYEOF'
import os
import sys
import time

path = sys.argv[1]
if not os.path.exists(path):
    print("missing")
else:
    print(int(time.time() - os.path.getmtime(path)))
PYEOF
}

section "Runtime"
echo "Deploy dir: $DEPLOY_DIR"
echo "Config: $ENV_FILE"
echo "OS: $OS_NAME"

section "Service"
if [ "$OS_NAME" = "Darwin" ]; then
    echo "Manager: launchd"
    if launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1; then
        echo "Status: loaded"
    else
        echo "Status: not loaded"
    fi
    echo "Command: launchctl print gui/$(id -u)/$LAUNCHD_LABEL"
elif command -v systemctl >/dev/null 2>&1; then
    echo "Manager: systemd"
    if systemctl is-active --quiet "$SERVICE"; then
        echo "Status: active"
    else
        echo "Status: inactive"
    fi
    echo "Command: systemctl status $SERVICE"
else
    echo "Manager: unsupported"
fi

section "Process"
BOT_PID="$(pgrep -f "approval_bot.py" || true)"
if [ -n "$BOT_PID" ]; then
    echo "approval_bot.py PID: $BOT_PID"
else
    echo "approval_bot.py PID: not running"
fi

section "Heartbeat"
AGE="$(heartbeat_age)"
if [ "$AGE" = "missing" ]; then
    echo "Heartbeat: missing ($HEARTBEAT_FILE)"
elif [ "$AGE" -le "$HEARTBEAT_MAX_AGE" ]; then
    echo "Heartbeat: fresh (${AGE}s <= ${HEARTBEAT_MAX_AGE}s)"
else
    echo "Heartbeat: stale (${AGE}s > ${HEARTBEAT_MAX_AGE}s)"
fi

section "Logs"
for file in bot.log watchdog.log monitor.log monitor-backup.log send-alert.log; do
    if [ -f "$DEPLOY_DIR/$file" ]; then
        echo "$file: $DEPLOY_DIR/$file"
    fi
done
