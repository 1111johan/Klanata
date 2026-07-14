# Amazon SP-API Inventory Console

本地运行的 Amazon SP-API 库存 Feed 工作站。页面完成数据校验、LWA 授权、Seller ID 匹配、`JSON_LISTINGS_FEED` 提交、状态轮询和处理报告下载。

## 功能

- 读取 Amazon Price and Quantity TXT/TSV 模板
- 按模板元数据定位真实数据行并跳过示例行
- 校验 SKU、配送渠道、库存数量和重复数据
- 显示库存分布、数据预览和零库存比例
- 验证北美、欧洲和远东 SP-API 授权
- 使用 Listings Items API `VALIDATION_PREVIEW` 校验 Seller ID
- 转换为 `JSON_LISTINGS_FEED` v2
- 创建 Feed 文档、上传、提交并轮询处理状态
- 下载并展示 Feed processing report 汇总
- 凭证仅保存在当前服务进程内存，不写入文件

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
powershell -ExecutionPolicy Bypass -File .\start.ps1 -TemplatePath "D:\data\PriceAndQuantity-ca.txt"
```

页面默认绑定 `127.0.0.1`，不会监听局域网地址。端口被占用时会自动选择下一个可用端口。

停止服务：

```powershell
powershell -ExecutionPolicy Bypass -File .\stop.ps1
```

## 上传流程

1. 选择 TXT/TSV 文件并完成数据校验。
2. 选择 SP-API 区域，填写 LWA Client ID、Client Secret 和 Refresh Token。
3. 填写 Seller ID，选择 Marketplace，执行 `VALIDATION_PREVIEW`。
4. 核对店铺和 SKU 数量，输入 `SUBMIT` 后正式提交。
5. 在任务记录中查看队列、处理和报告生成进度。

## 安全

- 不要把 Client Secret、Refresh Token 或 Seller Central 导出文件提交到 Git。
- `.gitignore` 已排除常见凭证、Feed 输入和处理报告文件。
- 浏览器成功授权后会立即清空 Client Secret 与 Refresh Token 输入框。
- 服务只保存短期 LWA Access Token，并在进程退出后清除。
- 建议在公共仓库提交前运行下面的扫描：

```powershell
Get-ChildItem -Recurse -File | Select-String -Pattern 'amzn1\.oa2-cs|Atzr\||refresh[_ -]?token|client[_ -]?secret'
```

## API 路由

| Method | Route | Purpose |
| --- | --- | --- |
| GET | `/api/status` | 本地服务状态 |
| POST | `/api/analyze` | 校验模板并创建分析会话 |
| POST | `/api/auth/verify` | 获取 LWA Access Token 并读取 Marketplace |
| POST | `/api/account/validate` | Seller ID 与 SKU 的预提交验证 |
| POST | `/api/feeds/submit` | 创建并提交 `JSON_LISTINGS_FEED` |
| GET | `/api/jobs` | 任务列表 |
| GET | `/api/jobs/{id}` | 更新并读取任务状态 |
| GET | `/api/jobs/{id}/report` | 下载处理报告 |

## 数据范围

当前版本针对 Merchant Fulfilled Network 库存数量更新，生成的消息使用：

- `operationType`: `PARTIAL_UPDATE`
- `productType`: `PRODUCT`
- `fulfillment_channel_code`: `DEFAULT`

FBA 库存由 Amazon 管理，控制台会拒绝上传 `AMAZON_NA` 数量。
