import { useCallback, useEffect, useMemo, useState } from 'react'
import type { FormEvent } from 'react'
import {
  Activity,
  Archive,
  Box,
  Boxes,
  ChevronLeft,
  ChevronRight,
  CircleAlert,
  CircleCheck,
  Database,
  Gauge,
  HardDrive,
  LayoutList,
  LockKeyhole,
  PackageSearch,
  RefreshCw,
  RotateCcw,
  Search,
  Server,
  ShieldAlert,
  ShieldCheck,
  SlidersHorizontal,
  Store,
  X,
} from 'lucide-react'
import './App.css'
import PricingView from './PricingView'

type ComponentHealth = {
  status: 'healthy' | 'degraded' | 'unhealthy' | 'not-configured'
  detail: string
}

type SystemHealth = {
  overallStatus: 'healthy' | 'degraded' | 'unhealthy'
  service: ComponentHealth
  database: ComponentHealth
  disk: ComponentHealth
  worker: ComponentHealth
  secretStore: ComponentHealth
  environment: string
  bindAddress: string
  dataRoot: string
  availableDiskBytes: number
  checkedAtUtc: string
}

type SystemVersion = {
  version: string
  phase: string
  framework: string
  databaseProvider: string
  databaseSchema: string
  startedAtUtc: string
}

type MarketplaceCapabilities = {
  canReadListings: boolean
  canReadCatalog: boolean
  canReadPricing: boolean
  canCreateDraftChangeSets: boolean
  canSimulatePricing: boolean
  canWritePrices: boolean
  canWriteMfnInventory: boolean
  writeBlockReason: string
  verifiedAtUtc?: string
}

type MarketplaceContext = {
  sellerId: string
  sellerName: string
  marketplaceId: string
  marketplaceName: string
  countryCode: string
  currencyCode: string
  region: string
  lastVerifiedAtUtc: string
  authorizationProfileCount: number
  capabilities: MarketplaceCapabilities
}

type CatalogMetrics = {
  totalListings: number
  activeListings: number
  mfnListings: number
  staleListings: number
  lastSynchronizedAtUtc?: string
}

type ProductListing = {
  sku: string
  asin?: string
  title?: string
  fulfillment: 'MFN' | 'FBA'
  status: string
  currencyCode: string
  price?: number
  businessPrice?: number
  mfnQuantity?: number
  freshness: 'fresh' | 'aging' | 'stale'
  synchronizedAtUtc: string
  snapshotVersion: number
}

type ProductCatalogPage = {
  context: MarketplaceContext
  metrics: CatalogMetrics
  items: ProductListing[]
  page: number
  pageSize: number
  totalItems: number
  totalPages: number
  generatedAtUtc: string
}

type ProductListingDetail = ProductListing & {
  sellerId: string
  marketplaceId: string
  amazonUpdatedAtUtc?: string
  sourceReference?: string
}

type ViewName = 'catalog' | 'pricing' | 'system'
type Filters = { status: string; fulfillment: string; freshness: string }

const initialFilters: Filters = { status: '', fulfillment: '', freshness: '' }

const healthLabels: Record<ComponentHealth['status'], string> = {
  healthy: '正常',
  degraded: '需关注',
  unhealthy: '异常',
  'not-configured': '待配置',
}

const listingStatusLabels: Record<string, string> = {
  Active: '在售',
  Inactive: '停售',
  Incomplete: '信息不全',
  Suppressed: '被抑制',
  Unknown: '未知',
}

const freshnessLabels = { fresh: '最新', aging: '需刷新', stale: '已过期' }

function contextKey(context: MarketplaceContext) {
  return `${context.sellerId}::${context.marketplaceId}`
}

async function getJson<T>(path: string, signal?: AbortSignal, allowUnavailable = false): Promise<T> {
  const response = await fetch(path, {
    credentials: 'same-origin',
    headers: { Accept: 'application/json' },
    signal,
  })
  const body = (await response.json()) as T & { detail?: string; title?: string }
  if (!response.ok && !(allowUnavailable && response.status === 503)) {
    throw new Error(body.detail || body.title || `请求失败（HTTP ${response.status}）`)
  }
  return body
}

