#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Send alerts through configured channels with fallback."""

import json
import os
import sys
import urllib.request


def post_json(url, body, headers=None):
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers=headers or {"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))


def get_dingtalk_token():
    app_key = os.environ.get("DINGTALK_APP_KEY", "")
    app_secret = os.environ.get("DINGTALK_APP_SECRET", "")
    if not app_key or not app_secret:
        raise RuntimeError("DINGTALK_APP_KEY/DINGTALK_APP_SECRET 未配置")

    token_url = f"https://oapi.dingtalk.com/gettoken?appkey={app_key}&appsecret={app_secret}"
    with urllib.request.urlopen(token_url, timeout=10) as resp:
        token_result = json.loads(resp.read().decode("utf-8"))
    token = token_result.get("access_token")
    if not token:
        raise RuntimeError(f"获取钉钉 token 失败: {token_result}")
    return token


def send_dingtalk(message):
    agent_id = int(os.environ.get("DINGTALK_AGENT_ID", "0") or "0")
    notify_user_id = os.environ.get("NOTIFY_USER_ID", "")
    if not agent_id or not notify_user_id:
        raise RuntimeError("DINGTALK_AGENT_ID/NOTIFY_USER_ID 未配置")

    token = get_dingtalk_token()
    url = f"https://oapi.dingtalk.com/topapi/message/corpconversation/asyncsend_v2?access_token={token}"
    return post_json(
        url,
        {
            "agent_id": agent_id,
            "userid_list": notify_user_id,
            "msg": {"msgtype": "text", "text": {"content": message}},
        },
    )


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
