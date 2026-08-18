#!/bin/bash
# 审批兜底监控 - 每 15 分钟运行一次
# 只扫描最近 BACKUP_LOOKBACK_HOURS 小时内仍 RUNNING 的审批单（默认 24 小时）

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/.env"
    set +a
fi

LOGFILE="$SCRIPT_DIR/monitor-backup.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"; }

SCRIPT_DIR="$SCRIPT_DIR" python3 << 'PYEOF'
import json, time, sys, os, logging
from datetime import datetime
from urllib import request as urllib_request

SCRIPT_DIR = os.environ.get("SCRIPT_DIR", os.getcwd())
sys.path.insert(0, SCRIPT_DIR)
from dingtalk_client import (
    execute_approve,
    get_access_token,
    get_process_instance,
    list_running_instance_ids,
    send_work_notification,
)

PROCESS_CODE = os.environ.get("TARGET_PROCESS_CODE", "")
TARGET_SYSTEM_SOURCE = os.environ.get("TARGET_SYSTEM_SOURCE", "AI工具账号")
STATE_FILE = os.environ.get("STATE_FILE", os.path.join(SCRIPT_DIR, ".approved_state.json"))
ALERT_THRESHOLD_MIN = int(os.environ.get("ALERT_THRESHOLD_MIN", "5") or "5")
BACKUP_LOOKBACK_HOURS = int(os.environ.get("BACKUP_LOOKBACK_HOURS", "24") or "24")
BACKUP_LOOKBACK_HOURS = max(1, min(BACKUP_LOOKBACK_HOURS, 168))
BACKUP_AUTO_APPROVE = os.environ.get("BACKUP_AUTO_APPROVE", "true").lower() in ("1", "true", "yes", "y")
ACTIONER_USER_ID = os.environ.get("ACTIONER_USER_ID", "")
NOTIFY_USER_ID = os.environ.get("NOTIFY_USER_ID", "")
AGENT_ID = int(os.environ.get("DINGTALK_AGENT_ID", "0") or "0")
ALERT_CHANNEL = os.environ.get("ALERT_CHANNEL", "dingtalk").lower()
SERVICE_NAME = os.environ.get("SERVICE_NAME", "dingtalk-bot.service")
LAUNCHD_LABEL = os.environ.get("LAUNCHD_LABEL", "com.gomoai.dingtalk-auto-approve")
OS_NAME = os.uname().sysname if hasattr(os, "uname") else ""
LOGGER = logging.getLogger("monitor-backup")
logging.basicConfig(level=logging.INFO, format="%(message)s")

def post_json(url, body, headers=None):
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib_request.Request(url, data=data, headers=headers or {"Content-Type": "application/json"}, method="POST")
    with urllib_request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))

def get_token():
    app_key = os.environ.get("DINGTALK_APP_KEY", "")
    app_secret = os.environ.get("DINGTALK_APP_SECRET", "")
    if not app_key or not app_secret:
        return None
    try:
        return get_access_token(app_key, app_secret, logger=LOGGER)
    except Exception as exc:
        print(f"ERROR: 无法获取钉钉 token: {exc}")
        return None

def load_approved():
    """加载 bot 自动通过的记录"""
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r") as f:
                data = json.load(f)
                return set(data.get("instances", {}).keys())
        except Exception:
            pass
    return set()

def save_approved(instance_id, applicant="", method="手动"):
    """保存已审批记录（手动通过的也记下来，避免重复告警）"""
    data = {"instances": {}}
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r") as f:
                data = json.load(f)
        except Exception:
            data = {"instances": {}}
    
    if instance_id not in data["instances"]:
        data["instances"][instance_id] = {
            "approved_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "applicant": applicant,
            "method": method,
        }
        try:
            with open(STATE_FILE, "w") as f:
                json.dump(data, f, ensure_ascii=False)
        except Exception:
            pass

def is_approve_success(result):
    if result.get("success") is True:
        return True
    if result.get("result") is True:
        return True
    if result.get("errcode") == 0:
        return True
    if "success" in result and result["success"] is not False:
        return True
    return False

RUNNING_STATES = {"RUNNING", "NEW", "TODO", "PENDING", "PROCESSING", "WAITING"}
DONE_RESULTS = {"AGREE", "REFUSE", "TERMINATE", "TERMINATED", "CANCEL", "CANCELED", "REJECT", "PASS"}

