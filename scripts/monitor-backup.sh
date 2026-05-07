#!/bin/bash
# 审批兜底监控 - 每 15 分钟运行一次
# 检查是否有符合条件的审批单卡住（等待 > 5 分钟未自动通过）

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
import urllib.error, urllib.request, json, urllib.parse, time, sys, os
from datetime import datetime

TOKEN_URL = f"https://oapi.dingtalk.com/gettoken?appkey={os.environ.get('DINGTALK_APP_KEY','')}&appsecret={os.environ.get('DINGTALK_APP_SECRET','')}"
SCRIPT_DIR = os.environ.get("SCRIPT_DIR", os.getcwd())
PROCESS_CODE = os.environ.get("TARGET_PROCESS_CODE", "")
TARGET_SYSTEM_SOURCE = os.environ.get("TARGET_SYSTEM_SOURCE", "AI工具账号")
STATE_FILE = os.environ.get("STATE_FILE", os.path.join(SCRIPT_DIR, ".approved_state.json"))
ALERT_THRESHOLD_MIN = int(os.environ.get("ALERT_THRESHOLD_MIN", "5") or "5")
BACKUP_AUTO_APPROVE = os.environ.get("BACKUP_AUTO_APPROVE", "true").lower() in ("1", "true", "yes", "y")
ACTIONER_USER_ID = os.environ.get("ACTIONER_USER_ID", "")
NOTIFY_USER_ID = os.environ.get("NOTIFY_USER_ID", "")
AGENT_ID = int(os.environ.get("DINGTALK_AGENT_ID", "0") or "0")
ALERT_CHANNEL = os.environ.get("ALERT_CHANNEL", "dingtalk").lower()
SERVICE_NAME = os.environ.get("SERVICE_NAME", "dingtalk-bot.service")
LAUNCHD_LABEL = os.environ.get("LAUNCHD_LABEL", "com.gomoai.dingtalk-auto-approve")
OS_NAME = os.uname().sysname if hasattr(os, "uname") else ""

def post_json(url, body, headers=None):
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers or {"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} {exc.reason}: {error_body}") from exc

def get_token():
    if not os.environ.get("DINGTALK_APP_KEY") or not os.environ.get("DINGTALK_APP_SECRET"):
        return None
    with urllib.request.urlopen(TOKEN_URL, timeout=10) as resp:
        r = json.loads(resp.read().decode())
        if r.get("errcode") == 0:
            return r["access_token"]
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

def get_instances(token, start_ts, end_ts):
    url = f"https://oapi.dingtalk.com/topapi/processinstance/listids?access_token={token}"
    data = urllib.parse.urlencode({
        "process_code": PROCESS_CODE,
        "start_time": start_ts,
        "end_time": end_ts,
        "size": 20,
    }).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read().decode())
        return result.get("result", {}).get("list", [])

def get_instance_detail(token, instance_id):
    url = f"https://oapi.dingtalk.com/topapi/processinstance/get?access_token={token}"
    data = urllib.parse.urlencode({"process_instance_id": instance_id}).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read().decode())
        return result.get("process_instance", {})

def execute_approve(token, instance_id, task_id=None):
    """兜底执行审批同意，与 Stream bot 使用同一个新版审批执行 API。"""
    body = {
        "processInstanceId": instance_id,
        "remark": "兜底自动通过",
        "result": "agree",
        "actionerUserId": ACTIONER_USER_ID,
    }
    if task_id:
        body["taskId"] = task_id
    return post_json(
        "https://api.dingtalk.com/v1.0/workflow/processInstances/execute",
        body,
        headers={
            "x-acs-dingtalk-access-token": token,
            "Content-Type": "application/json",
        },
    )

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

def find_task_id(value):
    """从审批详情里尽量提取当前 RUNNING 任务的 taskId。"""
    if isinstance(value, dict):
        status = str(value.get("status", value.get("taskStatus", value.get("state", "")))).upper()
        result = str(value.get("result", value.get("operation_result", ""))).upper()
        looks_running = status in ("RUNNING", "NEW", "TODO", "PENDING") or result in ("", "NONE")
        for key in ("taskId", "taskid", "task_id", "activityId", "activity_id"):
            task_id = value.get(key)
            if task_id and looks_running:
                try:
                    return int(task_id)
                except (TypeError, ValueError):
                    return None
        for child in value.values():
            task_id = find_task_id(child)
            if task_id:
                return task_id
    elif isinstance(value, list):
        for child in value:
            task_id = find_task_id(child)
            if task_id:
                return task_id
    return None

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
    url = f"https://oapi.dingtalk.com/topapi/message/corpconversation/asyncsend_v2?access_token={token}"
    return post_json(url, {
        "agent_id": AGENT_ID,
        "userid_list": NOTIFY_USER_ID,
        "msg": {"msgtype": "text", "text": {"content": message}},
    })

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

# 查询最近 7 天的实例
start_ts = int((now - 604800) * 1000)
end_ts = int(now * 1000)

instances = get_instances(token, start_ts, end_ts)
failed = []
alert_only = []
approved_by_backup = []

for inst_id in instances:
    # 已自动通过的跳过
    if inst_id in approved:
        continue

    detail = get_instance_detail(token, inst_id)
    if not detail:
        continue

    status = detail.get("status", "")
    # 只看还在运行中的
    if status != "RUNNING":
        continue

    form_values = detail.get("form_component_values", [])
    system_source = get_form_field(form_values, "系统来源")
    title = detail.get("title", "")
    applicant = extract_applicant(detail, form_values, title)
    create_time_str = detail.get("create_time", "")

    # 过滤：只检查指定系统来源的审批单
    if system_source != TARGET_SYSTEM_SOURCE:
        continue

    # 检查是否已被当前用户手动通过
    if is_manually_approved(detail):
        # 手动通过的单子也记录下来，避免重复检查
        save_approved(inst_id, applicant, "手动")
        continue

    # 计算等待时长
    if create_time_str:
        try:
            ct = datetime.strptime(create_time_str, "%Y-%m-%d %H:%M:%S")
            create_ts = ct.timestamp()
            wait_minutes = int((now - create_ts) / 60)
        except:
            wait_minutes = 0
    else:
        wait_minutes = 0

    if wait_minutes >= ALERT_THRESHOLD_MIN:
        item = {
            "instance_id": inst_id,
            "title": title,
            "applicant": applicant,
            "system_source": system_source,
            "wait_minutes": wait_minutes,
            "create_time": create_time_str,
            "form_summary": parse_form_summary(form_values),
            "task_id": find_task_id(detail),
        }
        if not BACKUP_AUTO_APPROVE:
            alert_only.append(item)
            continue

        try:
            result = execute_approve(token, inst_id, task_id=item["task_id"])
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
    sys.exit(1)
else:
    print("OK")
    sys.exit(0)
PYEOF
