# DingTalk Auto Approve OpenClaw Skill

这是一个 OpenClaw skill 仓库，用于部署和维护钉钉审批自动通过机器人。

用户可以把本仓库地址交给 OpenClaw：

```text
https://github.com/gomoai/dingtalk-auto-approve
```

OpenClaw/Agent 会读取 `SKILL.md`，询问必要参数，然后自动部署后台机器人服务。

## 它做什么

- 监听钉钉 Stream 审批事件
- 对符合条件的审批单自动通过
- 记录已处理审批单，避免重复处理
- 发送审批结果和异常告警
- 支持健康监控和兜底监控
- 支持 macOS `launchd` 和 Linux `systemd`

## 目录关系

这个仓库本身是 skill 源码，不是运行目录。

```text
GitHub skill 仓库
  ↓ OpenClaw clone / load
SKILL.md
  ↓ 指导 Agent 收集参数并执行部署
~/dingtalk-auto-approve
  ↓ 后台机器人运行目录
.env / bot.log / .approved_state.json
```

运行时的 `.env`、日志和状态文件不会提交到 GitHub。

## 交给 OpenClaw 使用

对 OpenClaw 说：

```text
把这个仓库部署成钉钉自动审批：
https://github.com/gomoai/dingtalk-auto-approve
```

OpenClaw 应只向你询问必要参数：

- 钉钉应用 `AppKey`
- 钉钉应用 `AppSecret`
- 钉钉应用 `AgentId`
- 目标审批流 `processCode`
- 审批执行人 `userId`
- 通知接收人 `userId`
- 是否启用 QClaw / webhook 告警

## 手动部署

如果不通过 OpenClaw，也可以手动部署后台服务：

```bash
git clone https://github.com/gomoai/dingtalk-auto-approve
cd dingtalk-auto-approve
bash scripts/setup.sh ~/dingtalk-auto-approve
```

然后配置：

```bash
nano ~/dingtalk-auto-approve/.env
```

## 平台支持

macOS：

- 使用用户级 `launchd LaunchAgent`
- 登录后自动拉起机器人
- 监控脚本通过 `StartInterval` 定时运行

Linux：

- 使用 `systemd` 托管机器人
- 使用 `crontab` 运行健康监控和兜底监控

## 安全说明

不要提交以下文件：

- `.env`
- `.approved_state.json`
- `*.log`
- `.bot.pid`
- `dingtalk-bot.service`
- `*.plist`

仓库内只应包含模板、脚本和说明，不应包含真实钉钉密钥、webhook 地址或审批数据。

## 关键文件

- `SKILL.md`: OpenClaw/Agent 执行协议
- `scripts/approval_bot.py`: 钉钉审批机器人
- `scripts/setup.sh`: 后台服务部署脚本
- `scripts/monitor.sh`: 健康监控
- `scripts/monitor-backup.sh`: 兜底监控
- `references/config-template.env`: 配置模板
- `references/dingtalk-permissions.md`: 钉钉权限说明