def _to_upper_text(value):
    return str(value).strip().upper() if value is not None else ""

def _to_text(value):
    return str(value).strip() if value is not None else ""

def collect_task_candidates(value, out):
    """递归收集审批详情中的 task 候选节点。"""
    if isinstance(value, dict):
        task_id = None
        for key in ("taskId", "taskid", "task_id", "activityId", "activity_id"):
            raw = value.get(key)
            if raw in (None, ""):
                continue
            try:
                task_id = int(raw)
                break
            except (TypeError, ValueError):
                task_id = None
        if task_id:
            status = _to_upper_text(value.get("status", value.get("taskStatus", value.get("state", ""))))
            result = _to_upper_text(value.get("result", value.get("operation_result", "")))
            user_ids = set()
            for key in (
                "userId", "userid", "staffId", "staffid", "staff_id",
                "approverUserId", "approver_userid", "actionerUserId", "actioner_userid",
            ):
                uid = _to_text(value.get(key))
                if uid:
                    user_ids.add(uid)
            out.append({
                "task_id": task_id,
                "status": status,
                "result": result,
                "user_ids": user_ids,
            })
        for child in value.values():
            collect_task_candidates(child, out)
    elif isinstance(value, list):
        for child in value:
            collect_task_candidates(child, out)

def find_running_task(detail, expected_user_id=""):
    """从审批详情中提取可执行任务（RUNNING + 未结束 + 尽量匹配审批人）。"""
    candidates = []
    collect_task_candidates(detail, candidates)
    if not candidates:
        return None, []

    running = []
    for c in candidates:
        status = c["status"]
        result = c["result"]
        status_running = status in RUNNING_STATES
        # 某些返回不带 status/result，保守认为可能是待办；但若明确已结束则排除。
        status_unknown = (not status and result in ("", "NONE"))
        if (status_running or status_unknown) and result not in DONE_RESULTS:
            running.append(c)

    if not running:
        return None, candidates

    if expected_user_id:
        for c in running:
            if expected_user_id in c["user_ids"]:
                return c["task_id"], running
        return None, running

    return running[0]["task_id"], running

def is_actioner_in_approval_chain(detail, actioner_user_id):
    """检查 actioner 是否出现在审批链任意任务中，避免无关审批单误告警。"""
    if not actioner_user_id:
        return True
    all_tasks = []
    collect_task_candidates(detail, all_tasks)
    for task in all_tasks:
        if actioner_user_id in task["user_ids"]:
            return True
    return False

def parse_form_summary(form_values):
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

def get_form_field(form_values, field_name):
    for item in form_values:
        if item.get("name") == field_name:
            return str(item.get("value", ""))
    return ""

def extract_applicant(detail, form_values, title):
    """尽量从不同钉钉返回格式里提取申请人名称。"""
    for key in ("originator_name", "originator_user_name", "originatorUserName"):
        value = detail.get(key)
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
        value = detail.get(key)
        if value:
            return str(value)

    return "未知"

def append_check_lines(lines):
    lines.append("请检查：")
    lines.append("1. ACTIONER_USER_ID 是否仍是该审批单当前审批人")
    lines.append("2. 钉钉应用是否已开通 qyapi_aflow_execute 权限")
    lines.append("3. 审批 API 返回信息 / 异常信息")
    lines.append(f"4. bot 日志: tail {os.path.join(SCRIPT_DIR, 'bot.log')}")
    lines.append(f"5. 兜底日志: tail {os.path.join(SCRIPT_DIR, 'monitor-backup.log')}")
    if OS_NAME == "Darwin":
        lines.append(f"6. 服务状态: launchctl print gui/$(id -u)/{LAUNCHD_LABEL}")
    else:
        lines.append(f"6. 服务状态: systemctl status {SERVICE_NAME}")
    lines.append("7. 如需手动处理，请在钉钉审批中操作")

def is_manually_approved(detail):
    """检查审批单是否已被当前用户手动通过
    
    判断逻辑：操作记录中有 ACTIONER_USER_ID 的 AGREE 操作
    """
    if not ACTIONER_USER_ID:
        return False
    ops = detail.get("operation_records", [])
    for op in ops:
        if op.get("userid") == ACTIONER_USER_ID and op.get("operation_result") == "AGREE":
            return True
    return False

