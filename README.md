# Klanata Amazon 商品运营工作站

> V4 正式主线位于 `src/` 和 `tests/`。当前已交付 API 原生调价 P0：不可变 Seller/Marketplace/Authorization 上下文、纯 FBM 筛选、版本化规则、逐 SKU 差异、未认证复核记录和安全验证门禁。真实用户/RBAC、Amazon Reports 同步、提交前实时回读、PTD 安全合并与价格写入尚未接入，因此生产提交仍由服务端阻断。详见 `docs/v4-pricing-implementation-status.md`。

## V4 智能调价 P0

正常调价入口不再接收 CSV、TXT、XLSX 或 XLSM 文件。运营流程改为：

1. 选择 Amazon 自动发现的店铺与 Marketplace。
2. 检查持久化商品快照和 12 小时数据新鲜度。
3. 自动筛选纯 FBM 商品并记录每个排除原因。
4. 使用版本化 Decimal 规则生成逐 SKU 差异。
5. 创建不可变 Change Set，以不同操作标签完成四项人工复核；P0 不把自由文本标签冒充真实身份认证。
6. 执行生产验证；在实时价格、PTD 和安全报价合并缺失时返回 `409 LIVE_VALIDATION_UNAVAILABLE`，且不调用 Amazon 写接口。

旧 PowerShell 文件调价已经降级为本机管理员应急模拟。旧价格批次创建、审批和提交默认返回 `403 V4_REQUIRED`；库存上传流程不受此门禁影响。

## Production v2 Phase 1

Phase 1 now provides the .NET 10 service foundation, React status console, SQLite persistence, worker heartbeat, audit foundation, local security controls, tests, backup tooling, and a self-contained Windows publish. It intentionally does not yet contain Amazon authorization or submission endpoints; those start in Phase 2.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-v2.ps1
```

Open `http://127.0.0.1:4318/`. The legacy production workstation remains on `http://127.0.0.1:4317/` until an approved cutover.

The authorized Linux server deployment runs as an isolated systemd service. Start the encrypted SSH tunnel with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\open-server-tunnel.ps1 -Background
```

Then open `http://127.0.0.1:4320/`. See `docs/server-deployment.md` for service, backup, and upgrade operations.

The complete Amazon workstation is available through the second encrypted tunnel:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\open-server-tunnel.ps1 -LocalPort 4321 -RemotePort 4319 -Background
```

Open `http://127.0.0.1:4321/` for data cleaning, two-profile authorization, Seller validation, Feed submission, polling, and report downloads. Local port 4317 is now read-only fallback.

Public server access: `http://144.225.124.172.nip.io/`.

本地运行的 Amazon SP-API 库存 Feed 工作站。页面完成数据校验、LWA 授权、Seller ID 匹配、`JSON_LISTINGS_FEED` 提交、状态轮询和处理报告下载。

## 功能

- 读取 Amazon Price and Quantity TXT/TSV 模板
- 按模板元数据定位真实数据行并跳过示例行
- 校验 SKU、配送渠道、库存数量和重复数据
- 显示库存分布、数据预览和零库存比例
- 验证北美、欧洲和远东 SP-API 授权
- 同时保留多个区域授权，并按 Marketplace 自动选择对应会话
- 使用 Listings Items API `VALIDATION_PREVIEW` 校验 Seller ID
- 转换为 `JSON_LISTINGS_FEED` v2
- 创建 Feed 文档、上传、提交并轮询处理状态
- 下载并展示 Feed processing report 汇总
- 对 Amazon 限流和临时服务错误自动重试并指数退避
- 页面刷新后自动续接处理中任务，轮询请求不会重叠
- 大批量或高比例零库存更新需要输入包含 SKU 数量的确认短语
- 直接读取 Amazon 官方 TXT、TSV、XLSX 和 XLSM 价格与数量模板
- 从模板元数据校验 Seller ID 与 Marketplace，阻止跨店铺误传
- Feed 文档上传后自动清理本地临时输入文件
- 凭证仅保存在当前服务进程内存，不写入文件
- API 原生智能调价：绑定已验证 Seller、Marketplace 和同区域 Authorization Profile，不以运营上传文件作为主数据
- 版本化规则：支持 `P <= 100` / `P > 100` 分段、固定金额、百分比、绝对与百分比双上限以及币种精度
- 企业价默认且当前仅允许 `UNCHANGED`；Change Set 不包含企业价目标值
- 逐 SKU 差异、中文排除原因、幂等 Change Set、异人四确认复核记录和不可变审计
- 生产验证在 Amazon 实时回读与安全报价合并完成前保持阻断，不创建 Feed 或 Listings Items 写请求

## 环境

- Windows PowerShell 5.1
- Windows 10/11
- 可访问 Amazon LWA 与 Selling Partner API

## 启动

```powershell
powershell -ExecutionPolicy Bypass -File .\start.ps1
```

指定默认模板文件：

```powershell
powershell -ExecutionPolicy Bypass -File .\start.ps1 -TemplatePath "D:\data\PriceAndQuantity-ca.xlsm"
```

页面默认绑定 `127.0.0.1`，不会监听局域网地址。端口被占用时会自动选择下一个可用端口。

停止服务：

```powershell
powershell -ExecutionPolicy Bypass -File .\stop.ps1
```

作为 production v2 切换期间的只读回退工具启动：

