#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Shared DingTalk OpenAPI helpers with a file-backed access_token cache."""

from __future__ import annotations

import fcntl
import json
import os
import time
from pathlib import Path
from typing import List, Optional
from urllib import error as urllib_error
from urllib import request as urllib_req
import urllib.parse

SCRIPT_DIR = Path(os.environ.get("SCRIPT_DIR") or Path(__file__).resolve().parent)
TOKEN_CACHE_FILE = Path(os.environ.get("TOKEN_CACHE_FILE") or (SCRIPT_DIR / ".access_token.json"))
TOKEN_SAFETY_SKEW_SECONDS = 200

GET_TOKEN_URL = "https://oapi.dingtalk.com/gettoken"
PROCESS_INSTANCE_GET_URL = "https://oapi.dingtalk.com/topapi/processinstance/get"
PROCESS_INSTANCE_LISTIDS_URL = "https://oapi.dingtalk.com/topapi/processinstance/listids"
PROCESS_INSTANCE_LISTIDS_V1_URL = "https://api.dingtalk.com/v1.0/workflow/processes/instanceIds/query"
PROCESS_INSTANCE_EXECUTE_URL = "https://api.dingtalk.com/v1.0/workflow/processInstances/execute"
WORK_NOTIFICATION_URL = "https://oapi.dingtalk.com/topapi/message/corpconversation/asyncsend_v2"


class DingTalkAPIError(RuntimeError):
    def __init__(self, message: str, payload=None, http_code: Optional[int] = None):
        super().__init__(message)
        self.payload = payload
        self.http_code = http_code


def _json_request(url: str, method: str = "GET", body=None, headers=None, timeout: int = 10) -> dict:
    data = None
    req_headers = dict(headers or {})
    if body is not None:
        if isinstance(body, (bytes, bytearray)):
            data = body
        elif isinstance(body, str):
            data = body.encode("utf-8")
        else:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            req_headers.setdefault("Content-Type", "application/json")
    req = urllib_req.Request(url, data=data, headers=req_headers, method=method)
    try:
        with urllib_req.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib_error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="replace")
        payload = None
        try:
            payload = json.loads(error_body) if error_body else None
        except json.JSONDecodeError:
            payload = {"raw": error_body}
        raise DingTalkAPIError(
            f"HTTP {exc.code} {exc.reason}: {error_body}",
            payload=payload,
            http_code=exc.code,
        ) from exc
    except (urllib_error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise DingTalkAPIError(str(exc)) from exc


def _read_token_cache(cache_file: Path) -> dict:
    if not cache_file.exists():
        return {}
    try:
        with cache_file.open("r", encoding="utf-8") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_SH)
            try:
                data = json.load(handle)
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        if isinstance(data, dict) and data.get("access_token") and data.get("expire_at"):
            return data
    except Exception:
        return {}
    return {}


def _write_token_cache(cache_file: Path, access_token: str, expire_at: float) -> None:
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(cache_file), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.ftruncate(fd, 0)
        os.lseek(fd, 0, os.SEEK_SET)
        payload = json.dumps(
            {"access_token": access_token, "expire_at": expire_at},
            ensure_ascii=False,
        ).encode("utf-8")
        os.write(fd, payload)
        os.fsync(fd)
        os.fchmod(fd, 0o600)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _fetch_access_token(app_key: str, app_secret: str) -> tuple:
    if not app_key or not app_secret:
        raise DingTalkAPIError("DINGTALK_APP_KEY/DINGTALK_APP_SECRET 未配置")
    query = urllib.parse.urlencode({"appkey": app_key, "appsecret": app_secret})
    result = _json_request(f"{GET_TOKEN_URL}?{query}", method="GET")
    if result.get("errcode", 0) not in (0, None) or not result.get("access_token"):
        raise DingTalkAPIError(f"获取 token 失败: {result}", payload=result)
    expires_in = int(result.get("expires_in") or 7200)
    return result["access_token"], max(60, expires_in - TOKEN_SAFETY_SKEW_SECONDS)


def get_access_token(
    app_key: str,
    app_secret: str,
    cache_file: Optional[Path] = None,
    force_refresh: bool = False,
    logger=None,
) -> str:
    """Return a cached access_token, refreshing from DingTalk when needed."""
    cache_path = Path(cache_file or TOKEN_CACHE_FILE)
    now = time.time()
    if not force_refresh:
        cached = _read_token_cache(cache_path)
        expire_at = float(cached.get("expire_at") or 0)
        if cached.get("access_token") and expire_at > now:
            return cached["access_token"]

    token, ttl = _fetch_access_token(app_key, app_secret)
    expire_at = now + ttl
    _write_token_cache(cache_path, token, expire_at)
    if logger:
        logger.info("access_token 已刷新")
    return token