def iter_alert_channels():
    for channel in ALERT_CHANNEL.replace(";", ",").split(","):
        channel = channel.strip().lower()
        if channel:
            yield channel

def send_alert(token, message):
    errors = []
    for channel in iter_alert_channels():
        if channel == "none":
            return
        try:
            if channel == "dingtalk":
                send_dingtalk_alert(token, message)
            elif channel in ("qclaw", "webhook"):
                send_webhook_alert(message, channel)
            else:
                raise RuntimeError(f"未知 ALERT_CHANNEL={channel}")
            print(f"OK: 告警已通过 {channel} 发送")
            return
        except Exception as exc:
            errors.append(f"{channel}: {exc}")
    if errors:
        raise RuntimeError("所有告警通道均发送失败: " + " | ".join(errors))

def send_dingtalk_alert(token, message):
    if not token or not NOTIFY_USER_ID or not AGENT_ID:
        raise RuntimeError("钉钉告警配置不完整")
    result = send_work_notification(token, AGENT_ID, NOTIFY_USER_ID, "", message)
    if result.get("errcode") not in (0, None):
        raise RuntimeError(f"钉钉告警发送失败: {result}")
    return result

def send_webhook_alert(message, channel):
    if channel == "qclaw":
        webhook_url = os.environ.get("QCLAW_WEBHOOK_URL") or os.environ.get("ALERT_WEBHOOK_URL", "")
    else:
        webhook_url = os.environ.get("ALERT_WEBHOOK_URL") or os.environ.get("QCLAW_WEBHOOK_URL", "")
    if not webhook_url:
        raise RuntimeError(f"{channel} webhook 地址未配置")
    return post_json(webhook_url, {"text": message, "content": message})

if not PROCESS_CODE:
    print("ERROR: 请配置 TARGET_PROCESS_CODE")
    sys.exit(1)
if BACKUP_AUTO_APPROVE and not ACTIONER_USER_ID:
    print("ERROR: 兜底自动审批需要配置 ACTIONER_USER_ID")
    sys.exit(1)

token = get_token()
if not token:
    print("ERROR: 无法获取钉钉 token")
    sys.exit(1)

approved = load_approved()
now = time.time()
start_ts = int((now - BACKUP_LOOKBACK_HOURS * 3600) * 1000)
end_ts = int(now * 1000)

instances, used_running_filter = list_running_instance_ids(
    token, PROCESS_CODE, start_ts, end_ts, logger=LOGGER
)
if not used_running_filter:
    print("WARN: RUNNING 过滤接口不可用，已回退旧版 listids")
failed = []
alert_only = []
approved_by_backup = []
fetched = 0
skipped_state = 0
skipped_remembered = 0