function formatDate(value?: string, includeSeconds = false) {
  if (!value) return '--'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return new Intl.DateTimeFormat('zh-CN', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: includeSeconds ? '2-digit' : undefined,
    hour12: false,
  }).format(date)
}

function formatCurrency(value: number | undefined, currencyCode: string) {
  if (value === undefined || value === null) return '--'
  try {
    return new Intl.NumberFormat('zh-CN', {
      style: 'currency',
      currency: currencyCode,
      minimumFractionDigits: 2,
    }).format(value)
  } catch {
    return `${currencyCode} ${value.toFixed(2)}`
  }
}

function formatBytes(value: number) {
  return value > 0 ? `${(value / 1024 / 1024 / 1024).toFixed(1)} GB` : '--'
}

function useHashView() {
  const readView = (): ViewName => {
    if (window.location.hash === '#system') return 'system'
    if (window.location.hash === '#pricing') return 'pricing'
    return 'catalog'
  }
  const [view, setView] = useState<ViewName>(readView)

  useEffect(() => {
    const onHashChange = () => setView(readView())
    window.addEventListener('hashchange', onHashChange)
    return () => window.removeEventListener('hashchange', onHashChange)
  }, [])

  const navigate = (nextView: ViewName) => {
    window.location.hash = nextView
    setView(nextView)
  }

  return [view, navigate] as const
}

function PrimaryNavigation({ view, className = '', label }: { view: ViewName; className?: string; label: string }) {
  return (
    <nav className={`primary-navigation ${className}`.trim()} aria-label={label}>
      <a className="nav-item" href="#catalog" aria-current={view === 'catalog' ? 'page' : undefined}><LayoutList aria-hidden="true" /><span>商品中心</span></a>
      <span className="nav-item is-disabled" aria-disabled="true" title="变更集将在后续安全阶段开放"><Archive aria-hidden="true" /><span>变更集</span><LockKeyhole className="nav-lock" aria-hidden="true" /></span>
      <a className="nav-item" href="#pricing" aria-current={view === 'pricing' ? 'page' : undefined}><SlidersHorizontal aria-hidden="true" /><span>智能调价</span></a>
      <a className="nav-item" href="#system" aria-current={view === 'system' ? 'page' : undefined}><Activity aria-hidden="true" /><span>系统状态</span></a>
    </nav>
  )
}

function HealthBadge({ status }: { status: ComponentHealth['status'] }) {
  return <span className={`health-badge is-${status}`}>{healthLabels[status]}</span>
}

function EmptyContext({ onOpenSystem }: { onOpenSystem: () => void }) {
  return (
    <section className="empty-context" aria-labelledby="empty-context-title">
      <div className="empty-context-icon"><ShieldAlert aria-hidden="true" /></div>
      <div>
        <span className="eyebrow">AMAZON CONTEXT</span>
        <h2 id="empty-context-title">尚无已验证的 Carkee 生产上下文</h2>
        <p>授权迁移完成后，Seller 和 Marketplace 将由 Amazon 自动发现并出现在这里。</p>
      </div>
      <button className="secondary-button" type="button" onClick={onOpenSystem}>
        <Activity aria-hidden="true" />查看系统状态
      </button>
    </section>
  )
}

