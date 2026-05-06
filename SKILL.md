---
name: dingtalk-auto-approve
description: >
  OpenClaw 钉钉审批自动通过技能。指导 Agent 部署和维护一个钉钉 Stream 审批机器人，
  监听审批事件，对符合条件的审批单自动通过，并附带进程守护、健康监控、兜底自动审批。
  使用场景：(1) 自动通过特定钉钉审批流（如账号权限申请单）(2) 监控审批机器人运行状态
  (3) 兜底检查并自动处理卡住的审批单 (4) 一键安装部署整套服务。
  触发词：钉钉审批自动通过、钉钉审批机器人、自动审批、审批流自动化、钉钉审批监控。
---

# 钉钉审批自动通过技能

这是一个 OpenClaw skill 仓库。用户可以只把 Git 仓库地址交给 OpenClaw；Agent 应自动 clone/加载本 skill，并在必要时向用户提问，随后部署和维护钉钉审批自动通过后台服务。

`SKILL.md` 是给 Agent 的执行协议；`scripts/setup.sh` 部署的是后台机器人运行服务，不是安装 OpenClaw skill 本身。后台服务默认部署到 `~/dingtalk-auto-approve` 或用户指定目录。

## 自动化目标

当用户说“用这个仓库部署钉钉自动审批”“安装这个 skill”“部署这个 Git 仓库”等类似请求时，Agent 应完成全流程：

1. 获取仓库地址并 clone 到本地临时目录或 OpenClaw skills 目录。
2. 校验仓库结构：必须存在 `SKILL.md`、`scripts/setup.sh`、`scripts/approval_bot.py`。
3. 只向用户询问必要参数，不让用户手动编辑文件。
4. 使用非交互模式运行 `scripts/setup.sh`，由环境变量写入 `.env`。
5. 按运行环境注册服务：Linux 使用 systemd + crontab；macOS 使用 launchd。
6. 执行健康检查，给出部署结果、日志路径和后续维护命令。

## 必问参数

部署前向用户收集：

```env
DINGTALK_APP_KEY=钉钉应用 AppKey
DINGTALK_APP_SECRET=钉钉应用 AppSecret
DINGTALK_AGENT_ID=钉钉应用 AgentId
TARGET_PROCESS_CODE=目标审批流代码
ACTIONER_USER_ID=执行审批的用户 userId
NOTIFY_USER_ID=接收通知的用户 userId
```

可使用默认值：

```env
TARGET_SYSTEM_SOURCE=AI工具账号
ALERT_CHANNEL=dingtalk
ALERT_THRESHOLD_MIN=5
BACKUP_AUTO_APPROVE=true
SERVICE_NAME=dingtalk-bot.service
LAUNCHD_LABEL=com.gomoai.dingtalk-auto-approve
```

如用户要求 QClaw/微信或 webhook 告警，再询问：

```env
ALERT_CHANNEL=qclaw
QCLAW_WEBHOOK_URL=QClaw webhook 地址
```

或：

```env
ALERT_CHANNEL=webhook
ALERT_WEBHOOK_URL=通用 webhook 地址
```

`ACTIONER_USER_ID` 必须是审批任务的当前处理人；`NOTIFY_USER_ID` 只负责接收通知，可以与审批执行人相同，也可以不同。

## Agent 自动部署流程

### 1. 安装/加载 skill 仓库

如果用户只提供 Git 仓库地址，先 clone：

```bash
git clone <repo-url> dingtalk-auto-approve
cd dingtalk-auto-approve
```

如果 OpenClaw 有固定 skills 目录，将仓库放到该目录；否则使用当前 clone 目录执行部署即可。不要把 `.env`、日志或状态文件提交回仓库。

### 2. 确认部署环境

正式常驻部署支持两类环境：

- Linux + systemd：注册 `dingtalk-bot.service`，使用 crontab 跑健康监控和兜底监控。
- macOS + launchd：注册用户级 `LaunchAgent`，登录后自动拉起机器人，并用 `StartInterval` 跑监控。

如果当前既不是 Linux/systemd 也不是 macOS/launchd：

- 可以继续生成运行目录和 `.env`
- 跳过服务注册
- 告知用户需要在 Linux 或 macOS 机器上执行正式部署

### 3. 非交互部署后台服务

Agent 收集参数后，用环境变量运行：

```bash
OPENCLAW_AUTO=1 \
SETUP_CRON=y \
DINGTALK_APP_KEY='<app-key>' \
DINGTALK_APP_SECRET='<app-secret>' \
DINGTALK_AGENT_ID='<agent-id>' \
TARGET_PROCESS_CODE='<process-code>' \
TARGET_SYSTEM_SOURCE='AI工具账号' \
ACTIONER_USER_ID='<actioner-user-id>' \
NOTIFY_USER_ID='<notify-user-id>' \
ALERT_CHANNEL='dingtalk' \
bash scripts/setup.sh ~/dingtalk-auto-approve
```

如启用 QClaw：

```bash
OPENCLAW_AUTO=1 \
SETUP_CRON=y \
ALERT_CHANNEL='qclaw' \
QCLAW_WEBHOOK_URL='<qclaw-webhook-url>' \
bash scripts/setup.sh ~/dingtalk-auto-approve
```

注意：实际执行时应把全部必填参数放在同一次命令环境中；不要把密钥打印到最终回复。

### 4. 启动服务

Linux/systemd：

```bash
sudo systemctl daemon-reload
sudo systemctl enable dingtalk-bot.service
sudo systemctl start dingtalk-bot.service
sudo systemctl status dingtalk-bot.service
```

