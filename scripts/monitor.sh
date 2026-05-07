#!/bin/bash
# 审批机器人 5 分钟健康监控
# 检查 systemd/launchd 服务 + bot 进程，异常时按 .env 的 ALERT_CHANNEL 发送告警。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOGFILE="$SCRIPT_DIR/monitor.log"
ALERT_SCRIPT="$SCRIPT_DIR/send-alert.py"

if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

OS_NAME="$(uname -s)"
SERVICE="${SERVICE_NAME:-dingtalk-bot.service}"
LAUNCHD_LABEL="${LAUNCHD_LABEL:-com.gomoai.dingtalk-auto-approve}"
HEARTBEAT_FILE="${HEARTBEAT_FILE:-$SCRIPT_DIR/.bot_heartbeat}"
HEARTBEAT_MAX_AGE="${HEARTBEAT_MAX_AGE:-180}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
}

send_alert() {
    local message="$1"
    if [ -x "$ALERT_SCRIPT" ]; then
        ALERT_MESSAGE="$message" "$ALERT_SCRIPT" >> "$SCRIPT_DIR/send-alert.log" 2>&1 || true
    else
        log "告警脚本不存在，跳过发送: $ALERT_SCRIPT"
    fi
}

heartbeat_age() {
    python3 - "$HEARTBEAT_FILE" << 'PYEOF'
import os
import sys
import time

path = sys.argv[1]
if not os.path.exists(path):
    print(-1)
else:
    print(int(time.time() - os.path.getmtime(path)))
PYEOF
}

restart_service() {
    if [ "$OS_NAME" = "Darwin" ]; then
        launchctl kickstart -k "gui/$(id -u)/$LAUNCHD_LABEL"
    else
        systemctl restart "$SERVICE"
    fi
}

service_status_hint() {
    if [ "$OS_NAME" = "Darwin" ]; then
        echo "launchctl print gui/$(id -u)/$LAUNCHD_LABEL"
    else
        echo "systemctl status $SERVICE"
    fi
}

# 检查服务状态
if [ "$OS_NAME" = "Darwin" ]; then
    if ! launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1; then
        log "launchd 服务未加载: $LAUNCHD_LABEL"
        ALERT="审批机器人 launchd 服务未加载
请检查: $(service_status_hint)"
        echo "$ALERT"
        send_alert "$ALERT"
        exit 1
    fi
elif ! systemctl is-active --quiet "$SERVICE"; then
    log "服务未运行: $SERVICE"
    ALERT="审批机器人服务已停止
请检查: $(service_status_hint)"
    echo "$ALERT"
    send_alert "$ALERT"
    exit 1
fi

# 检查 bot 进程
BOT_PID=$(pgrep -f "approval_bot.py" || true)
if [ -z "$BOT_PID" ]; then
    log "bot 进程未运行，尝试自动重启..."
    restart_service
    sleep 10
    NEW_PID=$(pgrep -f "approval_bot.py" || true)
    if [ -z "$NEW_PID" ]; then
        log "重启失败"
        ALERT="审批机器人重启失败
请紧急处理: $(service_status_hint)
日志: tail $SCRIPT_DIR/bot.log"
        echo "$ALERT"
        send_alert "$ALERT"
        exit 1
    else
        log "bot 已自动重启, PID: $NEW_PID"
        ALERT="bot 进程异常，已自动重启
新 PID: $NEW_PID"
        echo "$ALERT"
        send_alert "$ALERT"
        exit 0
    fi
fi

AGE="$(heartbeat_age)"
if [ "$AGE" -lt 0 ] || [ "$AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
    if [ "$AGE" -lt 0 ]; then
        REASON="心跳文件不存在: $HEARTBEAT_FILE"
    else
        REASON="心跳过期: ${AGE}s > ${HEARTBEAT_MAX_AGE}s"
    fi
    log "$REASON，尝试重启服务..."
    restart_service
    sleep 10
    NEW_AGE="$(heartbeat_age)"
    if [ "$NEW_AGE" -ge 0 ] && [ "$NEW_AGE" -le "$HEARTBEAT_MAX_AGE" ]; then
        ALERT="审批机器人心跳异常，已自动重启恢复
原因: $REASON
当前心跳年龄: ${NEW_AGE}s"
        echo "$ALERT"
        send_alert "$ALERT"
        exit 0
    fi

    ALERT="审批机器人心跳异常，自动重启后仍未恢复
原因: $REASON
请检查: $(service_status_hint)
bot 日志: tail $SCRIPT_DIR/bot.log
watchdog 日志: tail $SCRIPT_DIR/watchdog.log"
    echo "$ALERT"
    send_alert "$ALERT"
    exit 1
fi

log "bot 运行中, PID: $BOT_PID"
echo "OK"
exit 0
