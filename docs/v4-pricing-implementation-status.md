# Klanata 智能调价工作站 V4 P0 实施状态

## 本轮目标

本轮把调价主流程从旧 PowerShell 文件上传迁入 `.NET 10 + React + TypeScript` 正式主线。实现范围是生产安全的 P0 垂直切片：规则、筛选、差异、Change Set、审批和验证门禁完整持久化，但在 Amazon 实时校验和安全报价合并完成前不开放任何价格写入。

## 已完成

- 新增 `PricingRuleSet`、`PricingRun`、`PricingRunItem`、`PricingChangeSet`、`PricingChangeSetItem` 和 `PricingApproval` 持久模型。
- 新增 `V4PricingFoundation` 数据库迁移、唯一约束、外键和价格 `decimal(18,4)` 映射。
- 每个调价任务锁定 Seller、Marketplace、Marketplace Region 和一个已验证 Authorization Profile。
- 使用 12 小时快照门槛；非 MFN、非 Active、零库存、缺失价格、过期快照、同 ASIN FBA 和币种冲突均按 SKU 返回中文原因。
- 规则支持涨价/降价、固定额/百分比、`P <= threshold` 与 `P > threshold` 分段、绝对上限、百分比上限和 Marketplace 币种精度。
- 企业价默认且 P0 仅允许 `UNCHANGED`；Change Set 中 `TargetBusinessPrice = null`、`BusinessPriceModified = false`。
- Run 和 Change Set 具有唯一幂等键；规则版本、快照版本和目标价被固化。
- Change Set 要求不同于发起人的复核标签完成四项显式确认，但 P0 明确返回 `REVIEW_RECORDED` 与 `identityVerified=false`，不把自由文本视为认证身份。
- 创建 Run、创建 Change Set、记录复核和验证阻断均写入审计事件。
- 所有 `/api/v4` 非安全 HTTP 方法均执行同源 Cookie + CSRF 校验。
- React 页面改为六步流程：商品同步、候选筛选、调价规则、差异审核、复核门禁、结果核验。
- Run 创建后锁定商品同步、候选筛选和规则步骤；只有“新建任务”能够解锁，并会原子清空复核人、四项确认、校验结果和分页状态。
- Run、Change Set 和复核响应均校验 Seller、Marketplace、Run 与 Change Set 上下文，不接受跨上下文或陈旧响应。
- 页面按照后端快照时间计算 12 小时有效期，到期后自动禁用创建并重新读取同步状态，不永久信任首次返回的 `canStart=true`。
- 逐 SKU 差异每页最多渲染 100 条，避免大店铺一次渲染数百或数千行阻塞操作界面。
- 旧文件调价仅保留本机管理员应急模拟；旧批次创建、批准和提交默认 `403 V4_REQUIRED`。

## 本轮验收

- `.NET` Release 独立构建 0 警告、0 错误；全量测试 30/30 通过。
- EF Core 模型与迁移一致，`has-pending-model-changes` 无待生成变更。
- 前端 typecheck、lint 和 production build 全部通过。
- Playwright 在 1440、390 和 375 三个视口完成双轮六步流程，覆盖 102 SKU 分页、任务锁、复核状态清空、CSRF 和 `LIVE_VALIDATION_UNAVAILABLE` 门禁。
- 快照短到期烟测确认创建按钮会自动失效并重新拉取同步状态。
- 旧调价门禁、价格模拟、多 Token 隔离、凭证脱敏扫描和 `git diff --check` 全部通过；验收期间未调用 Amazon 写接口。

## 当前明确阻断

以下能力尚未实现，任何一项缺失都不允许真实改价：

- Amazon Reports 全量同步执行器和持久后台轮询；
- 候选 SKU 的 Listings Items 实时刷新；
- 自动调价状态、Issue、最低价、最高价和活动任务冲突检查；
- 单 SKU 目标价覆盖、恢复规则值和完整审核 XLSX 导出；
- `SAME_DELTA`、固定折扣、独立企业价规则等非 `UNCHANGED` 企业价策略；
- Product Type Definition 获取、缓存和 Schema 校验；
- 保留促销、min/max、阶梯企业价及其他 audience 的安全 offer 合并；
- SKU 写锁、提交前最新价格冲突检查和 Listings Items PATCH 队列；
- 大批量 `JSON_LISTINGS_FEED`、逐 SKU Processing Report 映射；
- 2/10/30/120 分钟价格回读、冲突识别和反向恢复 Change Set；
- PostgreSQL、Hangfire、RBAC 和正式用户身份系统；正式身份接入前不能形成生产批准。

因此 `POST /api/v4/pricing/change-sets/{id}/validate` 当前固定记录审计并返回：

```text
409 LIVE_VALIDATION_UNAVAILABLE
amazonWriteAttempted = false
identityVerified = false
```

Amazon `ACCEPTED` 或 Feed `DONE` 在后续阶段也不得直接映射为业务成功；只有价格回读与目标值一致才能标记成功。

## API

| Method | Route | 状态 |
| --- | --- | --- |
| GET | `/api/v4/pricing/sync-status` | 已完成 |
| POST | `/api/v4/pricing/sync` | 契约完成，执行器未接入时 `503` |
| POST | `/api/v4/pricing/runs` | 已完成 |
| GET | `/api/v4/pricing/runs/{id}` | 已完成 |
| POST | `/api/v4/pricing/runs/{id}/change-sets` | 已完成 |
| POST | `/api/v4/pricing/change-sets/{id}/approve` | 复核记录完成；正式身份审批未完成 |
| POST | `/api/v4/pricing/change-sets/{id}/validate` | 门禁完成，真实校验未接入时 `409` |

## 验收原则

本阶段可以验收“不会跨店、不会误改企业价、不会把自由文本冒充正式身份、不会伪造同步、不会在缺少实时校验时写 Amazon”。不能验收“正式双人审批”或“已经能够真实提交并回读完成”，因为相关能力仍明确关闭。