function ContextRail({
  contexts,
  selectedKey,
  onChange,
}: {
  contexts: MarketplaceContext[]
  selectedKey: string
  onChange: (value: string) => void
}) {
  const selected = contexts.find((item) => contextKey(item) === selectedKey)

  return (
    <section className="context-rail" aria-label="当前生产上下文">
      <div className="context-selector">
        <label htmlFor="production-context">Carkee 站点</label>
        <select id="production-context" value={selectedKey} disabled={contexts.length === 0} onChange={(event) => onChange(event.target.value)}>
          {contexts.length === 0 ? <option value="">等待 Amazon 授权迁移</option> : null}
          {contexts.map((context) => (
            <option value={contextKey(context)} key={contextKey(context)}>
              {context.sellerName} · {context.marketplaceName}
            </option>
          ))}
        </select>
      </div>

      <div className="context-identity">
        <div><span>Seller</span><strong>{selected?.sellerId ?? '--'}</strong></div>
        <div><span>Marketplace</span><strong>{selected?.marketplaceId ?? '--'}</strong></div>
      </div>

      <div className="context-safety">
        <span className="context-profile-count"><LockKeyhole aria-hidden="true" />{selected?.authorizationProfileCount ?? 0} 个授权档案</span>
        <span className={`context-read-state ${selected?.capabilities.canReadListings ? 'is-ready' : ''}`}>
          <ShieldCheck aria-hidden="true" />{selected?.capabilities.canReadListings ? '读取已验证' : '读取待验证'}
        </span>
        <span className="context-write-state" title={selected?.capabilities.writeBlockReason || '生产写入未开放'}>
          <LockKeyhole aria-hidden="true" />生产写入锁定
        </span>
      </div>
    </section>
  )
}

type CatalogViewProps = {
  contexts: MarketplaceContext[]
  selectedKey: string
  onContextChange: (value: string) => void
  catalog: ProductCatalogPage | null
  loading: boolean
  error: string
  searchDraft: string
  search: string
  filters: Filters
  page: number
  selectedSku: string
  detail: ProductListingDetail | null
  detailLoading: boolean
  onSearchDraftChange: (value: string) => void
  onSearch: (event: FormEvent<HTMLFormElement>) => void
  onFilterChange: (field: keyof Filters, value: string) => void
  onReset: () => void
  onRefresh: () => void
  onPageChange: (page: number) => void
  onSelectSku: (sku: string) => void
  onCloseDetail: () => void
  onOpenSystem: () => void
}

