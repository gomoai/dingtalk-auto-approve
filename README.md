# DingTalk Auto Approve Deployment Skill

这是一个部署型 OpenClaw skill 仓库，用于部署和维护钉钉审批自动通过机器人。

它不是把审批长连接直接跑在 OpenClaw 内部的插件。OpenClaw/Agent 负责读取 `SKILL.md` 和 `openclaw.skill.json`，完成参数收集、安装、诊断、升级和卸载；真正处理审批的是目标机器上的独立常驻后台服务。

用户可以把本仓库地址交给 OpenClaw：

```text
https://github.com/gomoai/dingtalk-auto-approve
```

OpenClaw/Agent 会读取 `SKILL.md`，询问必要参数，然后自动部署后台机器人服务。

## Skill 形态

本仓库提供一组标准生命周期入口，便于 OpenClaw/Agent 机器读取和调用：

| 动作 | 入口 | 用途 |
| --- | --- | --- |
| install | `scripts/install.sh` | 安装运行服务，内部调用 `setup.sh` |
| status | `scripts/status.sh` | 查看服务、进程、心跳和日志路径 |
| doctor | `scripts/doctor.sh` | 诊断配置、依赖、服务管理器和可选钉钉 token |
| upgrade | `scripts/upgrade.sh` | 重新部署脚本，保留 `.env` 和状态文件 |
| uninstall | `scripts/uninstall.sh` | 移除服务注册，可选择保留运行数据 |

机器可读元数据在 `openclaw.skill.json`，配置字段说明在 `references/config-schema.json`。

## 它做什么

- 监听钉钉 Stream 审批事件
- 对符合条件的审批单自动通过
- 记录已处理审批单，避免重复处理
- 发送审批结果和异常告警
- 支持健康监控和兜底自动审批
- 支持 macOS `launchd` 和 Linux `systemd`

## 运行方式要求

审批机器人依赖钉钉 Stream 长连接，必须常驻运行。

- Linux：使用 `systemd` 托管主进程
- macOS：使用 `launchd` 托管主进程
- 定时任务只用于健康检查和兜底审批
- 不要用 OpenClaw 自身 cron/定时任务周期性启动主 bot

健康监控会同时检查进程和 `.bot_heartbeat` 心跳文件。如果进程存在但心跳过期，`monitor.sh` 会重启服务并发送告警。`watchdog.sh` 在 bot 连续启动失败时也会主动告警。

## 目录关系

这个仓库本身是 skill 源码，不是运行目录。

```text
GitHub skill 仓库
  ↓ OpenClaw clone / load
SKILL.md / openclaw.skill.json
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

告警通道支持 fallback，例如：

```env
ALERT_CHANNEL=dingtalk,qclaw
```

表示先尝试钉钉工作通知，失败后再尝试 QClaw/webhook。

## 前置：创建钉钉应用/机器人

如果你还没有钉钉应用，可先参考腾讯云文档中的“创建钉钉机器人”步骤：

- [企业 AI 智能体管控台 ClawPro 接入钉钉指南](https://cloud.tencent.com/document/product/213/129177)

完成后记录以下参数：

- `AppKey` / `Client ID`
- `AppSecret` / `Client Secret`
- `AgentId`

注意：腾讯云文档主要覆盖“创建并接入钉钉机器人”的前置步骤。本项目还需要额外开通工作流/审批相关权限，否则机器人可以启动，但无法自动审批。

## 钉钉权限要求

在钉钉开发者后台为应用开通以下权限：

1. **Stream 事件订阅**
   - 事件：审批任务变更 `bpms_task_change`
   - 用途：实时接收审批任务事件

2. **工作流实例执行权限**
   - 权限码：`qyapi_aflow_execute`
   - API：`POST /v1.0/workflow/processInstances/execute`
   - 用途：自动同意审批
   - 注意：这个权限在普通“权限管理”页面通常搜不到，需要通过 [ExecuteProcessInstance API Explorer](https://open.dingtalk.com/document/api/explore/explorer-page?devType=org&api=workflow_1.0%23ExecuteProcessInstance) 申请开通

3. **工作流实例读权限**
   - API：`/topapi/processinstance/get`
   - 用途：读取审批单详情、表单字段、申请人和系统来源

4. **工作流实例列表/查询权限**
   - API：`/v1.0/workflow/processes/instanceIds/query`（优先，可按 `RUNNING` 过滤）
   - 兼容：`/topapi/processinstance/listids`
   - 用途：兜底扫描近期仍在审批中的实例

5. **工作通知发送权限**
   - API：`/topapi/message/corpconversation/asyncsend_v2`
   - 用途：发送审批成功、失败和兜底告警通知

## 手动部署

如果不通过 OpenClaw，也可以手动部署后台服务：

```bash
git clone https://github.com/gomoai/dingtalk-auto-approve
cd dingtalk-auto-approve
bash scripts/install.sh ~/dingtalk-auto-approve
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
- root 环境安装时会自动 `enable` 并 `restart` 服务，确保当前启动和开机自启
- 使用 `crontab` 运行健康监控和兜底监控

## 安全说明

不要提交以下文件：

- `.env`
- `.approved_state.json`
- `.access_token.json`
- `*.log`
- `.bot.pid`
- `.bot_heartbeat`
- `dingtalk-bot.service`
- `*.plist`

仓库内只应包含模板、脚本和说明，不应包含真实钉钉密钥、webhook 地址或审批数据。

## 关键文件

- `SKILL.md`: OpenClaw/Agent 执行协议
- `openclaw.skill.json`: 部署型 skill 元数据和动作入口
- `scripts/approval_bot.py`: 钉钉审批机器人
- `scripts/dingtalk_client.py`: 钉钉 API 与 access_token 文件缓存
- `scripts/setup.sh`: 后台服务部署脚本
- `scripts/install.sh`: 标准安装入口
- `scripts/status.sh`: 标准状态检查入口
- `scripts/doctor.sh`: 标准诊断入口
- `scripts/upgrade.sh`: 标准升级入口
- `scripts/uninstall.sh`: 标准卸载入口
- `scripts/monitor.sh`: 健康监控
- `scripts/monitor-backup.sh`: 兜底自动审批，处理早于 bot 启动时间的存量 RUNNING 审批单
- `scripts/send-alert.py`: 告警发送工具，支持多通道 fallback
- `references/config-template.env`: 配置模板
- `references/config-schema.json`: 机器可读配置 schema
- `references/dingtalk-permissions.md`: 钉钉权限说明
- `examples/`: OpenClaw、Linux、macOS 和告警配置示例