如果当前用户没有 root 权限，`setup.sh` 会在部署目录生成 `dingtalk-bot.service` 模板。提示用户或使用授权方式执行：

```bash
sudo cp ~/dingtalk-auto-approve/dingtalk-bot.service /etc/systemd/system/dingtalk-bot.service
```

macOS/launchd：

```bash
launchctl print gui/$(id -u)/com.gomoai.dingtalk-auto-approve
launchctl kickstart -k gui/$(id -u)/com.gomoai.dingtalk-auto-approve
```

`setup.sh` 会生成并加载这些用户级 LaunchAgent：

```text
~/Library/LaunchAgents/com.gomoai.dingtalk-auto-approve.plist
~/Library/LaunchAgents/com.gomoai.dingtalk-auto-approve.monitor.plist
~/Library/LaunchAgents/com.gomoai.dingtalk-auto-approve.monitor-backup.plist
```

### 5. 验收

部署后检查：

```bash
python3 -m py_compile ~/dingtalk-auto-approve/approval_bot.py
tail -n 50 ~/dingtalk-auto-approve/bot.log
bash ~/dingtalk-auto-approve/monitor.sh
bash ~/dingtalk-auto-approve/monitor-backup.sh
```

Linux 额外检查：

```bash
sudo systemctl is-active dingtalk-bot.service
```

macOS 额外检查：

```bash
launchctl print gui/$(id -u)/com.gomoai.dingtalk-auto-approve
pgrep -f approval_bot.py
```

成功后告诉用户：

- 运行目录：`~/dingtalk-auto-approve`
- 配置文件：`~/dingtalk-auto-approve/.env`
- 应用日志：`~/dingtalk-auto-approve/bot.log`
- 守护日志：`~/dingtalk-auto-approve/watchdog.log`
- Linux 服务命令：`systemctl status/restart dingtalk-bot.service`
- macOS 服务命令：`launchctl print/kickstart gui/$(id -u)/com.gomoai.dingtalk-auto-approve`

## 人工部署 fallback

仅当自动部署不可用时，再指导用户手动执行：

```bash
bash scripts/setup.sh ~/dingtalk-auto-approve
```

## 钉钉应用权限配置

**这是最容易踩坑的步骤。** 必须在钉钉开发者后台为应用开通以下权限：

1. 打开 [钉钉开发者后台](https://open-dev.dingtalk.com/)
2. 选择目标应用 → 权限管理
3. 搜索并开通以下权限：
   - `qyapi_aflow_execute`（工作流实例执行权限，**最关键**）
   - 工作流模板读权限
   - 工作流实例读权限
   - 工作通知发送权限

详细步骤见 [references/dingtalk-permissions.md](references/dingtalk-permissions.md)。

## 服务管理

```bash
systemctl status dingtalk-bot    # 查看状态
systemctl restart dingtalk-bot   # 重启
journalctl -u dingtalk-bot -f    # 查看实时日志
tail -f ~/dingtalk-auto-approve/bot.log      # 应用日志
tail -f ~/dingtalk-auto-approve/watchdog.log # 守护日志
tail -f ~/dingtalk-auto-approve/launchd.log  # macOS launchd 输出
```

## 自定义

### 修改目标审批流

编辑 `.env`：

```env
TARGET_PROCESS_CODE=PROC-你的审批流代码
TARGET_SYSTEM_SOURCE=AI工具账号
```

审批流代码获取方式：在钉钉开发者后台 → 应用开发 → 审批 中查看，
或通过 API 查询已创建的审批模板。

### 审批判断逻辑（5 层过滤）

1. 审批流代码匹配 `TARGET_PROCESS_CODE`
2. 事件类型 == `start`；若事件携带状态，则状态 == `RUNNING`
3. 幂等去重（`.approved_state.json` 中已记录）
4. 当前审批人字段（`userId` / `staffId`）== `ACTIONER_USER_ID`
5. 表单字段"系统来源" == `TARGET_SYSTEM_SOURCE`

### 兜底自动审批

`monitor-backup.sh` 每 15 分钟查询最近 7 天的目标审批流实例。对满足以下条件的审批单，会自动补执行同意：

1. 审批单仍是 `RUNNING`
2. 未出现在 `.approved_state.json`
3. 表单字段"系统来源" == `TARGET_SYSTEM_SOURCE`
4. 不是 `ACTIONER_USER_ID` 已手动同意过的单子
5. 等待时长 >= `ALERT_THRESHOLD_MIN`

默认 `BACKUP_AUTO_APPROVE=true`，因此早于 bot 启动时间的存量 RUNNING 单也会被兜底处理。若只想告警不自动审批，在 `.env` 中设置：

```env
BACKUP_AUTO_APPROVE=false
```

### 增加新的自动通过条件

在 `ApprovalAutoApproveHandler.process()` 方法中添加过滤逻辑，
在"执行自动通过"之前插入新的 `if` 判断即可。

## 注意事项

- **安全**：`.env` 包含密钥，确保不被公开访问
- **权限**：钉钉应用必须有 `qyapi_aflow_execute` 权限，否则审批 API 调用会失败
- **幂等**：`.approved_state.json` 保存已审批记录，防止重复处理
- **部署环境**：Linux 使用 systemd；macOS 使用 launchd 用户级 LaunchAgent
- **告警通道**：默认通过钉钉工作通知告警，QClaw/微信告警作为 webhook 可选集成