for inst_id in instances:
    if inst_id in approved:
        skipped_state += 1
        continue

    detail = get_process_instance(token, inst_id)
    fetched += 1
    if not detail:
        continue

    status = detail.get("status", "")
    form_values = detail.get("form_component_values", [])
    system_source = get_form_field(form_values, "系统来源")
    title = detail.get("title", "")
    applicant = extract_applicant(detail, form_values, title)
    create_time_str = detail.get("create_time", "")

    # 已结束或不匹配的单记住，避免下一轮重复拉详情。
    if status != "RUNNING":
        save_approved(inst_id, applicant, "跳过:已结束")
        skipped_remembered += 1
        continue
    if system_source != TARGET_SYSTEM_SOURCE:
        save_approved(inst_id, applicant, "跳过:系统来源不匹配")
        skipped_remembered += 1
        continue
    if is_manually_approved(detail):
        save_approved(inst_id, applicant, "手动")
        skipped_remembered += 1
        continue

    # 计算等待时长
    if create_time_str:
        try:
            ct = datetime.strptime(create_time_str, "%Y-%m-%d %H:%M:%S")
            create_ts = ct.timestamp()
            wait_minutes = int((now - create_ts) / 60)
        except Exception:
            wait_minutes = 0
    else:
        wait_minutes = 0

    if wait_minutes >= ALERT_THRESHOLD_MIN:
        task_id, running_tasks = find_running_task(detail, ACTIONER_USER_ID)
        running_approvers = sorted({uid for task in running_tasks for uid in task["user_ids"] if uid})
        item = {
            "instance_id": inst_id,
            "title": title,
            "applicant": applicant,
            "system_source": system_source,
            "wait_minutes": wait_minutes,
            "create_time": create_time_str,
            "form_summary": parse_form_summary(form_values),
            "task_id": task_id,
            "running_task_approvers": running_approvers,
        }
        if not BACKUP_AUTO_APPROVE:
            alert_only.append(item)
            continue

        if ACTIONER_USER_ID and not task_id:
            if not is_actioner_in_approval_chain(detail, ACTIONER_USER_ID):
                continue
            item["approve_error"] = (
                f"跳过自动通过：未找到 ACTIONER_USER_ID={ACTIONER_USER_ID} 的可执行 RUNNING 任务"
            )
            failed.append(item)
            continue

        try:
            result = execute_approve(
                token,
                inst_id,
                remark="兜底自动通过",
                task_id=item["task_id"],
                actioner_user_id=ACTIONER_USER_ID,
            )
            item["approve_result"] = result
            if is_approve_success(result):
                save_approved(inst_id, applicant, "兜底自动")
                approved_by_backup.append(item)
            else:
                failed.append(item)
        except Exception as exc:
            item["approve_error"] = str(exc)
            failed.append(item)

if approved_by_backup:
    notify_lines = ["审批兜底自动通过成功\n"]
    for s in approved_by_backup:
        notify_lines.append(f"审批标题: {s['title']}")
        notify_lines.append(f"申请人: {s['applicant']}")
        notify_lines.append(f"审批单号: {s['instance_id']}")
        notify_lines.append(f"已等待时长: {s['wait_minutes']} 分钟")
        notify_lines.append("")
    notify_msg = "\n".join(notify_lines)
    print(notify_msg)
    try:
        send_alert(token, notify_msg)
    except Exception as exc:
        print(f"WARN: 成功通知发送失败: {exc}")

pending_alerts = failed if BACKUP_AUTO_APPROVE else alert_only
if pending_alerts:
    title = "审批兜底告警：自动通过失败\n" if BACKUP_AUTO_APPROVE else "审批兜底告警：仅告警模式发现未处理审批单\n"
    alert_lines = [title]
    for s in pending_alerts:
        alert_lines.append(f"审批标题: {s['title']}")
        alert_lines.append(f"申请人: {s['applicant']}")
        alert_lines.append(f"审批单号: {s['instance_id']}")
        alert_lines.append(f"系统来源: {s['system_source']}")
        alert_lines.append(f"已等待时长: {s['wait_minutes']} 分钟")
        alert_lines.append(f"创建时间: {s['create_time']}")
        if s.get("task_id"):
            alert_lines.append(f"任务ID: {s['task_id']}")
        if s.get("running_task_approvers"):
            alert_lines.append(f"当前待办审批人候选: {', '.join(s['running_task_approvers'])}")
        if s.get("approve_result"):
            alert_lines.append(f"审批 API 返回: {json.dumps(s['approve_result'], ensure_ascii=False)}")
        if s.get("approve_error"):
            alert_lines.append(f"异常信息: {s['approve_error']}")
        alert_lines.append("")
    
    append_check_lines(alert_lines)
    
    alert_msg = "\n".join(alert_lines)
    print(alert_msg)
    
    # 发送告警失败不影响本次兜底检查结果。
    try:
        send_alert(token, alert_msg)
    except Exception as exc:
        print(f"WARN: 告警发送失败: {exc}")
    print(
        f"DONE: listed={len(instances)} skipped_state={skipped_state} "
        f"fetched={fetched} remembered={skipped_remembered} "
        f"lookback_h={BACKUP_LOOKBACK_HOURS} running_filter={used_running_filter}"
    )
    sys.exit(1)
else:
    print(
        f"OK: listed={len(instances)} skipped_state={skipped_state} "
        f"fetched={fetched} remembered={skipped_remembered} "
        f"lookback_h={BACKUP_LOOKBACK_HOURS} running_filter={used_running_filter}"
    )
    sys.exit(0)
PYEOF
