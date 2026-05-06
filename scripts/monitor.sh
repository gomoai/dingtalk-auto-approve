#!/bin/bash
# 审批机器人 5 分钟健康监控
# 检查 systemd/launchd 服务 + bot 进程，异常时按 .env 的 ALERT_CHANNEL 发送告警。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOGFILE="$SCRIPT_DIR/monitor.log"

if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

OS_NAME="$(uname -s)"
SERVICE="${SERVICE_NAME:-dingtalk-bot.service}"
LAUNCHD_LABEL="${LAUNCHD_LABEL:-com.gomoai.dingtalk-auto-approve}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
}

send_alert() {
    local message="$1"
    ALERT_MESSAGE="$message" python3 << 'PYEOF'
import json
import os
import sys
import urllib.request

channel = os.environ.get("ALERT_CHANNEL", "dingtalk").lower()
message = os.environ.get("ALERT_MESSAGE", "")

def post_json(url, body, headers=None):
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers or {"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))

try:
    if channel in ("", "none"):
        sys.exit(0)
    if channel == "dingtalk":
        app_key = os.environ.get("DINGTALK_APP_KEY", "")
        app_secret = os.environ.get("DINGTALK_APP_SECRET", "")
        agent_id = int(os.environ.get("DINGTALK_AGENT_ID", "0") or "0")
        notify_user_id = os.environ.get("NOTIFY_USER_ID", "")
        if not app_key or not app_secret or not agent_id or not notify_user_id:
            print("WARN: 钉钉告警配置不完整，跳过发送")
            sys.exit(0)
        token_url = f"https://oapi.dingtalk.com/gettoken?appkey={app_key}&appsecret={app_secret}"
        with urllib.request.urlopen(token_url, timeout=10) as resp:
            token_result = json.loads(resp.read().decode("utf-8"))
        token = token_result.get("access_token")
        if not token:
            print(f"WARN: 获取钉钉 token 失败: {token_result}")
            sys.exit(0)
        url = f"https://oapi.dingtalk.com/topapi/message/corpconversation/asyncsend_v2?access_token={token}"
        post_json(url, {
            "agent_id": agent_id,
            "userid_list": notify_user_id,
            "msg": {"msgtype": "text", "text": {"content": message}},
        })
    elif channel in ("qclaw", "webhook"):
        webhook_url = os.environ.get("QCLAW_WEBHOOK_URL") or os.environ.get("ALERT_WEBHOOK_URL", "")
        if not webhook_url:
            print("WARN: webhook 告警地址未配置，跳过发送")
            sys.exit(0)
        post_json(webhook_url, {"text": message, "content": message})
    else:
        print(f"WARN: 未知 ALERT_CHANNEL={channel}，跳过发送")
except Exception as exc:
    print(f"WARN: 告警发送失败: {exc}")
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

log "bot 运行中, PID: $BOT_PID"
echo "OK"
exit 0
