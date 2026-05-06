#!/bin/bash
# 钉钉审批自动通过服务 — 运行服务部署脚本
# 用法：bash setup.sh [部署目录]
# Agent 非交互用法：OPENCLAW_AUTO=1 DINGTALK_APP_KEY=... bash setup.sh [部署目录]
# 功能：部署后台机器人服务；不是安装 OpenClaw skill 本身。
#      OpenClaw skill 是本目录，setup.sh 只负责复制运行脚本、配置 .env，
#      并按环境注册 systemd(Linux) 或 launchd(macOS)。

set -e

DEPLOY_DIR="${1:-$HOME/dingtalk-auto-approve}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✘]${NC} $1"; }

echo "========================================="
echo " 钉钉审批自动通过服务 - 部署向导"
echo "========================================="
echo "运行服务部署目录: $DEPLOY_DIR"
echo "说明: 本脚本不安装 OpenClaw skill，只部署后台机器人服务。"
echo ""

abs_path() {
    python3 - "$1" << 'PYEOF'
import os
import sys
print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PYEOF
}

update_env() {
    local key="$1"
    local value="$2"
    python3 - "$ENV_FILE" "$key" "$value" << 'PYEOF'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text().splitlines() if path.exists() else []
updated = False
for index, line in enumerate(lines):
    if line.startswith(f"{key}="):
        lines[index] = f"{key}={value}"
        updated = True
if not updated:
    lines.append(f"{key}={value}")
path.write_text("\n".join(lines) + "\n")
PYEOF
}

write_env_from_var() {
    local key="$1"
    local value="${!key:-}"
    if [ -n "$value" ]; then
        update_env "$key" "$value"
    fi
}

write_launch_agent() {
    local label="$1"
    local program="$2"
    local plist="$3"
    local interval="${4:-}"
    local keep_alive="${5:-false}"

    cat > "$plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$program</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$ABS_DIR</string>
EOF

    if [ -n "$interval" ]; then
        cat >> "$plist" << EOF
    <key>StartInterval</key>
    <integer>$interval</integer>
EOF
    else
        cat >> "$plist" << EOF
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <$keep_alive/>
EOF
    fi

    cat >> "$plist" << EOF
    <key>StandardOutPath</key>
    <string>$ABS_DIR/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$ABS_DIR/launchd.err.log</string>
</dict>
</plist>
EOF
}

load_launch_agent() {
    local plist="$1"
    local label="$2"

    if ! command -v launchctl >/dev/null 2>&1; then
        warn "未找到 launchctl，已生成 plist 但未加载: $plist"
        return
    fi

    launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
    if launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1; then
        launchctl enable "gui/$(id -u)/$label" >/dev/null 2>&1 || true
        launchctl kickstart -k "gui/$(id -u)/$label" >/dev/null 2>&1 || true
        log "launchd 已加载: $label"
    else
        warn "launchd 加载失败，可手动执行: launchctl bootstrap gui/$(id -u) $plist"
    fi
}

# ── Step 1: 检查 Python 3 ──
if ! command -v python3 &>/dev/null; then
    err "未找到 python3，请先安装 Python 3.7+"
    exit 1
fi
log "Python 3: $(python3 --version)"

# ── Step 2: 创建部署目录 ──
mkdir -p "$DEPLOY_DIR"
log "部署目录已创建: $DEPLOY_DIR"

# ── Step 3: 复制脚本文件 ──
cp "$SCRIPT_DIR/approval_bot.py" "$DEPLOY_DIR/"
cp "$SCRIPT_DIR/watchdog.sh" "$DEPLOY_DIR/"
cp "$SCRIPT_DIR/monitor.sh" "$DEPLOY_DIR/"
cp "$SCRIPT_DIR/monitor-backup.sh" "$DEPLOY_DIR/"
chmod +x "$DEPLOY_DIR/watchdog.sh" "$DEPLOY_DIR/monitor.sh" "$DEPLOY_DIR/monitor-backup.sh"
log "脚本文件已复制"

# ── Step 4: 安装 Python 依赖 ──
if python3 -c "import dingtalk_stream" 2>/dev/null; then
    log "dingtalk-stream 已安装"
else
    warn "正在安装 dingtalk-stream..."
    pip3 install dingtalk-stream >/dev/null 2>&1 || {
        err "pip3 install 失败，请手动执行: pip3 install dingtalk-stream"
        exit 1
    }
    log "dingtalk-stream 安装完成"
fi

# ── Step 5: 生成 .env 配置 ──
ENV_FILE="$DEPLOY_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    warn ".env 已存在，跳过生成"
else
    cat > "$ENV_FILE" << 'EOF'
# 钉钉应用凭证（必填）
DINGTALK_APP_KEY=
DINGTALK_APP_SECRET=

