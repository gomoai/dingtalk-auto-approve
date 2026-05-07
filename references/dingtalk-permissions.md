# 钉钉应用权限配置指南

## 前置条件

- 已创建钉钉企业内部应用（[开发者后台](https://open-dev.dingtalk.com/)）
- 已获取 AppKey 和 AppSecret
- 应用已发布上线

如果还没有钉钉应用/机器人，可先参考腾讯云文档中的“创建钉钉机器人”步骤：

- [企业 AI 智能体管控台 ClawPro 接入钉钉指南](https://cloud.tencent.com/document/product/213/129177)

该文档适合作为创建钉钉应用/机器人和获取 `Client ID` / `Client Secret` 的前置参考；本项目还需要继续开通下方工作流/审批权限。

## 所需权限

在钉钉开发者后台 → 应用 → **权限管理** 页面，搜索并开通以下权限。注意：`qyapi_aflow_execute` 通常不能在普通权限搜索中找到，需要通过 API Explorer 页面申请。

### 0. Stream 事件订阅

- **事件**：审批任务变更 `bpms_task_change`
- **用途**：实时接收审批任务事件，触发自动审批
- **位置**：钉钉开发者后台应用配置中的 Stream / 事件订阅相关配置

### 1. qyapi_aflow_execute（核心权限）

- **名称**：工作流实例执行权限
- **用途**：调用 `POST /v1.0/workflow/processInstances/execute` 执行审批同意/拒绝
- **说明**：这是旧版 `topapi/processinstance/approve` 的替代 API，新版审批系统必须使用此权限
- **开通方式**：普通权限管理页通常搜不到，需要通过 [ExecuteProcessInstance API Explorer](https://open.dingtalk.com/document/api/explore/explorer-page?devType=org&api=workflow_1.0%23ExecuteProcessInstance) 页面申请开通

### 2. 工作流实例读权限

- **用途**：获取审批实例详情（`/topapi/processinstance/get`），读取表单字段、申请人、系统来源等

### 3. 工作流实例列表/查询权限

- **用途**：兜底监控查询最近 7 天审批实例（`/topapi/processinstance/listids`），处理 bot 启动前遗漏的 RUNNING 单

### 4. 工作通知发送权限

- **用途**：发送工作通知（`/topapi/message/corpconversation/asyncsend_v2`）
- **对应权限名**：企业内机器人发送消息

### 5. 工作流模板读权限（可选）

- **用途**：如果后续要让工具自动发现审批模板、辅助选择 `TARGET_PROCESS_CODE`，可开通

### 6. 工作流模板写权限（通常不需要）

- **用途**：仅当需要通过 API 创建或修改审批模板时才需要；当前服务不需要

## 开通步骤

1. 登录 [钉钉开发者后台](https://open-dev.dingtalk.com/)
2. 选择你的应用
3. 点击左侧「**权限管理**」
4. 在搜索框中搜索上述普通权限名称
5. 对 `qyapi_aflow_execute`，打开 [ExecuteProcessInstance API Explorer](https://open.dingtalk.com/document/api/explore/explorer-page?devType=org&api=workflow_1.0%23ExecuteProcessInstance) 页面申请开通
6. 点击「**申请开通**」
7. 部分权限需要管理员审批，等待通过后生效

## 验证权限是否生效

通过钉钉 [API Explorer](https://open-dev.dingtalk.com/apiExplorer) 测试：

1. 选择「工作流」相关 API
2. 使用当前应用的 AppKey/AppSecret 获取 access_token
3. 调用审批执行 API 测试
4. 如果返回 `不合法ApiName` 或 `无权限`，说明权限未开通

## 常见问题

### Q: 开通后仍然报"不合法ApiName"

A: 可能是缓存问题，等待 5-10 分钟后再试，或重新获取 access_token。

### Q: 找不到 qyapi_aflow_execute 权限

A: 这是正常情况。该权限通常不能在普通权限管理搜索中找到，请通过 [ExecuteProcessInstance API Explorer](https://open.dingtalk.com/document/api/explore/explorer-page?devType=org&api=workflow_1.0%23ExecuteProcessInstance) 页面申请开通。

### Q: 权限开通后多久生效？

A: 通常即时生效，少数需要管理员审批的权限可能需要几分钟到几小时。