function CatalogView(props: CatalogViewProps) {
  const {
    contexts, selectedKey, onContextChange, catalog, loading, error, searchDraft, search,
    filters, page, selectedSku, detail, detailLoading, onSearchDraftChange, onSearch,
    onFilterChange, onReset, onRefresh, onPageChange, onSelectSku, onCloseDetail, onOpenSystem,
  } = props
  const metrics = catalog?.metrics

  return (
    <>
      <ContextRail contexts={contexts} selectedKey={selectedKey} onChange={onContextChange} />
      <main className="main-content">
        <header className="page-heading">
          <div><span className="eyebrow">CATALOG OPERATIONS</span><h1>商品中心</h1><p>Amazon Listing 只读快照</p></div>
          <button className="icon-button" type="button" aria-label="刷新当前商品列表" title="刷新当前商品列表" disabled={!selectedKey || loading} onClick={onRefresh}>
            <RefreshCw className={loading ? 'is-spinning' : ''} aria-hidden="true" />
          </button>
        </header>

        {error ? <div className="inline-alert" role="alert"><CircleAlert aria-hidden="true" /><div><strong>商品数据读取失败</strong><span>{error}</span></div></div> : null}

        {contexts.length === 0 ? <EmptyContext onOpenSystem={onOpenSystem} /> : (
          <>
            <section className="metrics-grid" aria-label="商品指标">
              <article><span>全部 Listing</span><strong>{metrics?.totalListings ?? 0}</strong><Boxes aria-hidden="true" /></article>
              <article><span>在售</span><strong>{metrics?.activeListings ?? 0}</strong><CircleCheck aria-hidden="true" /></article>
              <article><span>MFN 自配送</span><strong>{metrics?.mfnListings ?? 0}</strong><Archive aria-hidden="true" /></article>
              <article className={metrics?.staleListings ? 'has-warning' : ''}><span>超过 24 小时</span><strong>{metrics?.staleListings ?? 0}</strong><Gauge aria-hidden="true" /></article>
            </section>

            <section className="catalog-tool" aria-labelledby="catalog-table-title">
              <div className="catalog-toolbar">
                <form className="search-form" role="search" onSubmit={onSearch}>
                  <Search aria-hidden="true" />
                  <input type="search" value={searchDraft} onChange={(event) => onSearchDraftChange(event.target.value)} placeholder="搜索 SKU、ASIN 或商品标题" aria-label="搜索商品" />
                  <button type="submit">搜索</button>
                </form>
                <div className="filter-group">
                  <SlidersHorizontal aria-hidden="true" />
                  <select aria-label="Listing 状态" value={filters.status} onChange={(event) => onFilterChange('status', event.target.value)}>
                    <option value="">全部状态</option><option value="Active">在售</option><option value="Inactive">停售</option><option value="Incomplete">信息不全</option><option value="Suppressed">被抑制</option>
                  </select>
                  <select aria-label="配送方式" value={filters.fulfillment} onChange={(event) => onFilterChange('fulfillment', event.target.value)}>
                    <option value="">全部配送</option><option value="Mfn">MFN</option><option value="Fba">FBA</option>
                  </select>
                  <select aria-label="数据新鲜度" value={filters.freshness} onChange={(event) => onFilterChange('freshness', event.target.value)}>
                    <option value="">全部时间</option><option value="fresh">15 分钟内</option><option value="aging">15 分钟至 24 小时</option><option value="stale">超过 24 小时</option>
                  </select>
                  <button className="reset-button" type="button" onClick={onReset} title="清除筛选"><RotateCcw aria-hidden="true" /><span>清除</span></button>
                </div>
              </div>

              <div className="table-meta">
                <h2 id="catalog-table-title">Listing 快照</h2>
                <span>{catalog?.totalItems ?? 0} 条结果{search ? ` · “${search}”` : ''}{metrics?.lastSynchronizedAtUtc ? ` · 最近同步 ${formatDate(metrics.lastSynchronizedAtUtc)}` : ''}</span>
              </div>

              <div className={`table-wrap ${loading ? 'is-loading' : ''}`} aria-busy={loading}>
                <table>
                  <thead><tr><th>商品 / SKU</th><th>配送</th><th>状态</th><th className="is-numeric">普通价</th><th className="is-numeric">企业价</th><th className="is-numeric">MFN 库存</th><th>数据时间</th></tr></thead>
                  <tbody>
                    {catalog?.items.map((item) => (
                      <tr key={item.sku}>
                        <td className="product-cell"><button type="button" onClick={() => onSelectSku(item.sku)}><strong>{item.title || '未命名商品'}</strong><span><code>{item.sku}</code>{item.asin ? ` · ${item.asin}` : ''}</span></button></td>
                        <td><span className={`channel-badge is-${item.fulfillment.toLowerCase()}`}>{item.fulfillment}</span></td>
                        <td><span className={`listing-status is-${item.status.toLowerCase()}`}>{listingStatusLabels[item.status] || item.status}</span></td>
                        <td className="is-numeric data-value">{formatCurrency(item.price, item.currencyCode)}</td>
                        <td className="is-numeric data-value">{formatCurrency(item.businessPrice, item.currencyCode)}</td>
                        <td className="is-numeric data-value">{item.fulfillment === 'MFN' ? item.mfnQuantity ?? '--' : '--'}</td>
                        <td><span className={`freshness is-${item.freshness}`}>{freshnessLabels[item.freshness]}</span><small>{formatDate(item.synchronizedAtUtc)}</small></td>
                      </tr>
                    ))}
                    {!loading && catalog?.items.length === 0 ? <tr className="empty-row"><td colSpan={7}><PackageSearch aria-hidden="true" /><span>当前筛选没有匹配的 Listing</span></td></tr> : null}
                  </tbody>
                </table>
              </div>

              <footer className="pagination">
                <span>第 {catalog?.totalPages ? page : 0} / {catalog?.totalPages ?? 0} 页</span>
                <div>
                  <button type="button" aria-label="上一页" title="上一页" disabled={page <= 1 || loading} onClick={() => onPageChange(page - 1)}><ChevronLeft aria-hidden="true" /></button>
                  <button type="button" aria-label="下一页" title="下一页" disabled={!catalog || page >= catalog.totalPages || loading} onClick={() => onPageChange(page + 1)}><ChevronRight aria-hidden="true" /></button>
                </div>
              </footer>
            </section>
          </>
        )}
      </main>

      {selectedSku ? (
        <div className="drawer-layer" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onCloseDetail() }}>
          <aside className="detail-drawer" aria-labelledby="detail-title">
            <header><div><span className="eyebrow">READ-ONLY SNAPSHOT</span><h2 id="detail-title">商品详情</h2></div><button className="icon-button" type="button" aria-label="关闭商品详情" title="关闭" onClick={onCloseDetail}><X aria-hidden="true" /></button></header>
            {detailLoading ? <div className="drawer-loading"><RefreshCw className="is-spinning" aria-hidden="true" />正在读取...</div> : null}
            {!detailLoading && detail ? (
              <div className="drawer-body">
                <div className="drawer-product"><Box aria-hidden="true" /><div><h3>{detail.title || '未命名商品'}</h3><code>{detail.sku}</code></div></div>
                <dl className="detail-list">
                  <div><dt>ASIN</dt><dd>{detail.asin || '--'}</dd></div><div><dt>Seller ID</dt><dd><code>{detail.sellerId}</code></dd></div><div><dt>Marketplace ID</dt><dd><code>{detail.marketplaceId}</code></dd></div><div><dt>配送方式</dt><dd>{detail.fulfillment}</dd></div><div><dt>Listing 状态</dt><dd>{listingStatusLabels[detail.status] || detail.status}</dd></div><div><dt>普通售价</dt><dd>{formatCurrency(detail.price, detail.currencyCode)}</dd></div><div><dt>企业售价</dt><dd>{formatCurrency(detail.businessPrice, detail.currencyCode)}</dd></div><div><dt>MFN 库存</dt><dd>{detail.fulfillment === 'MFN' ? detail.mfnQuantity ?? '--' : '--'}</dd></div><div><dt>Amazon 更新时间</dt><dd>{formatDate(detail.amazonUpdatedAtUtc, true)}</dd></div><div><dt>工作站同步时间</dt><dd>{formatDate(detail.synchronizedAtUtc, true)}</dd></div><div><dt>快照版本</dt><dd>v{detail.snapshotVersion}</dd></div><div><dt>来源</dt><dd>{detail.sourceReference || '--'}</dd></div>
                </dl>
                <div className="drawer-lock-note"><LockKeyhole aria-hidden="true" /><span>该页面只读取 Amazon 快照，不会直接修改商品。</span></div>
              </div>
            ) : null}
          </aside>
        </div>
      ) : null}
    </>
  )
}

