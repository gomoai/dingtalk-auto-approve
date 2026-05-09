# macOS launchd 示例

macOS 会使用用户级 `LaunchAgent` 托管主 bot 和定时监控：

```text
~/Library/LaunchAgents/com.gomoai.dingtalk-auto-approve.plist
~/Library/LaunchAgents/com.gomoai.dingtalk-auto-approve.monitor.plist
~/Library/LaunchAgents/com.gomoai.dingtalk-auto-approve.monitor-backup.plist
```

安装：

```bash
OPENCLAW_AUTO=1 SETUP_CRON=y bash scripts/install.sh ~/dingtalk-auto-approve
```

检查：

```bash
bash ~/dingtalk-auto-approve/status.sh
bash ~/dingtalk-auto-approve/doctor.sh
launchctl print gui/$(id -u)/com.gomoai.dingtalk-auto-approve
pgrep -f approval_bot.py
```

重启：

```bash
launchctl kickstart -k gui/$(id -u)/com.gomoai.dingtalk-auto-approve
```

卸载：

```bash
FORCE=1 bash ~/dingtalk-auto-approve/uninstall.sh
```