def get_process_instance(access_token: str, process_instance_id: str) -> dict:
    url = f"{PROCESS_INSTANCE_GET_URL}?access_token={urllib.parse.quote(access_token)}"
    body = urllib.parse.urlencode({"process_instance_id": process_instance_id}).encode()
    result = _json_request(url, method="POST", body=body, headers={"Content-Type": "application/x-www-form-urlencoded"})
    if result.get("errcode") not in (0, None):
        raise DingTalkAPIError(f"获取审批实例失败: {result}", payload=result)
    return result.get("process_instance") or {}


def execute_approve(
    access_token: str,
    process_instance_id: str,
    remark: str = "自动通过",
    result: str = "agree",
    task_id: Optional[int] = None,
    actioner_user_id: str = "",
) -> dict:
    body = {
        "processInstanceId": process_instance_id,
        "remark": remark,
        "result": result,
        "actionerUserId": actioner_user_id,
    }
    if task_id:
        body["taskId"] = task_id
    return _json_request(
        PROCESS_INSTANCE_EXECUTE_URL,
        method="POST",
        body=body,
        headers={
            "x-acs-dingtalk-access-token": access_token,
            "Content-Type": "application/json",
        },
    )


def send_work_notification(access_token: str, agent_id: int, user_id: str, title: str, content: str) -> dict:
    if not user_id:
        return {"errcode": -1, "errmsg": "NOTIFY_USER_ID 未配置"}
    url = f"{WORK_NOTIFICATION_URL}?access_token={urllib.parse.quote(access_token)}"
    text = f"{title}\n{content}" if title else content
    return _json_request(
        url,
        method="POST",
        body={
            "agent_id": agent_id,
            "userid_list": user_id,
            "msg": {
                "msgtype": "text",
                "text": {"content": text},
            },
        },
    )


def _extract_id_page(payload: dict) -> tuple:
    data = payload.get("result", payload) if isinstance(payload, dict) else {}
    if not isinstance(data, dict):
        data = {}
    ids = data.get("list") or data.get("ids") or []
    next_token = data.get("nextToken", data.get("next_token", data.get("next_cursor")))
    return list(ids), next_token


def _has_more(next_token) -> bool:
    if next_token in (None, "", 0, "0"):
        return False
    return True


def _list_running_ids_v1(access_token: str, process_code: str, start_ts: int, end_ts: int, max_pages: int) -> List[str]:
    ids: List[str] = []
    next_token = 0
    for _ in range(max_pages):
        payload = _json_request(
            PROCESS_INSTANCE_LISTIDS_V1_URL,
            method="POST",
            body={
                "processCode": process_code,
                "startTime": start_ts,
                "endTime": end_ts,
                "nextToken": next_token,
                "maxResults": 20,
                "statuses": ["RUNNING"],
            },
            headers={
                "x-acs-dingtalk-access-token": access_token,
                "Content-Type": "application/json",
            },
        )
        if payload.get("errcode") not in (0, None):
            raise DingTalkAPIError(f"获取 RUNNING 审批实例列表失败: {payload}", payload=payload)
        page_ids, next_token = _extract_id_page(payload)
        ids.extend(str(item) for item in page_ids if item)
        if not _has_more(next_token):
            break
        try:
            next_token = int(next_token)
        except (TypeError, ValueError):
            break
    return ids


def _list_ids_legacy(access_token: str, process_code: str, start_ts: int, end_ts: int, max_pages: int) -> List[str]:
    ids: List[str] = []
    cursor = 0
    for _ in range(max_pages):
        url = f"{PROCESS_INSTANCE_LISTIDS_URL}?access_token={urllib.parse.quote(access_token)}"
        body = urllib.parse.urlencode({
            "process_code": process_code,
            "start_time": start_ts,
            "end_time": end_ts,
            "size": 20,
            "cursor": cursor,
        }).encode()
        payload = _json_request(
            url,
            method="POST",
            body=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if payload.get("errcode") not in (0, None):
            raise DingTalkAPIError(f"获取审批实例列表失败: {payload}", payload=payload)
        page_ids, next_token = _extract_id_page(payload)
        ids.extend(str(item) for item in page_ids if item)
        if not _has_more(next_token):
            break
        try:
            cursor = int(next_token)
        except (TypeError, ValueError):
            break
    return ids


def list_running_instance_ids(
    access_token: str,
    process_code: str,
    start_ts: int,
    end_ts: int,
    max_pages: int = 10,
    logger=None,
) -> tuple:
    """List instance IDs. Prefer RUNNING-only v1 API, fall back to legacy listids.

    Returns (ids, used_running_filter).
    """
    try:
        ids = _list_running_ids_v1(access_token, process_code, start_ts, end_ts, max_pages)
        return ids, True
    except DingTalkAPIError as exc:
        if logger:
            logger.warning("RUNNING 过滤接口不可用，回退旧版 listids: %s", exc)
        ids = _list_ids_legacy(access_token, process_code, start_ts, end_ts, max_pages)
        return ids, False
