# Klanata Amazon 商品运营工作站 V3.0 实施状态

## 本轮范围

本轮按《Klanata Amazon 商品运营工作站 V3.0 完整升级改造实施方案》开始正式主线改造。正式主线位于 `src/` 和 `tests/`；PowerShell 兼容工作站只保留为迁移期间的只读和应急工具。

当前版本为 `3.0.0-phase2`，交付目标是先建立不可串店的 Amazon 业务上下文和只读商品中心。所有生产价格和库存写入继续关闭。

## 已完成

- 建立 Developer Application、Authorization Profile、Seller Account、Marketplace Participation、Marketplace Capability 和 Product Listing Snapshot 领域模型。
- Authorization Profile 只保存加密机密的引用位置，数据库和代码库均不保存明文 Client Secret 或 Refresh Token。
- Seller 和 Marketplace 只能来自已验证授权档案和 Amazon 发现结果；前端不能自行创建生产上下文。
- 同一 Seller 可绑定多个独立 Refresh Token 授权档案，并为提交选择其中一个已验证档案。
- 商品快照永久绑定 Seller ID、Marketplace ID 和 SKU，领域对象禁止跨店铺或跨站点移动。
- 数据库加入外键、唯一索引和乐观并发版本，阻止重复上下文和重复 Listing。
- 能力矩阵将 Listings、Catalog、Pricing 读取能力与价格、MFN 库存写入能力分开记录。
- 新能力记录的变更集、调价模拟、价格写入和 MFN 库存写入全部默认关闭。
- 新增已验证上下文查询、商品分页筛选和商品详情只读 API。
- 新增 React 商品中心，包含生产上下文条、真实指标、SKU/ASIN/标题搜索、状态/配送/新鲜度筛选、分页和详情抽屉。
- 新增授权未迁移空状态，不使用演示店铺或伪造商品填充生产界面。
- 系统状态页保留，并显示 V3 数据库 Schema 和实施阶段。
- 兼容工作站的“上传工作台”显示名称已统一改为“商品上传”。

## 数据库

迁移：`V3CommerceContextReadModel`、`V3MultipleSellerAuthorizations`

新增表：

- `DeveloperApplications`
- `AuthorizationProfiles`
- `SellerAccounts`
- `SellerAuthorizationGrants`
- `MarketplaceParticipations`
- `MarketplaceCapabilities`
- `ProductListings`

关键约束：

- `SellerAccounts.SellerId` 唯一。
- `(SellerAccountId, AuthorizationProfileId)` 唯一，一个 Seller 可拥有多个授权 Grant。
- 每个 Seller 最多一个主授权，其他授权作为显式可选备用档案。
- `(SellerAccountId, MarketplaceId)` 唯一。
- `(SellerId, MarketplaceId, Sku)` 唯一。
- 每个 Marketplace Participation 只有一个能力矩阵。
- Product Listing 必须引用有效 Marketplace Participation。

## API

- `GET /api/v3/workspace/contexts`
- `GET /api/v3/catalog/listings`
- `GET /api/v3/catalog/listings/{sku}`

未知或未验证的 Seller/Marketplace 组合返回 `404 Production context not found`，不会降级到任意 Seller ID 查询。

## 生产门禁

当前明确关闭：

- Amazon 授权资料迁移和加密机密仓库写入。
- Amazon Reports/Listings/Catalog/PTD 自动同步 Worker。
- Change Set 草稿、审批和提交。
- 普通价、企业价和 MFN 库存生产写入。
- `0.9` 规则相关调价模拟与生产执行。
- Feed 提交、SKU 级结果归档、提交后核验和补偿变更集。

Amazon `ACCEPTED` 或 Feed `DONE` 在后续实现中不得直接映射为业务完成；必须解析 SKU 级结果并完成提交后核验。

## 多 Refresh Token 规则

- 一个 Seller/Marketplace 可以绑定多个独立 Authorization Profile。
- 每个 Profile 必须单独通过该 Seller/Marketplace 的 `VALIDATION_PREVIEW`，不能仅凭 Marketplace 列表推断属于同一 Seller。
- 单次 Amazon API 请求只使用一个 Access Token；提交页面必须明确选择本次使用的授权档案。
- 未通过当前生产上下文验证的 Token 由后端拒绝，前端选择不能绕过。
- 创建 Amazon Feed Document 或 Feed 后不自动切换 Token 重试，避免不确定响应导致重复 Feed。
- Feed 创建完成后允许使用同一 Seller/Marketplace 下另一个已验证 Token 查询状态或下载结果。

## 后续阶段

1. 将凭证迁入正式加密机密仓库，并通过 Sellers API 自动发现 Seller 和 Marketplace。
2. 将正式数据库迁移到 PostgreSQL，并接入 Hangfire 持久任务。
3. 实现 Reports/Listings/Catalog/PTD 只读同步、任务状态和数据新鲜度监控。
4. 建立 Change Set、基准快照、差异校验、风险分级、RBAC 和审批矩阵。
5. 在灰度 Feature Flag 下实现价格和 MFN 库存写入、SKU 级结果、提交后核验和补偿恢复。

在以上生产门禁逐项验收前，V3 服务只作为安全的只读商品中心运行。
