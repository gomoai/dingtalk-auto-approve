#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Send alerts through configured channels with fallback."""

import json
import os
import sys
from urllib import request as urllib_req

from dingtalk_client import get_access_token, send_work_notification


def post_json(url, body, headers=None):
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib_req.Request(
        url,
        data=data,
        headers=headers or {"Content-Type": "application/json"},
        method="POST",
    )
    with urllib_req.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))


def send_dingtalk(message):
    agent_id = int(os.environ.get("DINGTALK_AGENT_ID", "0") or "0")
    notify_user_id = os.environ.get("NOTIFY_USER_ID", "")
    if not agent_id or not notify_user_id:
        raise RuntimeError("DINGTALK_AGENT_ID/NOTIFY_USER_ID 未配置")

    token = get_access_token(
        os.environ.get("DINGTALK_APP_KEY", ""),
        os.environ.get("DINGTALK_APP_SECRET", ""),
    )
    return send_work_notification(token, agent_id, notify_user_id, "", message)


def send_webhook(message, channel):
    if channel == "qclaw":
        webhook_url = os.environ.get("QCLAW_WEBHOOK_URL") or os.environ.get("ALERT_WEBHOOK_URL", "")
    else:
        webhook_url = os.environ.get("ALERT_WEBHOOK_URL") or os.environ.get("QCLAW_WEBHOOK_URL", "")
    if not webhook_url:
        raise RuntimeError(f"{channel} webhook 地址未配置")
    return post_json(webhook_url, {"text": message, "content": message})


def iter_channels():
    raw = os.environ.get("ALERT_CHANNEL", "dingtalk")
    for channel in raw.replace(";", ",").split(","):
        channel = channel.strip().lower()
        if channel:
            yield channel


def main():
    message = os.environ.get("ALERT_MESSAGE") or sys.stdin.read().strip()
    if not message:
        print("WARN: ALERT_MESSAGE 为空，跳过发送")
        return 0

    errors = []
    for channel in iter_channels():
        if channel == "none":
            return 0
        try:
            if channel == "dingtalk":
                send_dingtalk(message)
            elif channel in ("qclaw", "webhook"):
                send_webhook(message, channel)
            else:
                raise RuntimeError(f"未知 ALERT_CHANNEL={channel}")
            print(f"OK: 告警已通过 {channel} 发送")
            return 0
        except Exception as exc:
            errors.append(f"{channel}: {exc}")

    print("WARN: 所有告警通道均发送失败: " + " | ".join(errors))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
