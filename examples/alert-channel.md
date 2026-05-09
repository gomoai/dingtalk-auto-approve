# 告警通道示例

默认使用钉钉工作通知：

```env
ALERT_CHANNEL=dingtalk
DINGTALK_AGENT_ID=123456
NOTIFY_USER_ID=manager-userid
```

使用 QClaw/webhook：

```env
ALERT_CHANNEL=qclaw
QCLAW_WEBHOOK_URL=https://example.com/qclaw/webhook
```

使用 fallback：

```env
ALERT_CHANNEL=dingtalk,qclaw
QCLAW_WEBHOOK_URL=https://example.com/qclaw/webhook
```

含义是先尝试钉钉工作通知；如果钉钉 token、AgentId、接收人或发送 API 失败，再尝试 QClaw/webhook。

完全关闭告警：

```env
ALERT_CHANNEL=none
```

不建议长期关闭告警，因为 `watchdog.sh`、`monitor.sh` 和 `monitor-backup.sh` 都依赖告警通知服务异常。
