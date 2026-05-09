# OpenClaw 安装示例

把仓库地址交给 OpenClaw/Agent：

```text
把这个仓库部署成钉钉自动审批：
https://github.com/gomoai/dingtalk-auto-approve
```

Agent 应读取 `SKILL.md` 和 `openclaw.skill.json`，只询问必要参数：

```env
DINGTALK_APP_KEY=钉钉应用 AppKey
DINGTALK_APP_SECRET=钉钉应用 AppSecret
DINGTALK_AGENT_ID=钉钉应用 AgentId
TARGET_PROCESS_CODE=目标审批流代码
ACTIONER_USER_ID=执行审批的用户 userId
NOTIFY_USER_ID=接收通知的用户 userId
```

推荐调用稳定生命周期入口：

```bash
OPENCLAW_AUTO=1 \
SETUP_CRON=y \
DINGTALK_APP_KEY='<app-key>' \
DINGTALK_APP_SECRET='<app-secret>' \
DINGTALK_AGENT_ID='<agent-id>' \
TARGET_PROCESS_CODE='<process-code>' \
ACTIONER_USER_ID='<actioner-user-id>' \
NOTIFY_USER_ID='<notify-user-id>' \
bash scripts/install.sh ~/dingtalk-auto-approve
```

安装后检查：

```bash
bash ~/dingtalk-auto-approve/status.sh
bash ~/dingtalk-auto-approve/doctor.sh
```

注意：`approval_bot.py` 是钉钉 Stream 长连接，必须由 `systemd` 或 `launchd` 常驻托管，不应由 OpenClaw 自身 cron 周期性启动。
