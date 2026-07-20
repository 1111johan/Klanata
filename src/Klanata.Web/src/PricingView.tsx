import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  ArrowDown,
  ArrowRight,
  ArrowUp,
  BadgeCheck,
  Check,
  ChevronLeft,
  ChevronRight,
  CircleAlert,
  CircleCheck,
  Clock3,
  DatabaseZap,
  FileCheck2,
  Filter,
  LoaderCircle,
  LockKeyhole,
  RefreshCw,
  ShieldCheck,
  SlidersHorizontal,
  Store,
} from 'lucide-react'
import './pricing.css'

export type MarketplaceCapabilities = {
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

export type MarketplaceContext = {
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

type LocalSession = { csrfToken: string }
type AdjustmentType = 'FIXED_AMOUNT' | 'PERCENTAGE'
type Direction = 'INCREASE' | 'DECREASE'

type PricingSyncStatus = {
  sellerId: string
  marketplaceId: string
  state?: string
  status?: string
  syncState?: string
  hasSnapshot?: boolean
  isFresh?: boolean
  canStart?: boolean
  canStartPricingRun?: boolean
  snapshotVersion?: number
  latestSnapshotVersion?: number
  listingCount?: number
  totalListings?: number
  eligibleListings?: number
  excludedListings?: number
  synchronizedAtUtc?: string
  lastSynchronizedAtUtc?: string
  freshnessExpiresAtUtc?: string
  snapshotAgeSeconds?: number
  blockReason?: string
  writeBlockReason?: string
  detail?: string
}

type PricingRule = {
  id: string
  version: number
  name: string
  direction: Direction
  threshold: number
  belowThreshold: { type: AdjustmentType; value: number }
  atOrAboveThreshold: { type: AdjustmentType; value: number }
  absoluteChangeCap?: number
  percentageChangeCap?: number
  currencyPrecision: number
  businessPriceStrategy: 'UNCHANGED'
}

type PricingRunItem = {
  id: string
  sku: string
  asin?: string
  title?: string
  eligible: boolean
  exclusionCodes: string[]
  exclusionReasons: string[]
  currentPrice?: number | null
  targetPrice?: number | null
  priceChange?: number | null
  priceChangePercent?: number | null
  currentBusinessPrice?: number | null
  targetBusinessPrice?: number | null
  currencyCode: string
  snapshotVersion: number
  synchronizedAtUtc: string
}

type PricingRun = {
  id: string
  runNumber: string
  sellerId: string
  marketplaceId: string
  status: string
  initiatedBy: string
  createdAtUtc: string
  rule: PricingRule
  summary: { total: number; eligible: number; excluded: number }
  items: PricingRunItem[]
}

type ChangeSet = {
  id: string
  runId: string
  sellerId: string
  marketplaceId: string
  status: string
  initiatedBy: string
  itemCount: number
  createdAtUtc: string
  approval: null | { approver?: string; approvedAtUtc?: string; identityVerified?: boolean; identityAssurance?: string }
}

type ProblemDetails = {
  title?: string
  detail?: string
  status?: number
  code?: string
  errors?: Record<string, string[]>
}

type ValidationState = {
  kind: 'idle' | 'running' | 'passed' | 'blocked'
  title: string
  detail: string
  code?: string
}

type RuleDraft = {
  name: string
  direction: Direction
  threshold: string
  lowerType: AdjustmentType
  lowerValue: string
  upperType: AdjustmentType
  upperValue: string
  absoluteCap: string
  percentageCap: string
}

type PricingViewProps = {
  contexts: MarketplaceContext[]
  selectedKey: string
  onContextChange: (value: string) => void
  bootstrapLoading: boolean
  bootstrapError: string
}

const steps = [
  { label: '商品同步', icon: DatabaseZap },
  { label: '候选筛选', icon: Filter },
  { label: '调价规则', icon: SlidersHorizontal },
  { label: '差异审核', icon: FileCheck2 },
  { label: '复核门禁', icon: ShieldCheck },
  { label: '结果核验', icon: BadgeCheck },
] as const

const initialRule: RuleDraft = {
  name: '纯 FBM 日常调价',
  direction: 'INCREASE',
  threshold: '100',
  lowerType: 'FIXED_AMOUNT',
  lowerValue: '0.50',
  upperType: 'PERCENTAGE',
  upperValue: '0.50',
  absoluteCap: '0.90',
  percentageCap: '5',
}

const initialConfirmations = {
  sellerMarketplace: false,
  ruleVersion: false,
  anomaliesReviewed: false,
  amazonAcceptance: false,
}

const initialValidation: ValidationState = {
  kind: 'idle',
  title: '尚未执行生产校验',
  detail: '复核记录完成后才能验证 Amazon 提交条件。',
}

const snapshotFreshnessMs = 12 * 60 * 60 * 1000
const pricingItemPageSize = 100

function contextKey(context: MarketplaceContext) {
  return `${context.sellerId}::${context.marketplaceId}`
}

function formatDate(value?: string) {
  if (!value) return '--'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return new Intl.DateTimeFormat('zh-CN', {
    month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
  }).format(date)
}

function formatMoney(value: number | null | undefined, currency: string) {
  if (value == null) return '--'
  try {
    return new Intl.NumberFormat('zh-CN', { style: 'currency', currency, minimumFractionDigits: 2 }).format(value)
  } catch {
    return `${currency} ${value.toFixed(2)}`
  }
}

async function readBody<T>(response: Response): Promise<T> {
  const text = await response.text()
  return (text ? JSON.parse(text) : {}) as T
}

async function getJson<T>(path: string, signal?: AbortSignal): Promise<T> {
  const response = await fetch(path, { credentials: 'same-origin', headers: { Accept: 'application/json' }, signal })
  const body = await readBody<T & ProblemDetails>(response)
  if (!response.ok) throw Object.assign(new Error(body.detail || body.title || `请求失败（HTTP ${response.status}）`), { problem: body })
  return body
}

async function postJson<T>(path: string, csrfToken: string, body: unknown): Promise<T> {
  if (!csrfToken) throw new Error('安全会话尚未建立，生产操作已阻止。')
  const response = await fetch(path, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-Klanata-Csrf': csrfToken },
    body: JSON.stringify(body),
  })
  const result = await readBody<T & ProblemDetails>(response)
  if (!response.ok) throw Object.assign(new Error(result.detail || result.title || `请求失败（HTTP ${response.status}）`), { problem: result })
  return result
}

function getProblem(error: unknown): ProblemDetails | undefined {
  return (error as { problem?: ProblemDetails } | undefined)?.problem
}

function toNumber(value: string) {
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : 0
}

function optionalNumber(value: string) {
  if (!value.trim()) return undefined
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : undefined
}

function getSnapshotTime(status: PricingSyncStatus | null) {
  return status?.lastSynchronizedAtUtc || status?.synchronizedAtUtc
}

function isReviewRecorded(changeSet: ChangeSet | null) {
  return changeSet?.status?.trim().toLowerCase() === 'review_recorded'
}

function getSnapshotExpiry(status: PricingSyncStatus | null) {
  if (!status) return undefined
  const explicitExpiry = status.freshnessExpiresAtUtc ? new Date(status.freshnessExpiresAtUtc).getTime() : Number.NaN
  if (Number.isFinite(explicitExpiry)) return explicitExpiry
  const timestamp = getSnapshotTime(status)
  if (!timestamp) return undefined
  const synchronizedAt = new Date(timestamp).getTime()
  return Number.isFinite(synchronizedAt) ? synchronizedAt + snapshotFreshnessMs : undefined
}

function isSnapshotFresh(status: PricingSyncStatus | null, now: number) {
  if (!status) return false
  const serverReady = typeof status.canStart === 'boolean'
    ? status.canStart
    : typeof status.canStartPricingRun === 'boolean'
      ? status.canStartPricingRun
      : status.isFresh
  if (serverReady === false) return false
  const expiresAt = getSnapshotExpiry(status)
  if (expiresAt !== undefined && now >= expiresAt) return false
  return serverReady === true || expiresAt !== undefined
}

export default function PricingView({ contexts, selectedKey, onContextChange, bootstrapLoading, bootstrapError }: PricingViewProps) {
  const selected = useMemo(() => contexts.find((item) => contextKey(item) === selectedKey), [contexts, selectedKey])
  const [csrfToken, setCsrfToken] = useState('')
  const [sessionError, setSessionError] = useState('')
  const [syncStatus, setSyncStatus] = useState<PricingSyncStatus | null>(null)
  const [syncError, setSyncError] = useState('')
  const [syncErrorCode, setSyncErrorCode] = useState('')
  const [syncing, setSyncing] = useState(false)
  const [activeStep, setActiveStep] = useState(0)
  const [rule, setRule] = useState<RuleDraft>(initialRule)
  const [initiator, setInitiator] = useState('')
  const [approver, setApprover] = useState('')
  const [run, setRun] = useState<PricingRun | null>(null)
  const [changeSet, setChangeSet] = useState<ChangeSet | null>(null)
  const [confirmations, setConfirmations] = useState(initialConfirmations)
  const [validation, setValidation] = useState<ValidationState>(initialValidation)
  const [action, setAction] = useState('')
  const [actionError, setActionError] = useState('')
  const [runIdempotencyKey, setRunIdempotencyKey] = useState(() => crypto.randomUUID())
  const [freshnessNow, setFreshnessNow] = useState(() => Date.now())
  const [itemPage, setItemPage] = useState(1)
  const runContext = useMemo(
    () => run ? contexts.find((item) => item.sellerId === run.sellerId && item.marketplaceId === run.marketplaceId) : selected,
    [contexts, run, selected],
  )

  useEffect(() => {
    const controller = new AbortController()
    getJson<LocalSession>('/api/v2/system/session', controller.signal)
      .then((session) => { setCsrfToken(session.csrfToken); setSessionError('') })
      .catch((error: unknown) => {
        if (error instanceof DOMException && error.name === 'AbortError') return
        setSessionError(error instanceof Error ? error.message : '安全会话建立失败')
      })
    return () => controller.abort()
  }, [])

  const loadSyncStatus = useCallback(async (signal?: AbortSignal) => {
    if (!selected) return
    const params = new URLSearchParams({ sellerId: selected.sellerId, marketplaceId: selected.marketplaceId })
    try {
      const next = await getJson<PricingSyncStatus>(`/api/v4/pricing/sync-status?${params}`, signal)
      if (next.sellerId !== selected.sellerId || next.marketplaceId !== selected.marketplaceId) {
        throw new Error('同步状态上下文与所选店铺或站点不一致。')
      }
      setSyncStatus(next)
      setSyncError('')
      setSyncErrorCode('')
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return
      setSyncError(error instanceof Error ? error.message : '同步状态读取失败')
      setSyncErrorCode(getProblem(error)?.code || '')
    }
  }, [selected])

  useEffect(() => {
    setSyncStatus(null)
    setSyncError('')
    setSyncErrorCode('')
    setActiveStep(0)
    setRun(null)
    setChangeSet(null)
    setApprover('')
    setConfirmations(initialConfirmations)
    setValidation(initialValidation)
    setActionError('')
    setItemPage(1)
    if (!selected) return
    const controller = new AbortController()
    void loadSyncStatus(controller.signal)
    return () => controller.abort()
  }, [selected, loadSyncStatus])

  useEffect(() => {
    setRunIdempotencyKey(crypto.randomUUID())
  }, [selectedKey, rule, initiator])

  useEffect(() => {
    setFreshnessNow(Date.now())
    const expiresAt = getSnapshotExpiry(syncStatus)
    if (expiresAt === undefined) return
    const delay = expiresAt - Date.now()
    if (delay <= 0) return
    const controller = new AbortController()
    const timeout = window.setTimeout(() => {
      setFreshnessNow(Date.now())
      void loadSyncStatus(controller.signal)
    }, Math.min(delay + 250, 2_147_483_647))
    return () => {
      window.clearTimeout(timeout)
      controller.abort()
    }
  }, [syncStatus, loadSyncStatus])

  const snapshotFresh = isSnapshotFresh(syncStatus, freshnessNow)
  const snapshotTime = getSnapshotTime(syncStatus)
  const listingCount = syncStatus?.totalListings ?? syncStatus?.listingCount ?? 0
  const latestVersion = syncStatus?.latestSnapshotVersion ?? syncStatus?.snapshotVersion
  const authReady = Boolean(selected?.capabilities.canReadListings && selected.capabilities.canReadPricing)
  const simulationReady = Boolean(authReady && selected?.capabilities.canSimulatePricing)
  const changeSetReady = Boolean(selected?.capabilities.canCreateDraftChangeSets)
  const allConfirmed = Object.values(confirmations).every(Boolean)
  const lockedInitiator = run?.initiatedBy || initiator
  const identityConflict = Boolean(lockedInitiator.trim() && approver.trim() && lockedInitiator.trim().toLocaleLowerCase() === approver.trim().toLocaleLowerCase())
  const reviewRecorded = isReviewRecorded(changeSet)
  const operationInFlight = syncing || Boolean(action)
  const contextLocked = operationInFlight || Boolean(run) || Boolean(changeSet)
  const maxStep = validation.kind !== 'idle' || reviewRecorded ? 5 : changeSet ? 4 : run ? 3 : snapshotFresh ? 2 : syncStatus ? 1 : 0
  const minStep = run ? 3 : 0
  const itemPageCount = Math.max(1, Math.ceil((run?.items.length ?? 0) / pricingItemPageSize))
  const currentItemPage = Math.min(itemPage, itemPageCount)
  const visibleRunItems = useMemo(
    () => run?.items.slice((currentItemPage - 1) * pricingItemPageSize, currentItemPage * pricingItemPageSize) ?? [],
    [currentItemPage, run],
  )

  const syncProducts = async () => {
    if (!selected) return
    const requestedSellerId = selected.sellerId
    const requestedMarketplaceId = selected.marketplaceId
    setSyncing(true)
    setSyncError('')
    setSyncErrorCode('')
    try {
      const next = await postJson<PricingSyncStatus>('/api/v4/pricing/sync', csrfToken, {
        sellerId: requestedSellerId,
        marketplaceId: requestedMarketplaceId,
      })
      if (next.sellerId !== requestedSellerId || next.marketplaceId !== requestedMarketplaceId) {
        throw new Error('同步响应上下文与请求的店铺或站点不一致。')
      }
      setSyncStatus(next)
      if (next.state === 'SNAPSHOT_FRESH' && next.canStart === true) {
        setActiveStep(1)
      } else {
        setSyncError(next.detail || '同步请求已接收，但尚未形成可用的完整快照。')
        setSyncErrorCode(next.state || 'SYNC_NOT_READY')
      }
    } catch (error) {
      setSyncError(error instanceof Error ? error.message : 'Amazon 商品同步失败')
      setSyncErrorCode(getProblem(error)?.code || '')
    } finally {
      setSyncing(false)
    }
  }

  const createRun = async () => {
    if (!selected || run) return
    const requestedSellerId = selected.sellerId
    const requestedMarketplaceId = selected.marketplaceId
    setAction('run')
    setActionError('')
    try {
      const created = await postJson<PricingRun>('/api/v4/pricing/runs', csrfToken, {
        sellerId: requestedSellerId,
        marketplaceId: requestedMarketplaceId,
        initiator: initiator.trim(),
        idempotencyKey: runIdempotencyKey,
        rule: {
          name: rule.name.trim(),
          direction: rule.direction,
          threshold: toNumber(rule.threshold),
          belowThreshold: { type: rule.lowerType, value: toNumber(rule.lowerValue) },
          atOrAboveThreshold: { type: rule.upperType, value: toNumber(rule.upperValue) },
          absoluteChangeCap: optionalNumber(rule.absoluteCap),
          percentageChangeCap: optionalNumber(rule.percentageCap),
          businessPriceStrategy: 'UNCHANGED',
        },
      })
      if (created.sellerId !== requestedSellerId || created.marketplaceId !== requestedMarketplaceId) {
        throw new Error('调价任务上下文与请求的店铺或站点不一致，页面已阻止继续。')
      }
      setRun(created)
      setChangeSet(null)
      setApprover('')
      setConfirmations(initialConfirmations)
      setValidation(initialValidation)
      setItemPage(1)
      setActiveStep(3)
    } catch (error) {
      setActionError(error instanceof Error ? error.message : '调价预览创建失败')
    } finally {
      setAction('')
    }
  }

  const createChangeSet = async () => {
    if (!run || changeSet) return
    setAction('change-set')
    setActionError('')
    try {
      const created = await postJson<ChangeSet>(`/api/v4/pricing/runs/${encodeURIComponent(run.id)}/change-sets`, csrfToken, {})
      if (created.runId !== run.id || created.sellerId !== run.sellerId || created.marketplaceId !== run.marketplaceId) {
        throw new Error('变更集上下文与调价任务不一致，页面已阻止继续复核。')
      }
      setChangeSet(created)
      setActiveStep(4)
    } catch (error) {
      setActionError(error instanceof Error ? error.message : '变更集创建失败')
    } finally {
      setAction('')
    }
  }

  const approveChangeSet = async () => {
    if (!changeSet || reviewRecorded) return
    setAction('approve')
    setActionError('')
    try {
      const approved = await postJson<ChangeSet>(`/api/v4/pricing/change-sets/${encodeURIComponent(changeSet.id)}/approve`, csrfToken, {
        approver: approver.trim(), confirmations,
      })
      if (approved.id !== changeSet.id || approved.runId !== changeSet.runId || approved.sellerId !== changeSet.sellerId || approved.marketplaceId !== changeSet.marketplaceId) {
        throw new Error('复核响应上下文与当前变更集不一致，页面已阻止继续。')
      }
      setChangeSet(approved)
      if (isReviewRecorded(approved)) setActiveStep(5)
    } catch (error) {
      setActionError(error instanceof Error ? error.message : '复核记录失败')
    } finally {
      setAction('')
    }
  }

  const validateChangeSet = async () => {
    if (!changeSet || !isReviewRecorded(changeSet)) return
    setValidation({ kind: 'running', title: '正在执行生产校验', detail: '核对快照、规则版本、锁和 Amazon 提交条件。' })
    setActionError('')
    try {
      const result = await postJson<{ title?: string; detail?: string; state?: string; verified?: boolean }>(`/api/v4/pricing/change-sets/${encodeURIComponent(changeSet.id)}/validate`, csrfToken, {})
      if (result.verified !== true || result.state !== 'READY_TO_SUBMIT') {
        throw new Error('生产校验没有返回明确的 READY_TO_SUBMIT 验证状态。')
      }
      setValidation({ kind: 'passed', title: result.title || '生产校验通过', detail: result.detail || '变更集具备后续提交条件。' })
    } catch (error) {
      const problem = getProblem(error)
      setValidation({
        kind: 'blocked',
        title: problem?.title || '生产提交已阻止',
        detail: problem?.detail || (error instanceof Error ? error.message : '生产校验失败'),
        code: problem?.code,
      })
    }
  }

  const ruleValid = Boolean(rule.name.trim() && initiator.trim() && toNumber(rule.threshold) > 0 && toNumber(rule.lowerValue) > 0 && toNumber(rule.upperValue) > 0)

  const resetPricingFlow = () => {
    if (operationInFlight) return
    setRun(null)
    setChangeSet(null)
    setApprover('')
    setConfirmations(initialConfirmations)
    setValidation(initialValidation)
    setActionError('')
    setRunIdempotencyKey(crypto.randomUUID())
    setItemPage(1)
    setActiveStep(snapshotFresh ? 1 : 0)
  }

  return (
    <div className="pricing-page">
      <section className="pricing-context" aria-label="当前调价上下文">
        <div className="pricing-context-select">
          <label htmlFor="pricing-context">Carkee 站点</label>
          <select id="pricing-context" value={selectedKey} onChange={(event) => onContextChange(event.target.value)} disabled={!contexts.length || bootstrapLoading || contextLocked}>
            {!contexts.length ? <option value="">等待 Amazon 授权</option> : null}
            {contexts.map((context) => <option key={contextKey(context)} value={contextKey(context)}>{context.sellerName} · {context.marketplaceName}</option>)}
          </select>
        </div>
        <div className="pricing-context-fact"><Store aria-hidden="true" /><span>Seller</span><strong>{selected?.sellerId || '--'}</strong></div>
        <div className="pricing-context-fact"><ShieldCheck aria-hidden="true" /><span>授权</span><strong className={authReady ? 'is-positive' : 'is-blocked'}>{authReady ? '读取已验证' : '读取未就绪'}</strong></div>
        <div className="pricing-context-fact"><Clock3 aria-hidden="true" /><span>数据新鲜度</span><strong className={snapshotFresh ? 'is-positive' : 'is-blocked'}>{snapshotFresh ? `快照 v${latestVersion ?? '--'}` : '需要同步'}</strong><small>{formatDate(snapshotTime)}</small></div>
      </section>

      <main className="main-content pricing-main">
        <header className="pricing-heading">
          <div><span className="eyebrow">API-NATIVE PRICING</span><h1>智能调价</h1><p>一次任务只绑定一个店铺和一个站点，企业价固定不修改。</p></div>
          <div className="pricing-run-id"><span>当前任务</span><strong>{run?.runNumber || '未创建'}</strong>{run ? <button type="button" disabled={operationInFlight} onClick={resetPricingFlow}>新建任务</button> : null}</div>
        </header>

        {bootstrapError || sessionError ? <div className="pricing-alert is-danger" role="alert"><CircleAlert aria-hidden="true" /><div><strong>调价操作已阻止</strong><span>{bootstrapError || sessionError}</span></div></div> : null}

        <nav className="pricing-steps" aria-label="调价流程">
          {steps.map(({ label, icon: Icon }, index) => {
            const complete = index < activeStep || (index === 5 && validation.kind === 'passed')
            return <button key={label} type="button" aria-current={index === activeStep ? 'step' : undefined} className={`${index === activeStep ? 'is-active' : ''} ${complete ? 'is-complete' : ''}`} disabled={index < minStep || index > maxStep} onClick={() => setActiveStep(index)}><span className="step-index">{complete ? <Check aria-hidden="true" /> : index + 1}</span><Icon aria-hidden="true" /><span>{label}</span></button>
          })}
        </nav>

        <section className="pricing-stage">
          {activeStep === 0 ? (
            <div className="stage-layout is-sync">
              <div className="stage-copy"><span className="stage-number">01</span><div><h2>从 Amazon 同步最新商品</h2><p>系统直接读取 Listing、价格、库存和配送方式，不再要求上传 Excel 或 TXT。</p></div></div>
              <div className="sync-panel">
                <div className="sync-state"><DatabaseZap aria-hidden="true" /><div><span>当前快照</span><strong>{syncStatus ? `${listingCount} 条 Listing` : '尚未读取'}</strong><small>{snapshotTime ? `同步于 ${formatDate(snapshotTime)}` : '同步失败时会保留上一次可用快照'}</small></div></div>
                {syncError || (syncStatus && !snapshotFresh && syncStatus.detail) ? <div className="stage-block" role="alert"><CircleAlert aria-hidden="true" /><div><strong>{syncErrorCode || syncStatus?.state || 'Amazon 同步不可用'}</strong><span>{syncError || syncStatus?.detail}</span><small>未生成成功状态，上一次快照保持不变。</small></div></div> : null}
                <button className="primary-action" type="button" disabled={!selected || !csrfToken || syncing || !authReady} onClick={() => void syncProducts()}>{syncing ? <LoaderCircle className="is-spinning" aria-hidden="true" /> : <RefreshCw aria-hidden="true" />}{syncing ? '正在同步' : '同步 Amazon 商品'}</button>
                {snapshotFresh ? <button className="text-action" type="button" onClick={() => setActiveStep(1)}>使用当前快照继续<ArrowRight aria-hidden="true" /></button> : null}
              </div>
            </div>
          ) : null}

          {activeStep === 1 ? (
            <div className="stage-layout">
              <div className="stage-copy"><span className="stage-number">02</span><div><h2>自动筛选纯 FBM 候选</h2><p>排除原因会随 SKU 保存，运营无需手动整理表格。</p></div></div>
              <div className="eligibility-grid">
                <article><CircleCheck aria-hidden="true" /><h3>候选条件</h3><p>在线、可售、MFN 自配送、库存大于 0、价格数据新鲜。</p></article>
                <article><LockKeyhole aria-hidden="true" /><h3>快照筛选</h3><p>排除 FBA、同 ASIN 存在 FBA、停售或抑制、零库存等不符合纯 FBM 条件的 Listing。</p></article>
                <article><FileCheck2 aria-hidden="true" /><h3>提交门禁</h3><p>自动调价状态、最新价格与并发冲突将在生产提交前实时核验；每条已知排除原因均保留。</p></article>
              </div>
              <div className="stage-footer"><span>快照 v{latestVersion ?? '--'} · {listingCount} 条商品</span><button className="primary-action" type="button" onClick={() => setActiveStep(2)}>配置调价规则<ArrowRight aria-hidden="true" /></button></div>
            </div>
          ) : null}

          {activeStep === 2 ? (
            <div className="stage-layout">
              <div className="stage-copy"><span className="stage-number">03</span><div><h2>配置版本化调价规则</h2><p>以 {selected?.currencyCode || '站点币种'} 100 为分界分别计算，并同时受两类幅度上限保护。</p></div></div>
              <div className="rule-form">
                <label className="field is-wide"><span>规则名称</span><input value={rule.name} onChange={(event) => setRule((current) => ({ ...current, name: event.target.value }))} /></label>
                <label className="field"><span>任务发起人</span><input value={initiator} onChange={(event) => setInitiator(event.target.value)} placeholder="输入姓名或工号" /></label>
                <fieldset className="segmented-field"><legend>调整方向</legend><div><button type="button" aria-pressed={rule.direction === 'INCREASE'} className={rule.direction === 'INCREASE' ? 'is-selected' : ''} onClick={() => setRule((current) => ({ ...current, direction: 'INCREASE' }))}><ArrowUp aria-hidden="true" />涨价</button><button type="button" aria-pressed={rule.direction === 'DECREASE'} className={rule.direction === 'DECREASE' ? 'is-selected' : ''} onClick={() => setRule((current) => ({ ...current, direction: 'DECREASE' }))}><ArrowDown aria-hidden="true" />降价</button></div></fieldset>
                <label className="field"><span>价格分界</span><div className="input-suffix"><input type="number" min="0.01" step="0.01" value={rule.threshold} onChange={(event) => setRule((current) => ({ ...current, threshold: event.target.value }))} /><span>{selected?.currencyCode || '币种'}</span></div></label>
                <div className="band-rule"><div><strong>小于等于 {rule.threshold || '100'}</strong><small>较低售价区间</small></div><select aria-label="低价区间调整方式" value={rule.lowerType} onChange={(event) => setRule((current) => ({ ...current, lowerType: event.target.value as AdjustmentType }))}><option value="FIXED_AMOUNT">固定金额</option><option value="PERCENTAGE">百分比</option></select><div className="input-suffix"><input aria-label="低价区间调整值" type="number" min="0.01" step="0.01" value={rule.lowerValue} onChange={(event) => setRule((current) => ({ ...current, lowerValue: event.target.value }))} /><span>{rule.lowerType === 'PERCENTAGE' ? '%' : selected?.currencyCode || '金额'}</span></div></div>
                <div className="band-rule"><div><strong>大于 {rule.threshold || '100'}</strong><small>较高售价区间</small></div><select aria-label="高价区间调整方式" value={rule.upperType} onChange={(event) => setRule((current) => ({ ...current, upperType: event.target.value as AdjustmentType }))}><option value="FIXED_AMOUNT">固定金额</option><option value="PERCENTAGE">百分比</option></select><div className="input-suffix"><input aria-label="高价区间调整值" type="number" min="0.01" step="0.01" value={rule.upperValue} onChange={(event) => setRule((current) => ({ ...current, upperValue: event.target.value }))} /><span>{rule.upperType === 'PERCENTAGE' ? '%' : selected?.currencyCode || '金额'}</span></div></div>
                <label className="field"><span>单次绝对上限</span><div className="input-suffix"><input type="number" min="0" step="0.01" value={rule.absoluteCap} onChange={(event) => setRule((current) => ({ ...current, absoluteCap: event.target.value }))} /><span>{selected?.currencyCode || '金额'}</span></div></label>
                <label className="field"><span>单次百分比上限</span><div className="input-suffix"><input type="number" min="0" step="0.01" value={rule.percentageCap} onChange={(event) => setRule((current) => ({ ...current, percentageCap: event.target.value }))} /><span>%</span></div></label>
                <div className="b2b-lock"><LockKeyhole aria-hidden="true" /><div><span>企业价格策略</span><strong>不修改</strong></div></div>
              </div>
              {actionError ? <div className="pricing-alert is-danger" role="alert"><CircleAlert aria-hidden="true" /><div><strong>无法创建调价预览</strong><span>{actionError}</span></div></div> : null}
              <div className="stage-footer"><span>创建后生成不可变规则版本和逐 SKU 差异。</span><button className="primary-action" type="button" disabled={Boolean(run) || !snapshotFresh || !simulationReady || !ruleValid || action === 'run'} onClick={() => void createRun()}>{action === 'run' ? <LoaderCircle className="is-spinning" aria-hidden="true" /> : <FileCheck2 aria-hidden="true" />}生成差异预览</button></div>
            </div>
          ) : null}

          {activeStep === 3 ? (
            <div className="stage-layout">
              <div className="stage-copy"><span className="stage-number">04</span><div><h2>逐 SKU 审核价格差异</h2><p>报告快照价、目标价、幅度、排除原因和风险在同一张表中核对；提交前还会核验最新价。</p></div></div>
              {run ? <>
                <div className="run-summary"><div><span>总商品</span><strong>{run.summary.total}</strong></div><div className="is-green"><span>可调价</span><strong>{run.summary.eligible}</strong></div><div className="is-amber"><span>已排除</span><strong>{run.summary.excluded}</strong></div><div><span>规则版本</span><strong>v{run.rule.version}</strong></div></div>
                <div className="pricing-table-wrap"><table className="pricing-table"><thead><tr><th>商品 / SKU</th><th>状态</th><th className="is-numeric">报告快照价</th><th className="is-numeric">目标价</th><th className="is-numeric">差额</th><th className="is-numeric">幅度</th><th>排除 / 风险</th></tr></thead><tbody>{visibleRunItems.map((item) => <tr key={item.id || item.sku} className={!item.eligible ? 'is-excluded' : ''}><td><strong>{item.title || item.sku}</strong><span><code>{item.sku}</code>{item.asin ? ` · ${item.asin}` : ''}</span></td><td><span className={`eligibility ${item.eligible ? 'is-eligible' : ''}`}>{item.eligible ? '候选' : '排除'}</span></td><td className="is-numeric">{formatMoney(item.currentPrice, item.currencyCode)}</td><td className="is-numeric"><strong>{formatMoney(item.targetPrice, item.currencyCode)}</strong></td><td className={`is-numeric ${item.priceChange == null ? '' : item.priceChange >= 0 ? 'delta-up' : 'delta-down'}`}>{item.priceChange == null ? '--' : `${item.priceChange >= 0 ? '+' : ''}${item.priceChange.toFixed(2)}`}</td><td className="is-numeric">{item.priceChangePercent == null ? '--' : `${item.priceChangePercent >= 0 ? '+' : ''}${item.priceChangePercent.toFixed(2)}`}</td><td><span className={item.eligible ? 'risk-clear' : 'risk-reason'}>{item.eligible ? '待提交门禁核验' : item.exclusionReasons.join('；') || item.exclusionCodes.join(', ') || '不符合纯 FBM 条件'}</span></td></tr>)}</tbody></table></div>
                {itemPageCount > 1 ? <div className="pagination pricing-pagination" aria-label="SKU 差异分页"><span>第 {currentItemPage} / {itemPageCount} 页 · 共 {run.items.length} 条</span><div><button type="button" aria-label="上一页" title="上一页" disabled={currentItemPage <= 1} onClick={() => setItemPage((page) => Math.max(1, page - 1))}><ChevronLeft aria-hidden="true" /></button><button type="button" aria-label="下一页" title="下一页" disabled={currentItemPage >= itemPageCount} onClick={() => setItemPage((page) => Math.min(itemPageCount, page + 1))}><ChevronRight aria-hidden="true" /></button></div></div> : null}
              </> : <div className="stage-empty"><FileCheck2 aria-hidden="true" /><strong>尚未生成差异</strong><span>返回调价规则创建预览。</span></div>}
              {actionError ? <div className="pricing-alert is-danger" role="alert"><CircleAlert aria-hidden="true" /><div><strong>变更集创建失败</strong><span>{actionError}</span></div></div> : null}
              <div className="stage-footer"><span>企业价保持不变；仅候选 SKU 会进入变更集。</span><button className="primary-action" type="button" disabled={!run || Boolean(changeSet) || !changeSetReady || run.summary.eligible === 0 || action === 'change-set'} onClick={() => void createChangeSet()}>{action === 'change-set' ? <LoaderCircle className="is-spinning" aria-hidden="true" /> : <ShieldCheck aria-hidden="true" />}创建待复核变更集</button></div>
            </div>
          ) : null}

          {activeStep === 4 ? (
            <div className="stage-layout">
              <div className="stage-copy"><span className="stage-number">05</span><div><h2>记录异人复核后进入生产校验</h2><p>当前姓名仅为未认证标签，不构成正式双人审批；真实身份/RBAC 接入前生产写入保持锁定。</p></div></div>
              <div className="approval-layout">
                <div className="approval-identity"><div><span>发起人标签</span><strong>{run?.initiatedBy || '--'}</strong></div><ArrowRight aria-hidden="true" /><label><span>复核人标签</span><input value={approver} onChange={(event) => setApprover(event.target.value)} placeholder="必须与发起人标签不同" /></label>{identityConflict ? <small role="alert">复核人标签不能与发起人相同</small> : null}</div>
                <fieldset className="approval-checks"><legend>人工复核确认</legend>
                  <label><input type="checkbox" checked={confirmations.sellerMarketplace} onChange={(event) => setConfirmations((current) => ({ ...current, sellerMarketplace: event.target.checked }))} /><span><strong>店铺与站点正确</strong><small>{runContext?.sellerName} · {runContext?.marketplaceName}</small></span></label>
                  <label><input type="checkbox" checked={confirmations.ruleVersion} onChange={(event) => setConfirmations((current) => ({ ...current, ruleVersion: event.target.checked }))} /><span><strong>规则版本已锁定</strong><small>{run ? `${run.rule.name} · v${run.rule.version}` : '--'}</small></span></label>
                  <label><input type="checkbox" checked={confirmations.anomaliesReviewed} onChange={(event) => setConfirmations((current) => ({ ...current, anomaliesReviewed: event.target.checked }))} /><span><strong>差异与异常已逐项审核</strong><small>{run?.summary.eligible ?? 0} 条候选，{run?.summary.excluded ?? 0} 条排除</small></span></label>
                  <label><input type="checkbox" checked={confirmations.amazonAcceptance} onChange={(event) => setConfirmations((current) => ({ ...current, amazonAcceptance: event.target.checked }))} /><span><strong>理解 Amazon 接收不等于生效</strong><small>最终成功以回读目标价一致为准</small></span></label>
                </fieldset>
              </div>
              {actionError ? <div className="pricing-alert is-danger" role="alert"><CircleAlert aria-hidden="true" /><div><strong>复核未完成</strong><span>{actionError}</span></div></div> : null}
              <div className="stage-footer"><span>变更集 {changeSet?.id ? changeSet.id.slice(0, 12) : '--'} · {changeSet?.itemCount ?? 0} 个 SKU</span><button className="primary-action" type="button" disabled={!changeSet || reviewRecorded || !approver.trim() || identityConflict || !allConfirmed || action === 'approve'} onClick={() => void approveChangeSet()}>{action === 'approve' ? <LoaderCircle className="is-spinning" aria-hidden="true" /> : <BadgeCheck aria-hidden="true" />}记录复核并进入校验</button></div>
            </div>
          ) : null}

          {activeStep === 5 ? (
            <div className="stage-layout is-verification">
              <div className="stage-copy"><span className="stage-number">06</span><div><h2>验证 Amazon 最终结果</h2><p>当前报告快照不是实时价格；提交前最新价尚未核验。接口接收、处理完成与价格回读是三个独立状态，只有回读一致才算成功。</p></div></div>
              <div className={`verification-state is-${validation.kind}`} role="status" aria-live="polite" aria-atomic="true">
                {validation.kind === 'running' ? <LoaderCircle className="is-spinning" aria-hidden="true" /> : validation.kind === 'passed' ? <CircleCheck aria-hidden="true" /> : validation.kind === 'blocked' ? <CircleAlert aria-hidden="true" /> : <LockKeyhole aria-hidden="true" />}
                <div><span>{validation.code || 'PRODUCTION VALIDATION'}</span><h3>{validation.title}</h3><p>{validation.detail}</p></div>
              </div>
              <div className="verification-timeline" aria-label="生产结果阶段"><div className={changeSet ? 'is-reached' : ''}><span>1</span><strong>复核记录</strong><small>{reviewRecorded ? '已记录' : '等待'}</small></div><div className={reviewRecorded ? 'is-reached' : ''}><span>2</span><strong>生产校验</strong><small>{validation.kind === 'idle' ? '等待' : validation.kind === 'passed' ? '通过' : validation.kind === 'blocked' ? '已阻止' : '执行中'}</small></div><div><span>3</span><strong>Amazon 接收</strong><small>尚未提交</small></div><div><span>4</span><strong>价格回读</strong><small>尚未核验</small></div></div>
              <div className="stage-footer"><span>当前页面不会把复核标签、阻断或接口接收显示为调价成功。</span><button className="primary-action" type="button" disabled={!reviewRecorded || validation.kind === 'running'} onClick={() => void validateChangeSet()}><ShieldCheck aria-hidden="true" />执行生产校验</button></div>
            </div>
          ) : null}
        </section>
      </main>
    </div>
  )
}