# 目标审批配置（必填）
TARGET_PROCESS_CODE=
TARGET_SYSTEM_SOURCE=AI工具账号

# 审批执行人 userId（必填）：必须是审批任务当前处理人
ACTIONER_USER_ID=

# 通知配置（推荐）
DINGTALK_AGENT_ID=
NOTIFY_USER_ID=

# 告警通道：dingtalk / qclaw / webhook / none
ALERT_CHANNEL=dingtalk
QCLAW_WEBHOOK_URL=
ALERT_WEBHOOK_URL=

# 服务名（通常无需修改）
SERVICE_NAME=dingtalk-bot.service
LAUNCHD_LABEL=com.gomoai.dingtalk-auto-approve

# 兜底监控阈值（分钟）
ALERT_THRESHOLD_MIN=5

# 兜底监控是否自动补审批；设为 false 时只告警
BACKUP_AUTO_APPROVE=true
EOF
    log ".env 模板已生成，请编辑填入凭证和审批配置"
fi

# ── Step 6: 写入配置（支持 OpenClaw/Agent 非交互模式） ──
write_env_from_var "DINGTALK_APP_KEY"
write_env_from_var "DINGTALK_APP_SECRET"
write_env_from_var "DINGTALK_AGENT_ID"
write_env_from_var "TARGET_PROCESS_CODE"
write_env_from_var "TARGET_SYSTEM_SOURCE"
write_env_from_var "ACTIONER_USER_ID"
write_env_from_var "NOTIFY_USER_ID"
write_env_from_var "ALERT_CHANNEL"
write_env_from_var "QCLAW_WEBHOOK_URL"
write_env_from_var "ALERT_WEBHOOK_URL"
write_env_from_var "SERVICE_NAME"
write_env_from_var "LAUNCHD_LABEL"
write_env_from_var "ALERT_THRESHOLD_MIN"
write_env_from_var "BACKUP_AUTO_APPROVE"

if [ "${OPENCLAW_AUTO:-0}" = "1" ] || [ ! -t 0 ]; then
    log "已按环境变量写入配置，跳过交互输入"
    PROCESS_CODE=""
    SYSTEM_SOURCE=""
    ACTIONER_USER_ID_INPUT=""
else
    echo ""
    echo "可选：现在写入常用配置（留空则稍后手动编辑 .env）："
    read -p "  目标审批流代码 (PROC-xxx): " PROCESS_CODE
    read -p "  目标系统来源字段值 (用于匹配表单): " SYSTEM_SOURCE
    read -p "  审批执行人 userId: " ACTIONER_USER_ID_INPUT
fi

if [ -n "$PROCESS_CODE" ]; then
    update_env "TARGET_PROCESS_CODE" "$PROCESS_CODE"
    log "审批流代码已更新: $PROCESS_CODE"
fi

if [ -n "$SYSTEM_SOURCE" ]; then
    update_env "TARGET_SYSTEM_SOURCE" "$SYSTEM_SOURCE"
    log "系统来源已更新: $SYSTEM_SOURCE"
fi

if [ -n "$ACTIONER_USER_ID_INPUT" ]; then
    update_env "ACTIONER_USER_ID" "$ACTIONER_USER_ID_INPUT"
    log "审批执行人已更新: $ACTIONER_USER_ID_INPUT"
fi

# ── Step 7: 注册常驻服务（Linux 用 systemd，macOS 用 launchd） ──
SERVICE_FILE="/etc/systemd/system/dingtalk-bot.service"
ABS_DIR="$(abs_path "$DEPLOY_DIR")"
SERVICE_TEMPLATE="$DEPLOY_DIR/dingtalk-bot.service"
cat > "$SERVICE_TEMPLATE" << EOF
[Unit]
Description=DingTalk Approval Auto-Approve Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$ABS_DIR
ExecStart=/bin/bash $ABS_DIR/watchdog.sh
Restart=on-failure
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

OS_NAME="$(uname -s)"
if [ "$OS_NAME" = "Darwin" ]; then
    LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
    mkdir -p "$LAUNCH_AGENT_DIR"

    BOT_LABEL="${LAUNCHD_LABEL:-com.gomoai.dingtalk-auto-approve}"
    BOT_PLIST="$LAUNCH_AGENT_DIR/$BOT_LABEL.plist"
    write_launch_agent "$BOT_LABEL" "$ABS_DIR/watchdog.sh" "$BOT_PLIST" "" "true"
    load_launch_agent "$BOT_PLIST" "$BOT_LABEL"

    log "macOS launchd 服务已配置: $BOT_PLIST"
elif [ "$OS_NAME" != "Linux" ] || ! command -v systemctl >/dev/null 2>&1; then
    warn "当前环境不是 Linux/systemd 或 macOS/launchd，已跳过服务注册"
    warn "systemd 服务模板已生成: $SERVICE_TEMPLATE"
