# 钉钉应用权限配置指南

## 前置条件

- 已创建钉钉企业内部应用（[开发者后台](https://open-dev.dingtalk.com/)）
- 已获取 AppKey 和 AppSecret
- 应用已发布上线

## 所需权限

在钉钉开发者后台 → 应用 → **权限管理** 页面，搜索并开通以下权限：

### 1. qyapi_aflow_execute（核心权限）

- **名称**：工作流实例执行权限
- **用途**：调用 `POST /v1.0/workflow/processInstances/execute` 执行审批同意/拒绝
- **说明**：这是旧版 `topapi/processinstance/approve` 的替代 API，新版审批系统必须使用此权限

### 2. 工作流模板读权限

- **用途**：查询审批流程定义、审批人列表等

### 3. 工作流实例读权限

- **用途**：获取审批实例详情（`/topapi/processinstance/get`）

### 4. 工作流模板写权限

- **用途**：如需通过 API 修改审批模板（非必需）

### 5. 工作通知发送权限

- **用途**：发送工作通知（`/topapi/message/corpconversation/asyncsend_v2`）
- **对应权限名**：企业内机器人发送消息

## 开通步骤

1. 登录 [钉钉开发者后台](https://open-dev.dingtalk.com/)
2. 选择你的应用
3. 点击左侧「**权限管理**」
4. 在搜索框中搜索上述权限名称
5. 点击「**申请开通**」
6. 部分权限需要管理员审批，等待通过后生效

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

A: 该权限名称可能搜索不到，尝试搜索"工作流实例执行"或在"工作流"分类下查找。

### Q: 权限开通后多久生效？

A: 通常即时生效，少数需要管理员审批的权限可能需要几分钟到几小时。
