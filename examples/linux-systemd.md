# Linux systemd 示例

root 环境安装时，`scripts/install.sh` 会调用 `setup.sh` 并自动完成：

```bash
systemctl daemon-reload
systemctl enable dingtalk-bot.service
systemctl restart dingtalk-bot.service
```

非 root 环境会在运行目录生成 `dingtalk-bot.service` 模板，需要手动复制：

```bash
sudo cp ~/dingtalk-auto-approve/dingtalk-bot.service /etc/systemd/system/dingtalk-bot.service
sudo systemctl daemon-reload
sudo systemctl enable dingtalk-bot.service
sudo systemctl restart dingtalk-bot.service
```

常用维护命令：

```bash
bash ~/dingtalk-auto-approve/status.sh
bash ~/dingtalk-auto-approve/doctor.sh
systemctl status dingtalk-bot.service
journalctl -u dingtalk-bot.service -f
tail -f ~/dingtalk-auto-approve/bot.log
```

卸载：

```bash
FORCE=1 bash ~/dingtalk-auto-approve/uninstall.sh
```

如需保留 `.env`、日志和审批状态：

```bash
FORCE=1 KEEP_DATA=1 bash ~/dingtalk-auto-approve/uninstall.sh
```
