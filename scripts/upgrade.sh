#!/bin/bash
# OpenClaw skill lifecycle: upgrade
# Re-run setup from the current skill repository while preserving runtime data.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="${1:-${DEPLOY_DIR:-$HOME/dingtalk-auto-approve}}"

if [ ! -f "$DEPLOY_DIR/.env" ]; then
    echo "WARN: 未找到现有 .env，将按首次安装流程生成模板: $DEPLOY_DIR/.env"
fi

export OPENCLAW_AUTO="${OPENCLAW_AUTO:-1}"
export SETUP_CRON="${SETUP_CRON:-y}"

bash "$SCRIPT_DIR/setup.sh" "$DEPLOY_DIR"

echo ""
echo "升级完成。已保留运行目录中的 .env、.approved_state.json 和日志文件。"
echo "可执行状态检查:"
echo "bash $DEPLOY_DIR/status.sh"
