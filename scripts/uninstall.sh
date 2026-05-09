#!/bin/bash
# OpenClaw skill lifecycle: uninstall
# Remove service registrations and optionally delete the runtime directory.

set -e

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

echo "将卸载钉钉自动审批运行服务"
echo "运行目录: $DEPLOY_DIR"

if [ "${FORCE:-0}" != "1" ]; then
    echo "如需继续，请设置 FORCE=1 后重新执行。"
    exit 1
fi

if [ "$OS_NAME" = "Darwin" ]; then
    for label in "$LAUNCHD_LABEL" "$LAUNCHD_LABEL.monitor" "$LAUNCHD_LABEL.monitor-backup"; do
        launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
        rm -f "$HOME/Library/LaunchAgents/$label.plist"
        echo "已移除 launchd: $label"
    done
elif command -v systemctl >/dev/null 2>&1; then
    if [ "$(id -u)" = "0" ]; then
        systemctl stop "$SERVICE" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$SERVICE"
        systemctl daemon-reload >/dev/null 2>&1 || true
        echo "已移除 systemd 服务: $SERVICE"
    else
        echo "非 root 用户，跳过 systemd 删除。可手动执行:"
        echo "sudo systemctl stop $SERVICE"
        echo "sudo systemctl disable $SERVICE"
        echo "sudo rm -f /etc/systemd/system/$SERVICE"
        echo "sudo systemctl daemon-reload"
    fi
fi

if command -v crontab >/dev/null 2>&1; then
    tmp_cron="$(mktemp)"
    if crontab -l > "$tmp_cron" 2>/dev/null; then
        grep -v "$DEPLOY_DIR/monitor.sh" "$tmp_cron" | grep -v "$DEPLOY_DIR/monitor-backup.sh" | crontab - 2>/dev/null || true
    fi
    rm -f "$tmp_cron"
    echo "已清理 crontab 监控任务"
fi

if [ "${KEEP_DATA:-0}" = "1" ]; then
    echo "KEEP_DATA=1，保留运行目录: $DEPLOY_DIR"
else
    rm -rf "$DEPLOY_DIR"
    echo "已删除运行目录: $DEPLOY_DIR"
fi
