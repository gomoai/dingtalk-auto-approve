#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
钉钉审批自动通过机器人 - Stream 模式
监听审批任务变更事件，自动通过"账号权限申请单"

判断逻辑（5 层过滤 → 执行 → 通知）：
  过滤1：processCode == 目标审批流
  过滤2：事件类型 == start，若事件携带 status 则要求 status == RUNNING
  过滤3：幂等去重（instanceId 不重复处理，持久化存储）
  过滤4：审批人 userId/staffId == 当前用户
  过滤5：表单字段「系统来源」== "AI工具账号"

API 使用：
  - 审批通过：POST /v1.0/workflow/processInstances/execute
  - 审批详情：POST /topapi/processinstance/get
  - 工作通知：POST /topapi/message/corpconversation/asyncsend_v2

部署：
  cd dingtalk-auto-approve
  python3 approval_bot.py
"""

import os
import time
import json
import logging
from typing import Tuple
from pathlib import Path
from urllib import request as urllib_req
from urllib import error as urllib_error
import urllib.parse

import dingtalk_stream
from dingtalk_stream import AckMessage

# ============================================================
# 配置区
# ============================================================
# 这些值由 load_config() 从 .env 填充，保留默认值便于本地调试。
TARGET_PROCESS_CODE = ""
TARGET_SYSTEM_SOURCE = "AI工具账号"
ACTIONER_USER_ID = ""
NOTIFY_USER_ID = ""

# 幂等持久化文件
STATE_FILE = Path(__file__).resolve().parent / ".approved_state.json"

# ============================================================
# 配置加载（只读一次 .env）
# ============================================================
def _parse_int(value: str, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def load_config() -> dict:
    """从 .env 文件加载配置，优先使用环境变量"""
    env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if os.path.exists(env_path):
        file_env = {}
        with open(env_path, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    file_env[key.strip()] = value.strip()
        for key, value in file_env.items():
            os.environ.setdefault(key, value)

    return {
        "app_key": os.environ.get("DINGTALK_APP_KEY", ""),
        "app_secret": os.environ.get("DINGTALK_APP_SECRET", ""),
        "agent_id": _parse_int(os.environ.get("DINGTALK_AGENT_ID", "0")),
        "process_code": os.environ.get("TARGET_PROCESS_CODE", ""),
        "target_system_source": os.environ.get("TARGET_SYSTEM_SOURCE", TARGET_SYSTEM_SOURCE),
        "actioner_user_id": os.environ.get("ACTIONER_USER_ID", ""),
        "notify_user_id": os.environ.get("NOTIFY_USER_ID", ""),
    }


# ============================================================
# 幂等持久化管理
# ============================================================
class ApprovedState:
    """持久化已审批实例状态"""

    MAX_ENTRIES = 10000
    CLEANUP_THRESHOLD = MAX_ENTRIES + 1000

    def __init__(self, state_file: Path):
        self.state_file = state_file
        self.instances: dict = {}  # {instance_id: {"approved_at": timestamp, "applicant": name}}
        self._load()

    def _load(self):
        if self.state_file.exists():
            try:
                with open(self.state_file, "r") as f:
                    data = json.load(f)
                    self.instances = data.get("instances", {})
                logging.getLogger("approval_bot").info(
                    "已加载 %d 条已审批记录", len(self.instances)
                )
            except Exception as e:
                logging.getLogger("approval_bot").warning("加载状态文件失败: %s，从空状态开始", e)
                self.instances = {}

    def _save(self):
        try:
            with open(self.state_file, "w") as f:
                json.dump({"instances": self.instances}, f, ensure_ascii=False)
        except Exception as e:
            logging.getLogger("approval_bot").warning("保存状态文件失败: %s", e)

    def add(self, instance_id: str, applicant: str = ""):
        self.instances[instance_id] = {
            "approved_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "applicant": applicant,
        }
        if len(self.instances) > self.CLEANUP_THRESHOLD:
            # 保留最新的 MAX_ENTRIES 条
            sorted_items = sorted(
                self.instances.items(), key=lambda x: x[1].get("approved_at", ""), reverse=True
            )
            self.instances = dict(sorted_items[:self.MAX_ENTRIES])
        self._save()

    def contains(self, instance_id: str) -> bool:
        return instance_id in self.instances

    def __len__(self):
        return len(self.instances)


# ============================================================
# 日志配置
# ============================================================
def setup_logger():
    script_dir = Path(__file__).resolve().parent
    logger = logging.getLogger("approval_bot")
    logger.setLevel(logging.INFO)

    console = logging.StreamHandler()
    console.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)-8s %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
    )
    logger.addHandler(console)

    log_file = script_dir / "bot.log"
    file_handler = logging.FileHandler(log_file, encoding="utf-8")
    file_handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)-8s %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
    )
    logger.addHandler(file_handler)

    return logger


# ============================================================
# 钉钉 API 调用
# ============================================================
def api_get_access_token(app_key: str, app_secret: str) -> str:
    """获取钉钉 access_token"""
    url = f"https://oapi.dingtalk.com/gettoken?appkey={app_key}&appsecret={app_secret}"
    req = urllib_req.Request(url, method="GET")
    with urllib_req.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read().decode("utf-8"))
        if result.get("errcode") == 0:
            return result["access_token"]
        raise RuntimeError(f"获取 token 失败: {result}")


def api_get_process_instance(access_token: str, process_instance_id: str) -> dict:
    """获取审批实例详情（申请人、表单内容等）"""
    url = f"https://oapi.dingtalk.com/topapi/processinstance/get?access_token={access_token}"
    body = urllib.parse.urlencode({"process_instance_id": process_instance_id}).encode()
    req = urllib_req.Request(url, data=body, method="POST")
    with urllib_req.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read().decode("utf-8"))
        if result.get("errcode") != 0:
            raise RuntimeError(f"获取审批实例失败: {result}")
        return result.get("process_instance", {})


def api_execute_approve(access_token: str, process_instance_id: str,
                        remark: str = "自动通过", result: str = "agree",
                        task_id: int = None, actioner_user_id: str = "") -> dict:
    """执行审批同意/拒绝（新版 API）
    
    API: POST /v1.0/workflow/processInstances/execute
    需要权限: qyapi_aflow_execute
    """
    url = "https://api.dingtalk.com/v1.0/workflow/processInstances/execute"
    body_data = {
        "processInstanceId": process_instance_id,
        "remark": remark,
        "result": result,  # "agree" 或 "refuse"
        "actionerUserId": actioner_user_id,
    }
    if task_id:
        body_data["taskId"] = task_id
    
    body = json.dumps(body_data).encode()
    req = urllib_req.Request(url, data=body, headers={
        "x-acs-dingtalk-access-token": access_token,
        "Content-Type": "application/json"
    }, method="POST")
    try:
        with urllib_req.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib_error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"审批执行 API 失败: HTTP {exc.code} {exc.reason}: {error_body}") from exc


def api_send_work_notification(access_token: str, agent_id: int, 
                                user_id: str, title: str, content: str) -> dict:
    """发送工作通知到指定用户"""
    if not user_id:
        return {"errcode": -1, "errmsg": "NOTIFY_USER_ID 未配置"}
    url = f"https://oapi.dingtalk.com/topapi/message/corpconversation/asyncsend_v2?access_token={access_token}"
    body = json.dumps({
        "agent_id": agent_id,
        "userid_list": user_id,
        "msg": {
            "msgtype": "text",
            "text": {"content": f"{title}\n{content}"},
        },
    }).encode()
    req = urllib_req.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
    with urllib_req.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))


# ============================================================
# 表单解析
# ============================================================
def get_form_field(form_values: list, field_name: str) -> str:
    """根据字段名从表单中提取值"""
    for item in form_values:
        if item.get("name") == field_name:
            return str(item.get("value", ""))
    return ""


def extract_applicant(instance: dict, form_values: list, title: str) -> str:
    """尽量从不同钉钉返回格式里提取申请人名称。"""
    for key in ("originator_name", "originator_user_name", "originatorUserName"):
        value = instance.get(key)
        if value:
            return str(value)

    for field_name in ("申请人", "姓名", "提交人", "申请姓名", "用户姓名"):
        value = get_form_field(form_values, field_name)
        if value:
            return value

    if "提交的" in title:
        name = title.split("提交的", 1)[0].strip()
        if name:
            return name

    for key in ("originator_userid", "originatorUserId", "userid", "userId"):
        value = instance.get(key)
        if value:
            return str(value)

    return "未知"


def parse_form_summary(form_values: list) -> str:
    """将审批表单内容解析为可读文本"""
    lines = []
    for item in form_values:
        name = item.get("name", "")
        value = item.get("value", "")
        if isinstance(value, list):
            value = ", ".join(str(v) for v in value if v)
        elif isinstance(value, dict):
            value = json.dumps(value, ensure_ascii=False)
        if name and value:
            lines.append(f"{name}: {value}")
    return "\n".join(lines) if lines else "无详细内容"


def get_first_value(data: dict, *keys: str) -> str:
    """按多个可能字段名取第一个非空值。"""
    for key in keys:
        value = data.get(key)
        if value not in (None, ""):
            return value
    return ""


def normalize_event_data(event_data: dict) -> dict:
    """兼容钉钉 Stream 事件顶层 payload 和 data 嵌套 payload。"""
    if isinstance(event_data.get("data"), dict):
        nested = event_data["data"]
        merged = dict(event_data)
        merged.update(nested)
        return merged
    return event_data


# ============================================================
# 事件处理器
# ============================================================
class ApprovalAutoApproveHandler(dingtalk_stream.EventHandler):
    """审批任务变更事件处理器"""

    def __init__(self, logger, app_key, app_secret, state: ApprovedState, 
                 agent_id: int):
        super().__init__()
        self.logger = logger
        self.app_key = app_key
        self.app_secret = app_secret
        self._token = None
        self._token_expire = 0
        self._state = state
        self._agent_id = agent_id

    def _get_token(self) -> str:
        """获取并缓存 access_token"""
        now = time.time()
        if self._token and now < self._token_expire:
            return self._token
        self._token = api_get_access_token(self.app_key, self.app_secret)
        self._token_expire = now + 7000
        self.logger.info("access_token 已刷新")
        return self._token

    @staticmethod
    def _is_approve_success(result: dict) -> bool:
        """判断审批执行是否成功（兼容多种返回格式）"""
        # 格式1: {"success": true}
        if result.get("success") is True:
            return True
        # 格式2: {"result": true}
        if result.get("result") is True:
            return True
        # 格式3: {"errcode": 0}
        if result.get("errcode") == 0:
            return True
        # 格式4: 有 success 字段且非 false
        if "success" in result and result["success"] is not False:
            return True
        return False

    async def process(self, event: dingtalk_stream.EventMessage) -> Tuple[int, str]:
        event_type = event.headers.event_type
        if event_type != "bpms_task_change":
            return AckMessage.STATUS_OK, "OK"

        event_data = event.data or {}
        data = normalize_event_data(event_data)
        process_code = get_first_value(data, "processCode", "process_code")
        status = get_first_value(data, "status", "processInstanceStatus")
        instance_id = get_first_value(data, "processInstanceId", "process_instance_id")
        bpms_type = get_first_value(data, "type", "eventType", "event_type")
        title = get_first_value(data, "title", "processInstanceTitle")
        current_approver = get_first_value(data, "userId", "userid", "staffId", "staffid", "staff_id")
        task_id = get_first_value(data, "taskId", "taskid", "task_id", "activityId", "activity_id")
        # taskId 可能是字符串或整数，API 需要整数
        if task_id:
            try:
                task_id = int(task_id)
            except (ValueError, TypeError):
                task_id = None

        self.logger.info(
            "审批事件 | %s | 流程=%s | 标题=%s | 状态=%s | 审批人=%s | 实例=%s",
            bpms_type, process_code, title, status or "未提供", current_approver, instance_id,
        )

        # ── 过滤1：目标审批流 ──
        if process_code != TARGET_PROCESS_CODE:
            return AckMessage.STATUS_OK, "OK"

        # ── 过滤2：只处理 start；如果事件携带状态，则要求 RUNNING ──
        if bpms_type != "start":
            return AckMessage.STATUS_OK, "OK"
        if status and status != "RUNNING":
            return AckMessage.STATUS_OK, "OK"

        # ── 过滤3：幂等去重（持久化） ──
        if self._state.contains(instance_id):
            self.logger.info("已处理过的实例，跳过: %s", instance_id)
            return AckMessage.STATUS_OK, "OK"

        # ── 过滤4：审批人校验 ──
        if ACTIONER_USER_ID and current_approver and current_approver != ACTIONER_USER_ID:
            self.logger.info("非当前审批人(userId/staffId=%s)，跳过", current_approver)
            return AckMessage.STATUS_OK, "OK"

        # ── 拉取审批实例详情（用于过滤5 + 通知内容） ──
        try:
            token = self._get_token()
            instance = api_get_process_instance(token, instance_id)
        except Exception as e:
            self.logger.warning("获取审批实例详情失败: %s，跳过", e)
            return AckMessage.STATUS_OK, "OK"

        form_values = instance.get("form_component_values", [])
        system_source = get_form_field(form_values, "系统来源")
        applicant = extract_applicant(instance, form_values, title)
        form_summary = parse_form_summary(form_values)

        # ── 过滤5：系统来源必须是"AI工具账号" ──
        if system_source != TARGET_SYSTEM_SOURCE:
            self.logger.info(
                "系统来源不匹配(实际=%s, 期望=%s)，跳过: %s",
                system_source, TARGET_SYSTEM_SOURCE, title,
            )
            return AckMessage.STATUS_OK, "OK"

        # ── 执行自动通过 ──
        self.logger.info("✅ 全部条件满足，执行自动通过: %s (申请人: %s, 系统来源: %s)", 
                         title, applicant, system_source)
        try:
            result = api_execute_approve(
                token,
                instance_id,
                remark="自动通过",
                task_id=task_id,
                actioner_user_id=ACTIONER_USER_ID,
            )
            self.logger.info("审批 API 返回: %s", json.dumps(result, ensure_ascii=False))

            if self._is_approve_success(result):
                self._state.add(instance_id, applicant)
                self.logger.info("✅ 自动通过成功: %s (申请人: %s)", title, applicant)
                self._send_notify(
                    token, "✅ 审批自动通过成功",
                    f"审批标题: {title}\n申请人: {applicant}\n审批单号: {instance_id}\n\n申请内容:\n{form_summary}",
                )
            else:
                self.logger.error("❌ 自动通过失败: %s", result)
                self._send_notify(
                    token, "❌ 审批自动通过失败",
                    f"审批标题: {title}\n申请人: {applicant}\n审批单号: {instance_id}\n\n失败原因: {json.dumps(result, ensure_ascii=False)}\n\n申请内容:\n{form_summary}",
                )
        except Exception as e:
            self.logger.error("❌ 自动通过异常: %s", e)
            try:
                self._send_notify(
                    self._token or "", "❌ 审批自动通过异常",
                    f"审批标题: {title}\n审批单号: {instance_id}\n\n异常信息: {e}",
                )
            except Exception:
                pass

        return AckMessage.STATUS_OK, "OK"

    def _send_notify(self, token: str, title: str, content: str):
        """发送工作通知"""
        if not NOTIFY_USER_ID:
            self.logger.warning("NOTIFY_USER_ID 未配置，跳过通知发送")
            return
        try:
            result = api_send_work_notification(token, self._agent_id, NOTIFY_USER_ID, title, content)
            if result.get("errcode") == 0:
                self.logger.info("📩 通知已发送: %s", title)
            else:
                self.logger.error("📩 通知发送失败: %s", result)
        except Exception as e:
            self.logger.error("📩 通知发送异常: %s", e)


# ============================================================
# 启动入口
# ============================================================
def main():
    logger = setup_logger()
    config = load_config()

    if not config["app_key"] or not config["app_secret"]:
        raise ValueError("请配置 DINGTALK_APP_KEY 和 DINGTALK_APP_SECRET")
    if not config["process_code"]:
        raise ValueError("请配置 TARGET_PROCESS_CODE")
    if not config["actioner_user_id"]:
        raise ValueError("请配置 ACTIONER_USER_ID")

    global TARGET_PROCESS_CODE, TARGET_SYSTEM_SOURCE, ACTIONER_USER_ID, NOTIFY_USER_ID
    TARGET_PROCESS_CODE = config["process_code"]
    TARGET_SYSTEM_SOURCE = config["target_system_source"]
    ACTIONER_USER_ID = config["actioner_user_id"]
    NOTIFY_USER_ID = config["notify_user_id"]

    # 加载持久化状态
    state = ApprovedState(STATE_FILE)

    logger.info("=" * 50)
    logger.info("钉钉审批自动通过机器人启动")
    logger.info("目标审批流: %s", TARGET_PROCESS_CODE)
    logger.info("目标系统来源: %s", TARGET_SYSTEM_SOURCE)
    logger.info("审批执行人: %s", ACTIONER_USER_ID)
    logger.info("通知接收人: %s", NOTIFY_USER_ID or "未配置")
    logger.info("已加载审批记录: %d 条", len(state))
    logger.info("=" * 50)

    credential = dingtalk_stream.Credential(config["app_key"], config["app_secret"])
    client = dingtalk_stream.DingTalkStreamClient(credential)

    handler = ApprovalAutoApproveHandler(
        logger, config["app_key"], config["app_secret"], state, config["agent_id"]
    )
    client.register_all_event_handler(handler)

    logger.info("Stream 连接建立中...")
    client.start_forever()


if __name__ == "__main__":
    main()