function SystemView({ health, version, loading, error, onRefresh }: { health: SystemHealth | null; version: SystemVersion | null; loading: boolean; error: string; onRefresh: () => void }) {
  const components = [
    { label: '应用服务', icon: Server, value: health?.service },
    { label: '业务数据库', icon: Database, value: health?.database },
    { label: '磁盘空间', icon: HardDrive, value: health?.disk },
    { label: '后台 Worker', icon: Activity, value: health?.worker },
  ]

  return (
    <main className="main-content system-content">
      <header className="page-heading"><div><span className="eyebrow">SYSTEM RUNTIME</span><h1>系统状态</h1><p>服务、数据库和后台任务</p></div><button className="icon-button" type="button" aria-label="刷新系统状态" title="刷新系统状态" disabled={loading} onClick={onRefresh}><RefreshCw className={loading ? 'is-spinning' : ''} aria-hidden="true" /></button></header>
      {error ? <div className="inline-alert" role="alert"><CircleAlert aria-hidden="true" /><div><strong>系统状态读取失败</strong><span>{error}</span></div></div> : null}
      <section className="system-grid" aria-label="系统组件状态">
        {components.map(({ label, icon: Icon, value }) => <article key={label}><div><Icon aria-hidden="true" />{value ? <HealthBadge status={value.status} /> : <span className="health-badge">检查中</span>}</div><h2>{label}</h2><p>{value?.detail || '正在读取组件状态'}</p></article>)}
      </section>
      <section className="runtime-section" aria-labelledby="runtime-title">
        <div className="section-title"><div><span className="eyebrow">RUNTIME</span><h2 id="runtime-title">运行环境</h2></div><span>检查于 {formatDate(health?.checkedAtUtc, true)}</span></div>
        <dl><div><dt>应用版本</dt><dd>{version?.version || '--'}</dd></div><div><dt>实施阶段</dt><dd>{version?.phase || '--'}</dd></div><div><dt>数据库 Schema</dt><dd>{version?.databaseSchema || '--'}</dd></div><div><dt>数据库</dt><dd>{version?.databaseProvider || '--'}</dd></div><div><dt>监听地址</dt><dd><code>{health?.bindAddress || '--'}</code></dd></div><div><dt>可用磁盘</dt><dd>{formatBytes(health?.availableDiskBytes || 0)}</dd></div><div><dt>数据目录</dt><dd><code>{health?.dataRoot || '--'}</code></dd></div><div><dt>启动时间</dt><dd>{formatDate(version?.startedAtUtc, true)}</dd></div></dl>
      </section>
    </main>
  )
}

