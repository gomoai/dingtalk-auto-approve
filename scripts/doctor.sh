#!/bin/bash
# OpenClaw skill lifecycle: doctor
# Validate local runtime prerequisites without changing the system.

DEPLOY_DIR="${1:-${DEPLOY_DIR:-$HOME/dingtalk-auto-approve}}"
ENV_FILE="$DEPLOY_DIR/.env"
FAILED=0

fail() {
    echo "FAIL: $1"
    FAILED=1
}

pass() {
    echo "OK: $1"
}

warn() {
    echo "WARN: $1"
}

require_env() {
    local key="$1"
    local value="${!key:-}"
    if [ -z "$value" ]; then
        fail "缺少配置 $key"
    else
        pass "已配置 $key"
    fi
}

if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
    pass "找到配置文件: $ENV_FILE"
else
    fail "未找到配置文件: $ENV_FILE"
fi

if command -v python3 >/dev/null 2>&1; then
    pass "Python: $(python3 --version)"
else
    fail "未找到 python3"
fi

if python3 -c "import dingtalk_stream" >/dev/null 2>&1; then
    pass "Python 依赖 dingtalk_stream 已安装"
else
    fail "Python 依赖 dingtalk_stream 未安装"
fi

for key in DINGTALK_APP_KEY DINGTALK_APP_SECRET DINGTALK_AGENT_ID TARGET_PROCESS_CODE ACTIONER_USER_ID NOTIFY_USER_ID; do
    require_env "$key"
done

if [ -n "${DINGTALK_AGENT_ID:-}" ] && ! [[ "$DINGTALK_AGENT_ID" =~ ^[0-9]+$ ]]; then
    fail "DINGTALK_AGENT_ID 必须是数字"
fi

ALERT_CHANNEL="${ALERT_CHANNEL:-dingtalk}"
IFS=',' read -r -a CHANNELS <<< "$ALERT_CHANNEL"
for raw_channel in "${CHANNELS[@]}"; do
    channel="$(echo "$raw_channel" | tr '[:upper:]' '[:lower:]' | xargs)"
    case "$channel" in
        dingtalk)
            if [ -n "${DINGTALK_AGENT_ID:-}" ] && [ -n "${NOTIFY_USER_ID:-}" ]; then
                pass "钉钉告警配置可用"
            else
                warn "钉钉告警需要 DINGTALK_AGENT_ID 和 NOTIFY_USER_ID"
            fi
            ;;
        qclaw)
            if [ -n "${QCLAW_WEBHOOK_URL:-}" ] || [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
                pass "QClaw/webhook 告警配置可用"
            else
                warn "qclaw 告警通道未配置 webhook URL"
            fi
            ;;
        webhook)
            if [ -n "${ALERT_WEBHOOK_URL:-}" ] || [ -n "${QCLAW_WEBHOOK_URL:-}" ]; then
                pass "webhook 告警配置可用"
            else
                warn "webhook 告警通道未配置 webhook URL"
            fi
            ;;
        none|"")
            warn "告警通道已关闭"
            ;;
        *)
            fail "未知 ALERT_CHANNEL: $channel"
            ;;
    esac
done

if [ -f "$DEPLOY_DIR/approval_bot.py" ]; then
    python3 -m py_compile "$DEPLOY_DIR/approval_bot.py" && pass "approval_bot.py 语法检查通过" || fail "approval_bot.py 语法检查失败"
else
    warn "运行目录尚未部署 approval_bot.py"
fi

OS_NAME="$(uname -s)"
if [ "$OS_NAME" = "Darwin" ]; then
    if command -v launchctl >/dev/null 2>&1; then
        pass "可使用 launchd"
    else
        fail "macOS 未找到 launchctl"
    fi
elif command -v systemctl >/dev/null 2>&1; then
    pass "可使用 systemd"
else
    warn "当前环境未检测到 systemd/launchd，只能生成运行目录，不能注册常驻服务"
fi

if [ "${CHECK_DINGTALK_TOKEN:-0}" = "1" ]; then
    python3 - << 'PYEOF'
import json
import os
import sys
import urllib.request

app_key = os.environ.get("DINGTALK_APP_KEY", "")
app_secret = os.environ.get("DINGTALK_APP_SECRET", "")
url = f"https://oapi.dingtalk.com/gettoken?appkey={app_key}&appsecret={app_secret}"
try:
    with urllib.request.urlopen(url, timeout=10) as resp:
        result = json.loads(resp.read().decode("utf-8"))
    if result.get("access_token"):
        print("OK: 钉钉 token 获取成功")
    else:
        print(f"FAIL: 钉钉 token 获取失败: {result}")
        sys.exit(1)
except Exception as exc:
    print(f"FAIL: 钉钉 token 检查异常: {exc}")
    sys.exit(1)
PYEOF
    if [ $? -ne 0 ]; then
        FAILED=1
    fi
else
    warn "跳过钉钉 token 联网检查；如需检查，设置 CHECK_DINGTALK_TOKEN=1"
fi

exit "$FAILED"