elif [ "$(id -u)" != "0" ]; then
    warn "当前不是 root，已跳过写入 $SERVICE_FILE"
    warn "可稍后执行: sudo cp $SERVICE_TEMPLATE $SERVICE_FILE"
elif [ -f "$SERVICE_FILE" ]; then
    warn "systemd 服务已存在，跳过创建。模板已更新: $SERVICE_TEMPLATE"
else
    cp "$SERVICE_TEMPLATE" "$SERVICE_FILE"
    log "systemd 服务已注册: $SERVICE_FILE"
fi

# ── Step 8: 配置定时监控（Linux 用 crontab，macOS 用 launchd StartInterval） ──
if [ "${OPENCLAW_AUTO:-0}" = "1" ] || [ ! -t 0 ]; then
    SETUP_CRON="${SETUP_CRON:-n}"
else
    echo ""
    warn "是否配置定时监控？(y/n)"
    read -r SETUP_CRON
fi
if [[ "$SETUP_CRON" =~ ^[Yy]$ ]]; then
    if [ "$OS_NAME" = "Darwin" ]; then
        LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
        mkdir -p "$LAUNCH_AGENT_DIR"
        BASE_LAUNCHD_LABEL="${LAUNCHD_LABEL:-com.gomoai.dingtalk-auto-approve}"

        MONITOR_LABEL="$BASE_LAUNCHD_LABEL.monitor"
        MONITOR_PLIST="$LAUNCH_AGENT_DIR/$MONITOR_LABEL.plist"
        write_launch_agent "$MONITOR_LABEL" "$ABS_DIR/monitor.sh" "$MONITOR_PLIST" "300"
        load_launch_agent "$MONITOR_PLIST" "$MONITOR_LABEL"

        BACKUP_LABEL="$BASE_LAUNCHD_LABEL.monitor-backup"
        BACKUP_PLIST="$LAUNCH_AGENT_DIR/$BACKUP_LABEL.plist"
        write_launch_agent "$BACKUP_LABEL" "$ABS_DIR/monitor-backup.sh" "$BACKUP_PLIST" "900"
        load_launch_agent "$BACKUP_PLIST" "$BACKUP_LABEL"

        log "macOS 定时监控已通过 launchd 配置"
    else
        CRON_5M="*/5 * * * * bash $ABS_DIR/monitor.sh >/dev/null 2>&1"
        CRON_15M="*/15 * * * * bash $ABS_DIR/monitor-backup.sh >/dev/null 2>&1"
        
        # 检查是否已存在
        if crontab -l 2>/dev/null | grep -q "monitor.sh"; then
            log "5分钟监控已存在于 crontab"
        else
            (crontab -l 2>/dev/null; echo "$CRON_5M") | crontab -
            log "5分钟健康监控已添加"
        fi
        
        if crontab -l 2>/dev/null | grep -q "monitor-backup.sh"; then
            log "15分钟兜底监控已存在于 crontab"
        else
            (crontab -l 2>/dev/null; echo "$CRON_15M") | crontab -
            log "15分钟兜底监控已添加"
        fi
    fi
else
    warn "跳过定时监控配置，可稍后手动添加"
fi

# ── Step 9: 生成 .gitignore ──
if [ ! -f "$DEPLOY_DIR/.gitignore" ]; then
    cat > "$DEPLOY_DIR/.gitignore" << 'EOF'
.env
.approved_state.json
.bot.pid
__pycache__/
*.pyc
bot.log
watchdog.log
monitor.log
monitor-backup.log
EOF
    log ".gitignore 已生成"
fi

# ── Done ──
echo ""
echo "========================================="
echo " 安装完成！接下来："
echo "========================================="
echo ""
echo "1. 编辑 .env 填入钉钉应用凭证:"
echo "   nano $DEPLOY_DIR/.env"
echo ""
echo "2. 确认审批流代码和系统来源正确:"
echo "   grep -E 'TARGET_PROCESS_CODE|TARGET_SYSTEM_SOURCE|ACTIONER_USER_ID|ALERT_CHANNEL' $DEPLOY_DIR/.env"
echo ""
echo "3. 启动/查看服务:"
echo "   macOS: launchctl print gui/$(id -u)/\${LAUNCHD_LABEL:-com.gomoai.dingtalk-auto-approve}"
echo "   sudo systemctl daemon-reload"
echo "   sudo systemctl enable dingtalk-bot"
echo "   sudo systemctl start dingtalk-bot"
echo "   sudo systemctl status dingtalk-bot"
echo ""
echo "4. 查看日志:"
echo "   tail -f $DEPLOY_DIR/bot.log"
echo "   journalctl -u dingtalk-bot -f"
echo ""