function App() {
  const [view, navigate] = useHashView()
  const [contexts, setContexts] = useState<MarketplaceContext[]>([])
  const [selectedKey, setSelectedKey] = useState('')
  const [catalog, setCatalog] = useState<ProductCatalogPage | null>(null)
  const [health, setHealth] = useState<SystemHealth | null>(null)
  const [version, setVersion] = useState<SystemVersion | null>(null)
  const [bootstrapLoading, setBootstrapLoading] = useState(true)
  const [catalogLoading, setCatalogLoading] = useState(false)
  const [bootstrapError, setBootstrapError] = useState('')
  const [catalogError, setCatalogError] = useState('')
  const [searchDraft, setSearchDraft] = useState('')
  const [search, setSearch] = useState('')
  const [filters, setFilters] = useState<Filters>(initialFilters)
  const [page, setPage] = useState(1)
  const [refreshSequence, setRefreshSequence] = useState(0)
  const [selectedSku, setSelectedSku] = useState('')
  const [detail, setDetail] = useState<ProductListingDetail | null>(null)
  const [detailLoading, setDetailLoading] = useState(false)

  const selectedContext = useMemo(() => contexts.find((context) => contextKey(context) === selectedKey), [contexts, selectedKey])

  const loadBootstrap = useCallback(async () => {
    setBootstrapLoading(true)
    setBootstrapError('')
    try {
      const [contextResult, healthResult, versionResult] = await Promise.all([
        getJson<MarketplaceContext[]>('/api/v3/workspace/contexts'),
        getJson<SystemHealth>('/api/v2/system/health', undefined, true),
        getJson<SystemVersion>('/api/v2/system/version'),
      ])
      setContexts(contextResult)
      setHealth(healthResult)
      setVersion(versionResult)
      setSelectedKey((current) => contextResult.some((context) => contextKey(context) === current) ? current : contextResult[0] ? contextKey(contextResult[0]) : '')
    } catch (error) {
      setBootstrapError(error instanceof Error ? error.message : '工作站初始化失败')
    } finally {
      setBootstrapLoading(false)
    }
  }, [])

  useEffect(() => { void loadBootstrap() }, [loadBootstrap])

  useEffect(() => {
    if (!selectedContext) { setCatalog(null); return }
    const controller = new AbortController()
    const loadCatalog = async () => {
      setCatalogLoading(true)
      setCatalogError('')
      const params = new URLSearchParams({ sellerId: selectedContext.sellerId, marketplaceId: selectedContext.marketplaceId, page: String(page), pageSize: '50' })
      if (search) params.set('search', search)
      if (filters.status) params.set('status', filters.status)
      if (filters.fulfillment) params.set('fulfillment', filters.fulfillment)
      if (filters.freshness) params.set('freshness', filters.freshness)
      try {
        setCatalog(await getJson<ProductCatalogPage>(`/api/v3/catalog/listings?${params}`, controller.signal))
      } catch (error) {
        if (error instanceof DOMException && error.name === 'AbortError') return
        setCatalogError(error instanceof Error ? error.message : '商品数据读取失败')
      } finally {
        if (!controller.signal.aborted) setCatalogLoading(false)
      }
    }
    void loadCatalog()
    return () => controller.abort()
  }, [selectedContext, search, filters, page, refreshSequence])

  useEffect(() => {
    if (!selectedContext || !selectedSku) { setDetail(null); return }
    const controller = new AbortController()
    const loadDetail = async () => {
      setDetailLoading(true)
      try {
        const params = new URLSearchParams({ sellerId: selectedContext.sellerId, marketplaceId: selectedContext.marketplaceId })
        setDetail(await getJson<ProductListingDetail>(`/api/v3/catalog/listings/${encodeURIComponent(selectedSku)}?${params}`, controller.signal))
      } catch (error) {
        if (!(error instanceof DOMException && error.name === 'AbortError')) setDetail(null)
      } finally {
        if (!controller.signal.aborted) setDetailLoading(false)
      }
    }
    void loadDetail()
    return () => controller.abort()
  }, [selectedContext, selectedSku])

  const changeContext = (value: string) => { setSelectedKey(value); setPage(1); setSelectedSku('') }
  const submitSearch = (event: FormEvent<HTMLFormElement>) => { event.preventDefault(); setSearch(searchDraft.trim()); setPage(1) }
  const changeFilter = (field: keyof Filters, value: string) => { setFilters((current) => ({ ...current, [field]: value })); setPage(1) }
  const resetFilters = () => { setSearchDraft(''); setSearch(''); setFilters(initialFilters); setPage(1) }
  const overallStatus = health?.overallStatus || (bootstrapError ? 'unhealthy' : 'degraded')

  return (
    <div className="app-shell">
      <aside className="sidebar desktop-sidebar">
        <div className="brand"><span className="brand-mark">K</span><div><strong>Klanata</strong><span>Amazon Operations</span></div></div>
        <PrimaryNavigation view={view} label="主导航" />
        <div className="sidebar-status"><span className={`status-dot is-${overallStatus}`} aria-hidden="true" /><div><strong>{overallStatus === 'healthy' ? '平台正常' : overallStatus === 'unhealthy' ? '平台异常' : '平台需关注'}</strong><span>{version?.phase || '正在读取运行状态'}</span></div></div>
      </aside>

      <div className="workspace">
        <header className="topbar"><div className="topbar-location"><Store aria-hidden="true" /><span>{view === 'catalog' ? '商品运营工作站' : view === 'pricing' ? 'API 原生调价工作站' : '运行与安全'}</span></div><div className="topbar-meta"><span>{health?.environment || 'Loading'}</span><strong>v{version?.version?.split('+')[0] || '--'}</strong></div></header>
        {view === 'catalog' ? (
          <CatalogView contexts={contexts} selectedKey={selectedKey} onContextChange={changeContext} catalog={catalog} loading={catalogLoading || bootstrapLoading} error={catalogError || bootstrapError} searchDraft={searchDraft} search={search} filters={filters} page={page} selectedSku={selectedSku} detail={detail} detailLoading={detailLoading} onSearchDraftChange={setSearchDraft} onSearch={submitSearch} onFilterChange={changeFilter} onReset={resetFilters} onRefresh={() => setRefreshSequence((value) => value + 1)} onPageChange={setPage} onSelectSku={setSelectedSku} onCloseDetail={() => setSelectedSku('')} onOpenSystem={() => navigate('system')} />
        ) : view === 'pricing' ? (
          <PricingView contexts={contexts} selectedKey={selectedKey} onContextChange={changeContext} bootstrapLoading={bootstrapLoading} bootstrapError={bootstrapError} onOpenSystem={() => navigate('system')} />
        ) : (
          <SystemView health={health} version={version} loading={bootstrapLoading} error={bootstrapError} onRefresh={() => void loadBootstrap()} />
        )}
      </div>
      <PrimaryNavigation view={view} className="mobile-navigation" label="移动主导航" />
    </div>
  )
}

export default App