```powershell
powershell -ExecutionPolicy Bypass -File .\start.ps1 -ReadOnly
```

## 上传流程

1. 选择 Amazon 官方 TXT、TSV、XLSX 或 XLSM 文件并完成数据校验。
2. 选择 SP-API 区域，填写 LWA Client ID、Client Secret 和 Refresh Token。
3. 填写 Seller ID，选择 Marketplace；工作站先核对模板内的目标 Seller/Marketplace，再执行 `VALIDATION_PREVIEW`。
4. 核对店铺和 SKU 数量后输入页面要求的确认短语。大批量或高比例零库存更新使用 `SUBMIT <SKU数量>`。
5. 在任务记录中查看队列、处理和报告生成进度。

## 安全

- 不要把 Client Secret、Refresh Token 或 Seller Central 导出文件提交到 Git。
- `.gitignore` 已排除常见凭证、Feed 输入和处理报告文件。
- 浏览器成功授权后会立即清空 Client Secret 与 Refresh Token 输入框。
- 服务在当前进程内存中保存 LWA 凭证以自动刷新 Access Token，所有凭证都会在进程退出后清除且不会写入文件。
- 建议在公共仓库提交前运行下面的扫描：

```powershell
Get-ChildItem -Recurse -File | Select-String -Pattern 'amzn1\.oa2-cs|Atzr\||refresh[_ -]?token|client[_ -]?secret'
```

## API 路由

| Method | Route | Purpose |
| --- | --- | --- |
| GET | `/api/status` | 本地服务状态 |
| POST | `/api/analyze` | 解析 TXT/TSV/XLSX/XLSM 模板并创建分析会话 |
| POST | `/api/pricing/simulate` | 对已验证单一 Marketplace 执行调价筛选和安全模拟，不提交 Amazon |
| GET | `/api/v4/pricing/sync-status` | 读取持久化 Amazon 快照状态和 12 小时新鲜度 |
| POST | `/api/v4/pricing/sync` | 请求 Amazon Reports 同步；执行器未接入时明确返回 `503` |
| POST | `/api/v4/pricing/runs` | 创建版本化规则和逐 SKU 调价运行 |
| GET | `/api/v4/pricing/runs/{id}` | 读取调价运行、规则、差异和排除原因 |
| POST | `/api/v4/pricing/runs/{id}/change-sets` | 从候选 SKU 创建不可变 Change Set |
| POST | `/api/v4/pricing/change-sets/{id}/approve` | 记录异人标签的四项复核；返回 `identityVerified=false` |
| POST | `/api/v4/pricing/change-sets/{id}/validate` | 执行生产前门禁；当前安全阻断且不写 Amazon |
| POST | `/api/auth/verify` | 获取 LWA Access Token 并读取 Marketplace |
| POST | `/api/account/validate` | Seller ID 与 SKU 的预提交验证 |
| GET | `/api/workflow/current` | 恢复当前进程内的分析、授权和账户预检状态 |
| POST | `/api/feeds/submit` | 创建并提交 `JSON_LISTINGS_FEED` |
| GET | `/api/jobs` | 任务列表 |
| GET | `/api/jobs/{id}` | 更新并读取任务状态 |
| POST | `/api/jobs/{id}/reconnect` | 使用新的内存授权会话恢复任务轮询 |
| GET | `/api/jobs/{id}/report` | 下载处理报告 |

## 数据范围

当前版本针对 Merchant Fulfilled Network 库存数量更新，生成的消息使用：

- `operationType`: `PARTIAL_UPDATE`
- `productType`: `PRODUCT`
- `fulfillment_channel_code`: `DEFAULT`

FBA 库存由 Amazon 管理，控制台会拒绝上传 `AMAZON_NA` 数量。

Excel 文件只作为工作站的输入格式。服务读取工作簿中的 `Template` 工作表，执行与文本模板相同的校验，然后生成 Amazon SP-API 要求的 `JSON_LISTINGS_FEED`；不会执行工作簿宏，也不会把 Excel 二进制文件直接发送给 Feeds API。

## 智能调价安全模拟

调价页支持 CSV、TXT、TSV、XLSX 和 XLSM 快照。系统自动识别常见中英文列名，包括 Seller SKU/MSKU、ASIN、库存、配送渠道、Listing 状态、普通售价、企业售价、币种、最低/最高允许价和成本价。

运行规则测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-pricing-simulation.ps1
```

本地服务启动后运行页面回归测试：

```powershell
python .\scripts\verify-pricing-ui.py
```

测试覆盖上传、调价、任务和系统 4 个工作区，以及 1440px 桌面、768px 平板、390px 手机、375px 小屏、844×390 横屏和减弱动画模式。它会验证深链与后退、跳过导航、表单可访问名称、44px 命中区域、授权前禁用状态、生产提交锁定、控制台错误、失败请求和横向溢出，并将代表性截图写入 `output/ui-*.png`。

当前 UI 基线经 Chrome DevTools 验证：桌面和移动端 Lighthouse 的 Accessibility、Best Practices、SEO 与 Agentic Browsing 均为 100；本地性能追踪 LCP 约 241ms，CLS 约 0.0005。

当前版本不会创建价格 Feed 或调用 Listings Items 写接口。“≤100、>100、0.9”和企业价策略完成书面确认前，页面中的生产提交与审批入口保持禁用。
