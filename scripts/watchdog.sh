#!/bin/bash
# 钉钉审批机器人进程守护脚本
# 作用：检测 bot 是否在运行，如果不在则自动拉起
# 用法：chmod +x watchdog.sh && ./watchdog.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PIDFILE="$SCRIPT_DIR/.bot.pid"
LOGFILE="$SCRIPT_DIR/watchdog.log"
MAX_RESTARTS=10          # 最大连续重启次数（防止无限重启）
RESTART_WINDOW=300       # 时间窗口（秒），5 分钟内超过 MAX_RESTARTS 则放弃
BOT_CMD="python3 $SCRIPT_DIR/approval_bot.py"

# 记录重启时间
restart_times=()

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOGFILE"
}

cleanup() {
    log "收到退出信号，停止守护进程"
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE")
        kill "$pid" 2>/dev/null
        rm -f "$PIDFILE"
    fi
    exit 0
}

trap cleanup SIGINT SIGTERM

log "进程守护启动"
log "Bot 命令: $BOT_CMD"

while true; do
    # 检查 bot 是否在运行
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then
            # 正常运行，每 30 秒检查一次
            sleep 30
            continue
        else
            log "进程 $pid 已退出"
            rm -f "$PIDFILE"
        fi
    fi

    # 检查重启频率
    now=$(date +%s)
    # 清理 5 分钟前的记录
    restart_times=($(printf '%s\n' "${restart_times[@]}" | awk -v now="$now" -v window="$RESTART_WINDOW" '$1 > now - window'))
    
    if [ ${#restart_times[@]} -ge $MAX_RESTARTS ]; then
        log "⚠️ 连续重启 ${#restart_times[@]} 次（${RESTART_WINDOW}秒内），停止自动重启"
        log "请检查日志后手动重启: $BOT_CMD"
        exit 1
    fi

    # 启动 bot
    log "启动审批机器人..."
    nohup $BOT_CMD > /dev/null 2>&1 &
    pid=$!
    echo "$pid" > "$PIDFILE"
    restart_times+=("$now")
    log "Bot 已启动，PID: $pid（重启次数: ${#restart_times[@]}/${MAX_RESTARTS}）"

    # 等待 10 秒确认是否存活
    sleep 10
    if ! kill -0 "$pid" 2>/dev/null; then
        log "Bot 启动失败（10 秒内退出），日志: tail $SCRIPT_DIR/bot.log"
        rm -f "$PIDFILE"
        sleep 5
    fi
done
