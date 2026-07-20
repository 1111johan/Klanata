(() => {
  'use strict';

  const state = {
    view: 'workspace',
    server: null,
    analysis: null,
    auth: null,
    authSessions: [],
    account: null,
    pricingDirection: 'UP',
    pricingFile: null,
    pricingResult: null,
    pricingBatch: null,
    jobs: [],
    selectedJobId: null,
    pollTimer: null,
    pollJobId: null,
    pollInFlight: false,
    pollFailures: 0,
    defaultAutoLoaded: false,
    expandedWorkflowStep: null,
    analysisDetailsOpen: false,
    accountValidationRequest: 0,
    pricingPreset: 'standard'
  };

  const workflowOrder = ['file', 'account', 'submit'];

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
  const numberFormatter = new Intl.NumberFormat('zh-CN');
  const dateFormatter = new Intl.DateTimeFormat('zh-CN', {
    month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false
  });

  const pageMeta = {
    workspace: ['商品上传', '', 'AMAZON OPERATIONS'],
    pricing: ['管理员应急调价模拟', '历史文件只读筛选与差异预览，生产写入由 V4 API 原生流程执行', 'LEGACY READ-ONLY'],
    jobs: ['任务记录', 'Feed 处理状态与报告', 'FEED ACTIVITY'],
    settings: ['设置', 'Amazon 连接与运行状态', 'WORKSTATION SETTINGS']
  };
  const validViews = new Set(Object.keys(pageMeta));

  function viewFromHash() {
    const value = window.location.hash.slice(1).split(/[?&]/, 1)[0].toLowerCase();
    if (value === 'system') return 'settings';
    return validViews.has(value) ? value : 'workspace';
  }

  function oauthReasonMessage(reason) {
    const messages = {
      access_denied: 'Amazon 未授予访问权限，请确认登录的是目标店铺后重试',
      authorization_denied: 'Amazon 未授予访问权限，请确认登录的是目标店铺后重试',
      application_not_configured: '开发者应用尚未配置，请管理员完成应用设置',
      authorization_response_invalid: 'Amazon 返回的授权信息不完整，请重新发起授权',
      callback_failed: '授权回调未完成，请重新发起授权',
      expired_state: '授权请求已过期，请重新发起授权',
      invalid_request: 'Amazon 返回的授权请求无效，请重新发起授权',
      invalid_state: '授权校验未通过，请从本工作站重新发起授权',
      marketplace_discovery_failed: '店铺已授权，但站点发现失败，请重新授权或检查店铺状态',
      missing_state: '授权会话信息缺失，请从本工作站重新发起授权',
      missing_parameters: 'Amazon 返回的授权信息不完整，请重新发起授权',
      server_configuration: '服务器上的开发者应用配置不完整，请管理员检查设置',
      store_not_allowed: '登录的 Amazon 店铺不是 Carkee，本次授权未保存；请切换到 Carkee 后重试',
      storage_unavailable: '店铺已授权，但安全存储暂不可用，请管理员检查服务器配置',
      token_exchange_failed: '授权信息换取失败，请重新发起授权'
    };
    return messages[String(reason || '').toLowerCase()] || 'Amazon 授权未完成，请重新发起授权';
  }

  function consumeOAuthReturn() {
    const currentUrl = new URL(window.location.href);
    const rawHash = currentUrl.hash.slice(1);
    const hashQuestion = rawHash.indexOf('?');
    const hashRoute = (hashQuestion >= 0 ? rawHash.slice(0, hashQuestion) : rawHash).split('&', 1)[0];
    const hashQuery = hashQuestion >= 0 ? rawHash.slice(hashQuestion + 1) : '';
    const hashParams = new URLSearchParams(hashQuery);
    const marker = hashParams.get('amazon') || hashParams.get('amazon_oauth') ||
      currentUrl.searchParams.get('amazon') || currentUrl.searchParams.get('amazon_oauth');
    if (!marker) return null;

    const reason = hashParams.get('reason') || currentUrl.searchParams.get('reason') || '';
    const success = ['connected', 'success', 'authorized', 'ok'].includes(marker.toLowerCase());
    const sensitiveKeys = [
      'amazon', 'amazon_oauth', 'reason', 'code', 'spapi_oauth_code',
      'selling_partner_id', 'state', 'error', 'error_description'
    ];
    sensitiveKeys.forEach(key => currentUrl.searchParams.delete(key));
    const cleanRoute = validViews.has(hashRoute.toLowerCase()) ? hashRoute.toLowerCase() : 'settings';
    currentUrl.hash = `#${cleanRoute}`;
    const cleanSearch = currentUrl.searchParams.toString();
    window.history.replaceState(null, '', `${currentUrl.pathname}${cleanSearch ? `?${cleanSearch}` : ''}${currentUrl.hash}`);
    return { success, reason };
  }

  function escapeHtml(value) {
    return String(value ?? '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#039;');
  }

  function formatNumber(value) {
    return numberFormatter.format(Number(value || 0));
  }

  function formatDate(value) {
    if (!value) return '—';
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? String(value) : dateFormatter.format(date);
  }

  function regionLabel(region) {
    return ({ na: '北美', eu: '欧洲', fe: '远东' }[String(region || '').toLowerCase()] || String(region || '').toUpperCase());
  }

  function regionEndpoint(region) {
    return ({
      na: 'sellingpartnerapi-na.amazon.com',
      eu: 'sellingpartnerapi-eu.amazon.com',
      fe: 'sellingpartnerapi-fe.amazon.com',
    }[String(region || '').toLowerCase()] || '');
  }

  function isSelectableMarketplace(item) {
    const name = String(item?.name || '');
    return Boolean(item?.isParticipating) && !item?.hasSuspendedListings &&
      !/^Non-Amazon\b/i.test(name) && !/Shadow Marketplace/i.test(name);
  }

  function allowedAmazonStoreName() {
    return String(state.server?.allowedAmazonStoreName || 'Carkee').trim() || 'Carkee';
  }

  function isAllowedAuthSession(session) {
    return Boolean(session?.storeAllowed);
  }

  function allowedAuthSessions() {
    return state.authSessions.filter(isAllowedAuthSession);
  }

  function operationalAuthSessions() {
    return allowedAuthSessions().filter(session => Boolean(String(session?.sellerId || '').trim()));
  }

  function verifiedSessionStoreName(session) {
    return String(session?.verifiedStoreName || allowedAmazonStoreName()).trim() || allowedAmazonStoreName();
  }

  function submissionRisk() {
    const summary = state.analysis?.summary;
    if (!summary) return { high: false, rows: 0, zeroQuantity: 0, zeroRate: 0, phrase: 'SUBMIT' };
    const rows = Number(summary.rows || 0);
    const zeroQuantity = Number(summary.zeroQuantity || 0);
    const zeroRate = rows > 0 ? zeroQuantity / rows : 0;
    const high = rows >= 1000 || zeroRate >= 0.5;
    const strict = state.server?.submissionConfirmation === 'risk-based-row-count';
    return { high, rows, zeroQuantity, zeroRate, phrase: strict && high ? `SUBMIT ${rows}` : 'SUBMIT' };
  }

  async function api(path, options = {}) {
    const response = await fetch(path, {
      headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
      ...options
    });
    const contentType = response.headers.get('content-type') || '';
    const body = contentType.includes('application/json') ? await response.json() : await response.text();
    if (!response.ok) {
      const message = body?.error?.message || body?.message || body || `HTTP ${response.status}`;
      throw new Error(message);
    }
    return body;
  }

  function toast(title, message, type = '') {
    const item = document.createElement('div');
    item.className = `toast ${type ? `is-${type}` : ''}`;
    item.innerHTML = `<strong>${escapeHtml(title)}</strong><span>${escapeHtml(message)}</span>`;
    $('#toast-stack').append(item);
    window.setTimeout(() => item.remove(), 5200);
  }

  function setLoading(button, loading, label) {
    if (!button.dataset.originalHtml) button.dataset.originalHtml = button.innerHTML;
    button.disabled = loading;
    button.setAttribute('aria-busy', String(loading));
    const loadingLabel = `${String(label || '处理中').replace(/[.…]+$/, '')}…`;
    button.innerHTML = loading
      ? `<span class="button-spinner" aria-hidden="true"></span>${escapeHtml(loadingLabel)}`
      : button.dataset.originalHtml;
    refreshIcons();
  }

  function refreshIcons() {
    if (window.lucide) window.lucide.createIcons({ attrs: { width: 16, height: 16, 'stroke-width': 1.8 } });
  }

  function mountSettingsAuth() {
    const panel = $('#flow-panel-auth');
    const slot = $('#settings-auth-slot');
    if (!panel || !slot || panel.parentElement === slot) return;
    slot.append(panel);
    panel.classList.remove('flow-panel', 'is-expanded', 'is-current', 'is-complete', 'is-locked');
    panel.classList.add('no-top-border', 'settings-auth-section');
    panel.removeAttribute('data-flow-panel');
    panel.removeAttribute('aria-disabled');
    $('[data-flow-toggle="auth"]', panel)?.remove();
  }

  function setView(view, syncHash = true) {
    if (!validViews.has(view)) view = 'workspace';
    if (view === 'pricing' && state.server && !state.server.legacyPricingSimulationAvailable) view = 'workspace';
    state.view = view;
    $$('.view').forEach(node => node.classList.toggle('is-visible', node.dataset.view === view));
    $$('.nav-item').forEach(button => {
      const active = button.dataset.viewTarget === view;
      button.classList.toggle('is-active', active);
      if (active) button.setAttribute('aria-current', 'page');
      else button.removeAttribute('aria-current');
    });
    $('#page-title').textContent = pageMeta[view][0];
    const subtitle = pageMeta[view][1];
    $('#page-subtitle').textContent = subtitle;
    $('#page-subtitle').classList.toggle('is-hidden', !subtitle);
    $('#page-kicker').textContent = pageMeta[view][2];
    document.title = `${pageMeta[view][0]} · Klanata`;
    if (syncHash && window.location.hash !== `#${view}`) {
      window.history.replaceState(null, '', `#${view}`);
    }
    updateHeaderTarget();
    if (view === 'pricing') {
      renderPricingMarketplaces();
      updatePricingButton();
    }
    if (view === 'jobs') loadJobs();
    if (view === 'settings') renderSystem();
  }

  function setSectionState(elementId, text, type = '') {
    const element = $(elementId);
    element.textContent = text;
    element.className = `section-state ${type ? `is-${type}` : ''}`;
  }

  function setWorkflowStep(step, status, detail) {
    const element = $(`[data-workflow-step="${step}"]`);
    if (!element) return;
    element.classList.remove('is-active', 'is-complete', 'is-error');
    if (status) element.classList.add(`is-${status}`);
    if (status === 'active') element.setAttribute('aria-current', 'step');
    else element.removeAttribute('aria-current');
    const target = $(`#step-${step}-status`);
    if (target && detail) target.textContent = detail;
  }

  function currentWorkflowStep() {
    if (!state.analysis) return 'file';
    if (!state.account) return 'account';
    return 'submit';
  }

  function setExpandedWorkflowStep(step, scroll = false) {
    const currentIndex = workflowOrder.indexOf(currentWorkflowStep());
    const targetIndex = workflowOrder.indexOf(step);
    if (targetIndex < 0 || targetIndex > currentIndex) return;
    state.expandedWorkflowStep = step;
    updateFlowPanels();
    if (scroll) {
      const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      $(`[data-flow-panel="${step}"]`)?.scrollIntoView({ behavior: reducedMotion ? 'auto' : 'smooth', block: 'start' });
    }
  }

  function toggleExpandedWorkflowStep(step) {
    if (state.expandedWorkflowStep === step) {
      state.expandedWorkflowStep = '';
      updateFlowPanels();
      return;
    }
    setExpandedWorkflowStep(step, true);
  }

  function updateFlowPanels() {
    const current = currentWorkflowStep();
    workflowOrder.forEach(step => {
      const panel = $(`[data-flow-panel="${step}"]`);
      const jump = $(`[data-flow-jump="${step}"]`);
      const toggle = $(`[data-flow-toggle="${step}"]`);
      if (!panel) return;

      panel.classList.add('is-expanded');
      panel.classList.toggle('is-current', step === current);
      panel.classList.toggle('is-complete', step !== current);
      panel.classList.remove('is-locked');
      panel.setAttribute('aria-disabled', 'false');

      if (jump) {
        jump.disabled = false;
        jump.setAttribute('aria-expanded', 'true');
        jump.setAttribute('aria-controls', panel.id);
        jump.setAttribute('aria-label', `${panel.querySelector('h2')?.textContent || '步骤'}：${$(`#step-${step}-status`)?.textContent || ''}`);
      }
      if (toggle) {
        toggle.disabled = true;
        toggle.setAttribute('aria-expanded', 'true');
      }
    });
  }

  function setAnalysisDetails(open) {
    state.analysisDetailsOpen = Boolean(open);
    const button = $('#analysis-toggle');
    $('#analysis-area').classList.toggle('is-hidden', !state.analysisDetailsOpen);
    button.setAttribute('aria-expanded', String(state.analysisDetailsOpen));
    button.innerHTML = `
      <i data-lucide="chart-no-axes-column-increasing" aria-hidden="true"></i>
      <span>${state.analysisDetailsOpen ? '收起数据详情' : '查看数据详情'}</span>
      <i data-lucide="chevron-${state.analysisDetailsOpen ? 'up' : 'down'}" aria-hidden="true"></i>`;
    refreshIcons();
  }

  function updateWorkflow() {
    if (state.analysis) setWorkflowStep('file', 'complete', `${formatNumber(state.analysis.summary.rows)} SKU`);
    else setWorkflowStep('file', 'active', '待载入');

    if (state.account) setWorkflowStep('account', 'complete', '已就绪');
    else setWorkflowStep('account', authorizedMarketplaces().length ? 'active' : '', '待选择');

    const activeJob = state.jobs.find(job => job.id === state.selectedJobId);
    if (activeJob) {
      if (activeJob.status === 'DONE') setWorkflowStep('submit', 'complete', '已完成');
      else if (['FATAL', 'CANCELLED', 'SUBMISSION_FAILED', 'SUBMISSION_UNKNOWN'].includes(activeJob.status)) setWorkflowStep('submit', 'error', activeJob.status);
      else setWorkflowStep('submit', 'active', activeJob.status);
    } else {
      setWorkflowStep('submit', state.account ? 'active' : '', '未提交');
    }
    updateFlowPanels();
  }

  async function loadServerStatus() {
    try {
      state.server = await api('/api/status');
      $('#legacy-pricing-nav').classList.toggle('is-hidden', !state.server.legacyPricingSimulationAvailable);
      if (state.view === 'pricing' && !state.server.legacyPricingSimulationAvailable) setView('workspace');
      $('#server-dot').className = 'status-dot is-success';
      $('#server-label').textContent = '服务正常';
      $('#load-default-button').disabled = !state.server.defaultFileAvailable;
      renderSystem();
      renderDeveloperApplication();
      updateReview();
      updatePricingProductionControls();
      updateSubmitButton();
    } catch (error) {
      $('#server-dot').className = 'status-dot is-danger';
      $('#server-label').textContent = '服务离线';
      $('#system-health').textContent = '离线';
      toast('本地服务不可用', error.message, 'danger');
    }
  }

  function renderSystem() {
    if (!state.server) return;
    $('#system-health').textContent = state.server.ok ? '正常' : '异常';
    $('#system-health').className = `section-state ${state.server.ok ? 'is-success' : 'is-danger'}`;
    $('#system-bind').textContent = state.server.bind;
    $('#system-bind-status').textContent = state.server.ok ? '运行中' : '离线';
    $('#system-credentials').textContent = state.server.credentialStorage;
    $('#system-default-file').textContent = state.server.defaultFileName || '未配置';
    $('#system-file-status').textContent = state.server.defaultFileAvailable ? '可用' : '缺失';
    $('#system-version').textContent = state.server.apiVersion;
  }

  function renderDeveloperApplication() {
    const app = state.server?.developerApplication || {};
    const configured = Boolean(app.configured);
    const oauthReady = Boolean(app.oauthReady);
    const canConfigure = Boolean(state.server?.adminConfigurationWritable);
    $('#admin-application-settings').hidden = !canConfigure;
    $('.legacy-auth-settings').hidden = !canConfigure;
    const strip = $('#developer-app-strip');
    if (!strip) return;
    strip.classList.toggle('is-ready', configured);
    $('#developer-app-status').textContent = oauthReady
      ? '已配置，可发起 OAuth 授权'
      : configured ? '凭证已保存，待补 Application ID' : '未配置，需要管理员录入';
    $('#developer-app-client').textContent = configured ? app.clientId || 'Client ID 已保存' : '等待配置';
    $('#developer-app-secret').textContent = configured ? '密钥已加密' : '未配置';
    $('#developer-app-secret').className = `status-badge ${configured ? 'is-success' : 'is-warning'}`;
    const applicationId = $('#application-id');
    const authorizationBaseUri = $('#authorization-base-uri');
    if (applicationId && !applicationId.value && app.applicationId &&
        !/[\u2026*]/.test(app.applicationId) && !String(app.applicationId).includes('...')) {
      applicationId.value = app.applicationId;
    }
    if (authorizationBaseUri && !authorizationBaseUri.value && app.authorizationBaseUri) {
      authorizationBaseUri.value = app.authorizationBaseUri;
    }
    $('#client-id').placeholder = configured ? '已配置，留空可保留原值' : 'amzn1.application-oa2-client...';
    $('#oauth-auth-button').classList.toggle('needs-configuration', !oauthReady);
    $('#oauth-auth-button').disabled = !oauthReady && !canConfigure;
  }

  async function saveDeveloperApplication() {
    const button = $('#save-application-button');
    const applicationId = $('#application-id').value.trim();
    const clientId = $('#client-id').value.trim();
    const clientSecret = $('#client-secret').value.trim();
    const authorizationBaseUri = $('#authorization-base-uri').value.trim();
    const configured = Boolean(state.server?.developerApplication?.configured);
    if (!applicationId) {
      toast('缺少 Application ID', '请填写 Amazon 开发者应用的 Application ID', 'danger');
      $('#application-id').focus();
      return;
    }
    if (!configured && (!clientId || !clientSecret)) {
      toast('应用凭证不完整', '首次配置需要填写 LWA Client ID 和 Client Secret', 'danger');
      (!clientId ? $('#client-id') : $('#client-secret')).focus();
      return;
    }

    setLoading(button, true, '正在保存');
    $('#application-result').className = 'inline-status is-warning';
    $('#application-result').innerHTML = '<span class="status-dot is-warning" aria-hidden="true"></span><span>正在加密并保存应用配置</span>';
    try {
      await api('/api/auth/application', {
        method: 'POST',
        body: JSON.stringify({ applicationId, clientId, clientSecret, authorizationBaseUri })
      });
      $('#client-id').value = '';
      $('#client-secret').value = '';
      await loadServerStatus();
      $('#application-result').className = 'inline-status is-success';
      $('#application-result').innerHTML = '<span class="status-dot is-success" aria-hidden="true"></span><span>应用配置已保存，可以发起 Carkee 授权</span>';
      toast('应用配置已保存', '现在可以连接 Carkee', 'success');
    } catch (error) {
      $('#application-result').className = 'inline-status is-danger';
      $('#application-result').innerHTML = `<span class="status-dot is-danger" aria-hidden="true"></span><span>${escapeHtml(error.message)}</span>`;
      toast('应用配置保存失败', error.message, 'danger');
    } finally {
      setLoading(button, false);
    }
  }

  async function startOAuthAuthorization() {
    const button = $('#oauth-auth-button');
    if (!state.server?.developerApplication?.oauthReady) {
      if (!state.server?.adminConfigurationWritable) {
        toast('等待管理员配置', '服务器管理员补充 Application ID 后即可重新授权', 'warning');
        return;
      }
      const settings = $('#admin-application-settings');
      settings.open = true;
      $('#application-id').focus({ preventScroll: true });
      settings.scrollIntoView({ behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth', block: 'start' });
      toast('先完成管理员应用配置', '配置一次后，运营人员只需点击授权按钮', 'warning');
      return;
    }

    setLoading(button, true, '正在前往 Amazon');
    try {
      const result = await api('/api/auth/oauth/start');
      const authorizationUrl = new URL(String(result.authorizationUrl || ''), window.location.origin);
      if (!['http:', 'https:'].includes(authorizationUrl.protocol)) throw new Error('Amazon 授权地址无效');
      window.location.assign(authorizationUrl.href);
    } catch (error) {
      setLoading(button, false);
      toast('无法发起 Amazon 授权', error.message, 'danger');
    }
  }

  async function analyzeDefault(silent = false) {
    const button = $('#load-default-button');
    setLoading(button, true, '正在校验');
    try {
      const result = await api('/api/analyze', {
        method: 'POST', body: JSON.stringify({ useDefault: true })
      });
      acceptAnalysis(result);
      if (!silent) toast('数据校验完成', `${formatNumber(result.summary.rows)} 个 SKU 可上传`, 'success');
    } catch (error) {
      setSectionState('#file-state', '校验失败', 'danger');
      setWorkflowStep('file', 'error', '校验失败');
      toast('文件校验失败', error.message, 'danger');
    } finally {
      setLoading(button, false);
    }
  }

  async function analyzeFile(file) {
    const button = $('#choose-file-button');
    setLoading(button, true, '正在读取');
    try {
      const spreadsheet = /\.(xlsx|xlsm)$/i.test(file.name);
      if (spreadsheet && file.size > 6 * 1024 * 1024) {
        throw new Error('Excel 模板不能超过 6 MB');
      }
      let payload;
      if (spreadsheet) {
        const dataUrl = await new Promise((resolve, reject) => {
          const reader = new FileReader();
          reader.addEventListener('load', () => resolve(reader.result), { once: true });
          reader.addEventListener('error', () => reject(reader.error || new Error('无法读取 Excel 文件')), { once: true });
          reader.readAsDataURL(file);
        });
        payload = {
          useDefault: false,
          fileName: file.name,
          contentBase64: String(dataUrl).split(',', 2)[1] || ''
        };
      } else {
        payload = { useDefault: false, fileName: file.name, content: await file.text() };
      }
      const result = await api('/api/analyze', {
        method: 'POST', body: JSON.stringify(payload)
      });
      acceptAnalysis(result);
      toast('数据校验完成', `${formatNumber(result.summary.rows)} 个 SKU 可上传`, 'success');
    } catch (error) {
      setSectionState('#file-state', '校验失败', 'danger');
      setWorkflowStep('file', 'error', '校验失败');
      toast('文件校验失败', error.message, 'danger');
    } finally {
      setLoading(button, false);
      $('#file-input').value = '';
    }
  }

  function acceptAnalysis(result) {
    state.analysis = result;
    $('#confirm-checkbox').checked = false;
    $('#confirmation-input').value = '';
    invalidateAccount(false);
    $('#drop-title').textContent = result.fileName;
    $('#drop-meta').textContent = `${formatNumber(result.summary.rows)} 行 · ${result.summary.columnCount} 列`;
    setSectionState('#file-state', '校验通过', 'success');
    $('#file-summary').innerHTML = `
      <dl class="file-facts">
        <div><dt>文件</dt><dd>${escapeHtml(result.fileName)}</dd></div>
        <div><dt>有效数据</dt><dd>${formatNumber(result.summary.rows)} 行</dd></div>
        <div><dt>唯一 SKU</dt><dd>${formatNumber(result.summary.uniqueSkus)}</dd></div>
        ${result.templateSellerId ? `<div><dt>文件 Seller</dt><dd>${escapeHtml(result.templateSellerId)}</dd></div>` : ''}
        ${result.templateMarketplaceId ? `<div><dt>文件站点</dt><dd>${escapeHtml(result.templateMarketplaceId)}</dd></div>` : ''}
        <div><dt>示例行</dt><dd>已跳过 ${formatNumber(result.summary.skippedExampleRows)}</dd></div>
        <div><dt>有效字段</dt><dd>${result.nonEmptyColumns.map(item => escapeHtml(item.label)).join(' / ')}</dd></div>
      </dl>`;
    $('#analysis-toggle').classList.remove('is-hidden');
    setAnalysisDetails(false);
    $('#metric-skus').textContent = formatNumber(result.summary.uniqueSkus);
    $('#metric-columns').textContent = `${result.summary.columnCount} 列模板`;
    $('#metric-zero').textContent = formatNumber(result.summary.zeroQuantity);
    $('#metric-zero-rate').textContent = `${(result.summary.zeroQuantity / result.summary.rows * 100).toFixed(1)}%`;
    $('#metric-positive').textContent = formatNumber(result.summary.positiveQuantity);
    $('#metric-range').textContent = `${formatNumber(result.summary.minQuantity)}–${formatNumber(result.summary.maxQuantity)}`;
    $('#metric-total').textContent = formatNumber(result.summary.totalQuantity);
    $('#distribution-total').textContent = `${formatNumber(result.summary.rows)} SKU`;
    renderDistribution(result.distribution);
    renderPreview(result.preview);
    renderMarketplaces();
    updateReview();
    updateWorkflow();
    updateAccountButton();
    void prepareSelectedTarget();
  }

  function renderDistribution(items) {
    const max = Math.max(...items.map(item => item.count), 1);
    $('#distribution-chart').innerHTML = items.map(item => {
      const height = Math.max(2, Math.round(item.count / max * 100));
      return `<div class="bar-column ${item.key === 'zero' ? 'is-zero' : ''}">
        <span class="bar-value">${formatNumber(item.count)}</span>
        <div class="bar-track"><div class="bar-fill" style="height:${height}%"></div></div>
        <span class="bar-label">${escapeHtml(item.label)}</span>
      </div>`;
    }).join('');
  }

  function renderPreview(rows) {
    $('#preview-count').textContent = `前 ${rows.length} 行`;
    $('#preview-body').innerHTML = rows.map(row => `<tr>
      <td>${formatNumber(row.row)}</td>
      <td><code>${escapeHtml(row.sku)}</code></td>
      <td>${escapeHtml(row.channel)}</td>
      <td class="align-right">${formatNumber(row.quantity)}</td>
    </tr>`).join('');
  }

  async function verifyAuth() {
    const button = $('#verify-auth-button');
    const refreshToken = $('#refresh-token').value.trim();
    const sellerId = $('#auth-seller-id').value.trim().toUpperCase();
    const appConfigured = Boolean(state.server?.developerApplication?.configured);
    if (!sellerId) {
      toast('缺少 Seller ID', '请填写这个 Refresh Token 对应店铺的 Seller ID', 'danger');
      return;
    }
    if (!refreshToken) {
      toast('缺少授权账户', '请填写卖家授权账户的 Refresh Token', 'danger');
      return;
    }
    if (!appConfigured) {
      toast('开发者应用未配置', '请管理员先保存 Amazon 开发者应用配置', 'danger');
      return;
    }

    setLoading(button, true, '正在迁移');
    $('#legacy-auth-result').className = 'inline-status is-warning';
    $('#legacy-auth-result').innerHTML = '<span class="status-dot is-warning" aria-hidden="true"></span><span>正在验证旧授权并发现可用站点</span>';
    try {
      const payload = { refreshToken, sellerId };
      const result = await api('/api/auth/verify', {
        method: 'POST', body: JSON.stringify(payload)
      });
      await loadServerStatus();
      const current = await api('/api/workflow/current');
      state.authSessions = Array.isArray(current.authSessions) && current.authSessions.length
        ? current.authSessions
        : [result];
      const preferredMarketplaceId = selectedMarketplace()?.id || state.account?.marketplaceId || '';
      if (state.account && !accountAuthorizationIds().includes(result.authSessionId)) {
        invalidateAccount(false);
        setSectionState('#account-state', '需要重新验证', 'warning');
        $('#account-result').innerHTML = '<div class="inline-status is-warning" style="padding-top:14px"><span class="status-dot is-warning"></span><span>新授权尚未应用到当前目标，请重新选择 Carkee 站点</span></div>';
      }
      renderAuthorizationSummary();
      renderMarketplaces(preferredMarketplaceId);
      $('#auth-seller-id').value = '';
      $('#refresh-token').value = '';
      $('#legacy-auth-result').className = 'inline-status is-success';
      $('#legacy-auth-result').innerHTML = '<span class="status-dot is-success" aria-hidden="true"></span><span>旧授权已迁移并保存</span>';
      toast('旧授权迁移完成', `${result.verifiedStoreName || allowedAmazonStoreName()} · ${result.marketplaces?.length || 0} 个站点`, 'success');
      updateWorkflow();
      updateReview();
      updateAccountButton();
      renderJobDetail();
      void prepareSelectedTarget();
    } catch (error) {
      $('#legacy-auth-result').className = 'inline-status is-danger';
      $('#legacy-auth-result').innerHTML = `<span class="status-dot is-danger" aria-hidden="true"></span><span>${escapeHtml(error.message)}</span>`;
      toast('旧授权迁移失败', error.message, 'danger');
      updateWorkflow();
    } finally {
      setLoading(button, false);
    }
  }

  function authorizedMarketplaces() {
    const groups = new Map();
    [...operationalAuthSessions()].reverse().forEach(session => {
      const verifiedStoreName = verifiedSessionStoreName(session);
      (Array.isArray(session.marketplaces) ? session.marketplaces : []).filter(isSelectableMarketplace).forEach(item => {
        const sellerId = String(session.sellerId || '').trim().toUpperCase();
        const key = `${sellerId}:${session.region}:${item.id}`;
        if (!groups.has(key)) {
          groups.set(key, {
            ...item,
            storeName: verifiedStoreName,
            authSessionId: session.authSessionId,
            authSessionIds: [],
            sellerId,
            region: session.region,
          });
        }
        const group = groups.get(key);
        if (!group.authSessionIds.includes(session.authSessionId)) {
          group.authSessionIds.push(session.authSessionId);
        }
      });
    });
    return [...groups.values()];
  }

  function syncSelectedAuth() {
    const marketplace = selectedMarketplace();
    state.auth = marketplace
      ? operationalAuthSessions().find(session => session.authSessionId === marketplace.authSessionId) || null
      : null;
    $('#seller-id').value = marketplace?.sellerId || state.auth?.sellerId || '';
    return state.auth;
  }

  function marketplaceContextValue(item) {
    return `${item.sellerId || 'unbound'}::${item.id}`;
  }

  function maskSellerId(value) {
    const sellerId = String(value || '');
    if (sellerId.length <= 8) return sellerId || '未绑定';
    return `${sellerId.slice(0, 4)}…${sellerId.slice(-4)}`;
  }

  function renderAuthorizationSummary() {
    const application = state.server?.developerApplication || {};
    const storeName = allowedAmazonStoreName();
    const sessions = allowedAuthSessions();
    const oauthButtonLabel = application.oauthReady
      ? (sessions.length ? `重新授权 ${storeName}` : `连接 ${storeName}`)
      : (state.server?.adminConfigurationWritable
          ? (application.configured ? '补充 Application ID' : '配置 Amazon 应用')
          : '等待管理员配置');
    if (!sessions.length) {
      setSectionState('#auth-state', '未连接');
      $('#oauth-connect-title').textContent = `尚未连接 ${storeName}`;
      $('#oauth-connect-detail').textContent = `登录 Amazon 并确认 ${storeName} 授权，可销售站点会自动绑定`;
      $('#oauth-auth-button-label').textContent = oauthButtonLabel;
      $('#auth-result').className = 'inline-status settings-auth-result';
      $('#auth-result').innerHTML = `<span class="status-dot" aria-hidden="true"></span><span>${escapeHtml(storeName)} 授权可供商品上传和智能调价共同使用</span>`;
      $('#authorized-accounts').innerHTML = '';
      renderPricingMarketplaces();
      refreshIcons();
      return;
    }

    const accounts = new Map();
    sessions.forEach(session => {
      const sellerId = String(session.sellerId || '').trim();
      const key = sellerId || session.authSessionId;
      if (!accounts.has(key)) {
        accounts.set(key, {
          sellerId,
          verifiedStoreName: verifiedSessionStoreName(session),
          sessionIds: [],
          regions: new Set(),
          endpoints: new Set(),
          storeNames: new Set(),
          marketplaces: new Map(),
        });
      }
      const account = accounts.get(key);
      account.sessionIds.push(session.authSessionId);
      account.regions.add(regionLabel(session.region));
      account.endpoints.add(regionEndpoint(session.region));
      (Array.isArray(session.marketplaces) ? session.marketplaces : []).filter(isSelectableMarketplace).forEach(item => {
        account.storeNames.add(account.verifiedStoreName);
        account.marketplaces.set(item.id, item);
      });
    });
    const accountList = [...accounts.values()];
    const marketplaceCount = authorizedMarketplaces().length;
    const pendingCount = accountList.filter(account => !account.sellerId).length;
    setSectionState('#auth-state', `${storeName} · ${sessions.length} 个授权`, marketplaceCount ? 'success' : 'warning');
    $('#oauth-connect-title').textContent = marketplaceCount ? `${storeName} 已连接` : `${storeName} 授权待绑定`;
    $('#oauth-connect-detail').textContent = `${marketplaceCount} 个可用站点${pendingCount ? ` · ${pendingCount} 个授权待绑定` : ''}`;
    $('#oauth-auth-button-label').textContent = oauthButtonLabel;
    $('#auth-result').className = `inline-status settings-auth-result ${marketplaceCount ? 'is-success' : 'is-warning'}`;
    $('#auth-result').innerHTML = `<span class="status-dot ${marketplaceCount ? 'is-success' : 'is-warning'}" aria-hidden="true"></span><span>${escapeHtml(storeName)} · ${formatNumber(marketplaceCount)} 个可用站点 · ${formatNumber(sessions.length)} 个授权${pendingCount ? ` · ${formatNumber(pendingCount)} 个待绑定` : ''}</span>`;
    $('#authorized-accounts').innerHTML = accountList.map(account => {
      const selectable = [...account.marketplaces.values()];
      const groupedCountries = selectable.map(item => item.countryCode).join('、') || '无可选站点';
      const accountStoreName = account.verifiedStoreName || storeName;
      const bindingStatus = account.sellerId
        ? `Seller ${escapeHtml(maskSellerId(account.sellerId))} · 已连接 · ${formatNumber(account.sessionIds.length)} 个授权`
        : `待绑定 Seller ID · ${formatNumber(account.sessionIds.length)} 个授权`;
      return `<article class="authorized-account">
        <div class="authorized-account-main">
          <span class="authorized-account-icon" aria-hidden="true"><i data-lucide="badge-check"></i></span>
          <div>
            <h3>${escapeHtml(accountStoreName)}</h3>
            <code>${bindingStatus}</code>
          </div>
        </div>
        <div class="authorized-sites" aria-label="已连接站点">
          ${selectable.map(item => `<span class="site-chip" title="${escapeHtml(item.name)}"><strong>${escapeHtml(item.countryCode)}</strong><span>${escapeHtml(item.name)}</span></span>`).join('') || `<span class="site-chip"><strong>—</strong><span>无可选站点</span></span>`}
        </div>
        <small>已发现站点：${escapeHtml(groupedCountries)}</small>
      </article>`;
    }).join('');
    renderPricingMarketplaces();
    refreshIcons();
  }

  function renderMarketplaces(preferredMarketplaceId = '') {
    const select = $('#marketplace-select');
    const active = authorizedMarketplaces();
    const currentValue = select.value;
    if (!active.length) {
      select.innerHTML = '<option value="">先到设置连接 Carkee</option>';
      select.disabled = true;
      state.auth = null;
      $('#seller-id').value = '';
      updateHeaderTarget();
      return;
    }
    select.innerHTML = '<option value="">选择 Carkee 站点</option>' + active.map(item =>
      `<option value="${escapeHtml(marketplaceContextValue(item))}">${escapeHtml(item.storeName || allowedAmazonStoreName())} · ${escapeHtml(item.countryCode)} · ${escapeHtml(item.name || 'Amazon 站点')}</option>`
    ).join('');

    const templateMatches = state.analysis?.templateMarketplaceId
      ? active.filter(item => item.id === state.analysis.templateMarketplaceId &&
          (!state.analysis.templateSellerId || item.sellerId === state.analysis.templateSellerId))
      : [];
    const current = active.find(item => marketplaceContextValue(item) === currentValue);
    const preferred = active.filter(item => item.id === preferredMarketplaceId);
    if (templateMatches.length === 1) select.value = marketplaceContextValue(templateMatches[0]);
    else if (state.analysis?.templateMarketplaceId) select.value = '';
    else if (current) select.value = marketplaceContextValue(current);
    else if (preferred.length === 1) select.value = marketplaceContextValue(preferred[0]);
    else if (active.length === 1) select.value = marketplaceContextValue(active[0]);
    select.disabled = false;
    syncSelectedAuth();
    updateHeaderTarget();
  }

  async function restoreWorkflow() {
    try {
      const current = await api('/api/workflow/current');
      const restoredSessions = Array.isArray(current.authSessions) && current.authSessions.length
        ? current.authSessions
        : current.auth ? [current.auth] : [];
      state.authSessions = restoredSessions;
      renderAuthorizationSummary();
      renderMarketplaces();
      $('#client-id').value = '';
      $('#client-secret').value = '';
      $('#auth-seller-id').value = '';
      $('#refresh-token').value = '';
      updateAccountButton();
      updateWorkflow();
      updateReview();
      renderPricingMarketplaces();
      updatePricingButton();
      updateSubmitButton();
      renderJobDetail();
      refreshIcons();
      return Boolean(authorizedMarketplaces().length);
    } catch (error) {
      toast('工作流恢复失败', error.message, 'danger');
      return false;
    }
  }

  function updateAccountButton() {
    syncSelectedAuth();
    const marketplace = selectedMarketplace();
    const button = $('#validate-account-button');
    if (button) button.disabled = !(state.analysis && state.auth && marketplace?.sellerId && !getTargetMismatch(marketplace));
  }

  function invalidateAccount(update = true) {
    state.accountValidationRequest++;
    state.account = null;
    $('#confirm-checkbox').checked = false;
    $('#confirmation-input').value = '';
    setSectionState('#account-state', '待检查');
    $('#account-result').innerHTML = '<div class="empty-state compact"><i data-lucide="link-2" aria-hidden="true"></i><span>选择店铺与文件后自动检查</span></div>';
    if (update) {
      updateWorkflow();
      updateReview();
      updatePricingButton();
      updateSubmitButton();
    }
    refreshIcons();
  }

  function getTargetMismatch(marketplace = selectedMarketplace()) {
    if (!state.analysis || !marketplace) return '';
    if (state.analysis.templateSellerId && state.analysis.templateSellerId !== marketplace.sellerId) {
      return '文件所属 Seller 与当前店铺不同';
    }
    if (state.analysis.templateMarketplaceId && state.analysis.templateMarketplaceId !== marketplace.id) {
      return '文件所属站点与当前目标站点不同';
    }
    return '';
  }

  function renderTargetMismatch(marketplace, reason) {
    const fileSeller = state.analysis?.templateSellerId || '文件未声明';
    const fileMarketplace = state.analysis?.templateMarketplaceId || '文件未声明';
    $('#account-result').innerHTML = `
      <div class="target-mismatch" role="alert">
        <div><span>文件归属</span><strong>${escapeHtml(fileSeller)}</strong><small>${escapeHtml(fileMarketplace)}</small></div>
        <i data-lucide="arrow-right-left" aria-hidden="true"></i>
        <div><span>当前目标</span><strong>${escapeHtml(marketplace?.sellerId || '未选择')}</strong><small>${escapeHtml(marketplace?.id || '未选择')}</small></div>
      </div>
      <div class="inline-status is-danger target-mismatch-message"><span class="status-dot is-danger"></span><span>${escapeHtml(reason)}。请选择该店铺导出的文件，系统不会跨店上传。</span></div>`;
    refreshIcons();
  }

  async function prepareSelectedTarget() {
    const marketplace = selectedMarketplace();
    invalidateAccount(false);
    syncSelectedAuth();
    if (!authorizedMarketplaces().length) {
      setSectionState('#account-state', '未连接', 'warning');
      $('#account-result').innerHTML = '<div class="inline-status is-warning target-guidance"><span class="status-dot is-warning"></span><span>请先到设置连接并绑定 Carkee。</span></div>';
      refreshIcons();
      return;
    }
    if (!marketplace) {
      setSectionState('#account-state', state.analysis ? '无匹配目标' : '请选择', 'warning');
      const owner = state.analysis?.templateSellerId
        ? `文件内的店铺标识为 ${escapeHtml(state.analysis.templateSellerId)} · ${escapeHtml(state.analysis.templateMarketplaceId || '未知站点')}，当前授权中没有找到唯一匹配。`
        : '请选择本次操作的 Carkee 站点。';
      $('#account-result').innerHTML = `<div class="inline-status is-warning target-guidance"><span class="status-dot is-warning"></span><span>${owner}</span></div>`;
      refreshIcons();
      return;
    }
    if (!marketplace.sellerId) {
      setSectionState('#account-state', '授权信息不完整', 'danger');
      $('#account-result').innerHTML = '<div class="inline-status is-danger target-guidance"><span class="status-dot is-danger"></span><span>Carkee 授权信息不完整，请在设置中重新授权。</span></div>';
      refreshIcons();
      return;
    }
    if (!state.analysis) {
      setSectionState('#account-state', '目标已选', 'success');
      $('#account-result').innerHTML = `<div class="target-ready"><i data-lucide="store" aria-hidden="true"></i><span><strong>${escapeHtml(marketplace.storeName || allowedAmazonStoreName())} · ${escapeHtml(marketplace.countryCode)}</strong><small>授权已自动绑定 · 等待选择文件</small></span></div>`;
      refreshIcons();
      return;
    }
    const mismatch = getTargetMismatch(marketplace);
    if (mismatch) {
      setSectionState('#account-state', '文件不匹配', 'danger');
      renderTargetMismatch(marketplace, mismatch);
      updateReview();
      updateSubmitButton();
      return;
    }
    await validateAccount({ automatic: true });
  }

  async function validateAccount({ automatic = false } = {}) {
    syncSelectedAuth();
    if (!state.analysis || !state.auth) return;
    const button = $('#validate-account-button');
    const sellerId = $('#seller-id').value.trim();
    const marketplace = selectedMarketplace();
    const marketplaceId = marketplace?.id || '';
    const mismatch = getTargetMismatch(marketplace);
    if (mismatch) {
      setSectionState('#account-state', '文件不匹配', 'danger');
      renderTargetMismatch(marketplace, mismatch);
      return;
    }
    const requestId = ++state.accountValidationRequest;
    if (button) setLoading(button, true, '验证中');
    setSectionState('#account-state', '自动检查中', 'warning');
    try {
      const result = await api('/api/account/validate', {
        method: 'POST',
        body: JSON.stringify({
          authSessionId: state.auth.authSessionId,
          authSessionIds: selectedMarketplace()?.authSessionIds || [state.auth.authSessionId],
          analysisId: state.analysis.analysisId,
          sellerId,
          marketplaceId
        })
      });
      if (requestId !== state.accountValidationRequest) return;
      state.account = { ...result, marketplace, sellerId, marketplaceId };
      setSectionState('#account-state', '匹配通过', 'success');
      $('#account-result').innerHTML = `
        <div class="account-match">
          <div><span>店铺</span><strong>${escapeHtml(marketplace?.storeName || '—')}</strong></div>
          <div><span>站点</span><strong>${escapeHtml(marketplace?.countryCode || marketplaceId)}</strong></div>
          <div><span>账户绑定</span><strong>Amazon 已确认</strong></div>
          <div><span>预检 SKU</span><strong>${escapeHtml(result.sku || state.analysis.preview[0]?.sku || '—')}</strong></div>
          <div><span>可用授权</span><strong>${formatNumber(result.authorizationProfileCount || 1)} 个</strong></div>
          ${result.rejectedAuthorizationProfileCount ? `<div><span>未通过授权</span><strong>${formatNumber(result.rejectedAuthorizationProfileCount)} 个</strong></div>` : ''}
        </div>
        ${renderIssues(result.issues)}`;
      if (!automatic) toast('目标检查通过', `${marketplace?.storeName || 'Amazon seller'} · ${marketplace?.countryCode || marketplaceId}`, 'success');
      updateWorkflow();
      updateReview();
      updateSubmitButton();
    } catch (error) {
      if (requestId !== state.accountValidationRequest) return;
      state.account = null;
      setSectionState('#account-state', '账户不匹配', 'danger');
      $('#account-result').innerHTML = `<div class="inline-status is-danger target-guidance"><span class="status-dot is-danger"></span><span>Amazon 未确认当前 Carkee 与站点组合。请在设置中重新授权。${automatic ? '' : ` ${escapeHtml(error.message)}`}</span></div>`;
      setWorkflowStep('account', 'error', '不匹配');
      if (!automatic) toast('目标检查失败', error.message, 'danger');
      updateReview();
      updateSubmitButton();
    } finally {
      if (button && requestId === state.accountValidationRequest) setLoading(button, false);
    }
  }

  function renderIssues(issues) {
    if (!Array.isArray(issues) || !issues.length) return '';
    return `<ul class="issue-list">${issues.map(issue =>
      `<li>${escapeHtml(issue.severity || 'ISSUE')} · ${escapeHtml(issue.code || '')} · ${escapeHtml(issue.message || '')}</li>`
    ).join('')}</ul>`;
  }

  function selectedMarketplace() {
    const value = $('#marketplace-select').value;
    return authorizedMarketplaces().find(item => marketplaceContextValue(item) === value) || null;
  }

  function marketplaceCurrency(countryCode) {
    const currencies = {
      US: 'USD', CA: 'CAD', MX: 'MXN', BR: 'BRL', UK: 'GBP', GB: 'GBP',
      SE: 'SEK', PL: 'PLN', TR: 'TRY', JP: 'JPY', AU: 'AUD', SG: 'SGD',
      IN: 'INR', SA: 'SAR', AE: 'AED', EG: 'EGP',
    };
    return currencies[String(countryCode || '').toUpperCase()] || 'EUR';
  }

  function pricingMarketplaceValue(item) {
    return marketplaceContextValue(item);
  }

  function selectedPricingMarketplace() {
    const value = $('#pricing-marketplace-select').value;
    return authorizedMarketplaces().find(item => pricingMarketplaceValue(item) === value) || null;
  }

  function pricingContextReady(marketplace = selectedPricingMarketplace()) {
    return Boolean(marketplace?.sellerId && marketplace?.authSessionId);
  }

  function renderPricingMarketplaces() {
    const select = $('#pricing-marketplace-select');
    if (!select) return;
    const currentValue = select.value;
    const items = authorizedMarketplaces();
    if (!items.length) {
      select.innerHTML = '<option value="">先到设置连接 Carkee</option>';
      select.disabled = true;
      updatePricingButton();
      updateHeaderTarget();
      return;
    }
    select.innerHTML = '<option value="">选择 Carkee 站点</option>' + items.map(item =>
      `<option value="${escapeHtml(pricingMarketplaceValue(item))}">${escapeHtml(item.storeName || allowedAmazonStoreName())} · ${escapeHtml(item.countryCode)} · ${escapeHtml(item.name || 'Amazon 站点')} · ${escapeHtml(marketplaceCurrency(item.countryCode))}</option>`
    ).join('');
    if (items.some(item => pricingMarketplaceValue(item) === currentValue)) {
      select.value = currentValue;
    } else {
      const uploadTarget = selectedMarketplace();
      const matched = uploadTarget && items.find(item => item.sellerId === uploadTarget.sellerId && item.id === uploadTarget.id);
      if (matched) select.value = pricingMarketplaceValue(matched);
      else if (items.length === 1) select.value = pricingMarketplaceValue(items[0]);
    }
    select.disabled = false;
    updatePricingButton();
    updateHeaderTarget();
  }

  function updateHeaderTarget() {
    let summary = '未选择目标店铺';
    let ready = false;
    if (state.view === 'pricing') {
      const marketplace = selectedPricingMarketplace();
      if (marketplace) {
        summary = `${marketplace.storeName || 'Amazon seller'} · ${marketplace.countryCode}`;
        ready = true;
      }
    } else {
      const marketplace = selectedMarketplace();
      const store = state.account?.marketplace?.storeName || marketplace?.storeName;
      const country = state.account?.marketplace?.countryCode || marketplace?.countryCode;
      if (store || country) {
        summary = `${store || 'Amazon seller'} · ${country || 'Marketplace'}`;
        ready = Boolean(state.account);
      }
    }
    $('#target-summary').textContent = summary;
    $('#target-badge').title = `当前目标：${summary}`;
    $('#target-badge').classList.toggle('is-ready', ready);
  }

  function setPricingStep(step, status, detail) {
    const element = $(`[data-pricing-step="${step}"]`);
    if (!element) return;
    element.classList.remove('is-active', 'is-complete', 'is-error');
    if (status) element.classList.add(`is-${status}`);
    if (status === 'active') element.setAttribute('aria-current', 'step');
    else element.removeAttribute('aria-current');
    const target = $(`#pricing-step-${step}`);
    if (target && detail) target.textContent = detail;
  }

  function updatePricingWorkflow() {
    if (state.pricingFile) {
      setPricingStep('source', 'complete', state.pricingFile.name);
      setPricingStep('filter', state.pricingResult ? 'complete' : 'active', state.pricingResult ? `${formatNumber(state.pricingResult.summary.eligible)} 个候选` : '待运行');
    } else {
      setPricingStep('source', 'active', '待导入');
      setPricingStep('filter', '', '待运行');
    }
    setPricingStep('rule', state.pricingResult ? 'complete' : '', state.pricingResult ? '已模拟' : '待运行');
    setPricingStep('gate', state.pricingResult ? 'complete' : '', state.pricingResult ? '只读预览' : 'V4 执行');
  }

  function pricingRuleValuesValid() {
    return ['pricing-threshold', 'pricing-lower-value', 'pricing-upper-value', 'pricing-max-change']
      .every(id => Number.isFinite(Number($(`#${id}`).value)) && Number($(`#${id}`).value) > 0);
  }

  function applyPricingPreset(name) {
    const presets = {
      conservative: { lower: '0.30', upper: '0.30', maximum: '0.50' },
      standard: { lower: '0.50', upper: '0.50', maximum: '0.90' },
      aggressive: { lower: '0.90', upper: '0.90', maximum: '1.50' },
    };
    const preset = presets[name];
    if (!preset) return;
    state.pricingPreset = name;
    $('#pricing-threshold').value = '100';
    $('#pricing-lower-mode').value = 'FIXED_AMOUNT';
    $('#pricing-lower-value').value = preset.lower;
    $('#pricing-upper-mode').value = 'PERCENTAGE';
    $('#pricing-upper-value').value = preset.upper;
    $('#pricing-max-change').value = preset.maximum;
    $$('[data-pricing-preset]').forEach(button => {
      const selected = button.dataset.pricingPreset === name;
      button.classList.toggle('is-selected', selected);
      button.setAttribute('aria-pressed', String(selected));
    });
    state.pricingResult = null;
    state.pricingBatch = null;
    $('#pricing-results').classList.add('is-hidden');
    updatePricingButton();
  }

  function updatePricingButton() {
    const button = $('#pricing-run-button');
    if (!button) return;
    const marketplace = selectedPricingMarketplace();
    const contextReady = pricingContextReady(marketplace);
    const ready = Boolean(state.pricingFile && marketplace && contextReady && pricingRuleValuesValid());
    button.disabled = !ready;
    const status = $('#pricing-simulation-status');
    if (!marketplace) {
      status.className = 'inline-status is-warning';
      status.innerHTML = '<span class="status-dot is-warning"></span><span>请选择 Carkee 站点；授权未绑定时请到设置重新连接</span>';
    } else if (!contextReady) {
      status.className = 'inline-status is-warning';
      status.innerHTML = '<span class="status-dot is-warning"></span><span>Carkee 授权信息不完整，请在设置中重新授权</span>';
    } else if (!state.pricingFile) {
      status.className = 'inline-status';
      status.innerHTML = '<span class="status-dot"></span><span>等待 Listing 或赛狐快照文件</span>';
    } else if (!pricingRuleValuesValid()) {
      status.className = 'inline-status is-danger';
      status.innerHTML = '<span class="status-dot is-danger"></span><span>规则数值必须大于零</span>';
    } else if (!state.pricingResult) {
      status.className = 'inline-status is-success';
      status.innerHTML = '<span class="status-dot is-success"></span><span>数据与规则已就绪，可以运行安全模拟</span>';
    }
    updatePricingProductionControls();
    updatePricingWorkflow();
  }

  function updatePricingProductionControls() {
    const approvalButton = $('#pricing-approval-button');
    if (!approvalButton) return;

    approvalButton.disabled = true;
    approvalButton.classList.add('is-hidden');

    const strip = $('#pricing-production-strip');
    const status = $('#pricing-production-status');
    const phrase = $('#pricing-production-phrase');
    const action = $('#pricing-production-action');
    if (!strip || !status || !phrase || !action) return;
    phrase.value = '';
    action.disabled = true;
    status.textContent = 'V4_REQUIRED';
    strip.classList.add('is-hidden');
  }

  function openPricingActionDialog() {
    const batch = state.pricingBatch;
    if (!batch || !['APPROVAL_PENDING', 'APPROVED'].includes(batch.status)) return;
    const marketplace = selectedPricingMarketplace();
    const submitting = batch.status === 'APPROVED';
    $('#pricing-action-dialog-title').textContent = submitting ? '确认提交调价 Feed' : '确认调价审批';
    $('#pricing-dialog-store').textContent = batch.storeName || marketplace?.storeName || '—';
    $('#pricing-dialog-marketplace').textContent = batch.countryCode || marketplace?.countryCode || '—';
    $('#pricing-dialog-direction').textContent = batch.direction === 'DOWN' ? '下降' : '上涨';
    $('#pricing-dialog-rows').textContent = formatNumber(batch.rows || state.pricingResult?.summary?.eligible || 0);
    $('#pricing-dialog-risk').textContent = batch.risk || state.pricingResult?.summary?.overallRisk || '—';
    const confirm = $('#confirm-pricing-action');
    confirm.className = `button ${submitting ? 'button-danger' : 'button-primary'}`;
    confirm.innerHTML = `<i data-lucide="${submitting ? 'send' : 'badge-check'}" aria-hidden="true"></i>${submitting ? '确认提交' : '确认审批'}`;
    $('#pricing-action-dialog').showModal();
    refreshIcons();
  }

  function selectPricingFile(file) {
    if (!file) return;
    if (!/\.(csv|txt|tsv|xlsx|xlsm)$/i.test(file.name)) {
      toast('文件格式不支持', '请选择 CSV、TXT、TSV、XLSX 或 XLSM 文件', 'danger');
      return;
    }
    if (file.size > 8 * 1024 * 1024) {
      toast('文件过大', '调价快照不能超过 8 MB', 'danger');
      return;
    }
    state.pricingFile = file;
    state.pricingResult = null;
    state.pricingBatch = null;
    $('#pricing-file-name').textContent = file.name;
    $('#pricing-source-state').textContent = '已选择';
    $('#pricing-source-state').className = 'section-state is-success';
    $('#pricing-results').classList.add('is-hidden');
    updatePricingProductionControls();
    updatePricingButton();
  }

  function fileAsBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.addEventListener('load', () => resolve(String(reader.result).split(',', 2)[1] || ''), { once: true });
      reader.addEventListener('error', () => reject(reader.error || new Error('无法读取文件')), { once: true });
      reader.readAsDataURL(file);
    });
  }

  async function runPricingSimulation() {
    const marketplace = selectedPricingMarketplace();
    const file = state.pricingFile;
    if (!marketplace || !file) return;
    const button = $('#pricing-run-button');
    setLoading(button, true, '正在筛选与计算');
    const status = $('#pricing-simulation-status');
    status.className = 'inline-status is-warning';
    status.innerHTML = '<span class="status-dot is-warning"></span><span>正在解析快照、排除 FBA 并计算价格差异</span>';
    try {
      const spreadsheet = /\.(xlsx|xlsm)$/i.test(file.name);
      const payload = {
        fileName: file.name,
        authSessionId: marketplace.authSessionId,
        marketplaceId: marketplace.id,
        rule: {
          direction: state.pricingDirection,
          threshold: Number($('#pricing-threshold').value),
          lowerMode: $('#pricing-lower-mode').value,
          lowerValue: Number($('#pricing-lower-value').value),
          upperMode: $('#pricing-upper-mode').value,
          upperValue: Number($('#pricing-upper-value').value),
          maxAbsoluteChange: Number($('#pricing-max-change').value),
          businessPriceMode: $('#pricing-business-mode').value,
        },
      };
      if (spreadsheet) payload.contentBase64 = await fileAsBase64(file);
      else payload.content = await file.text();
      const result = await api('/api/pricing/simulate', { method: 'POST', body: JSON.stringify(payload) });
      state.pricingResult = result;
      state.pricingBatch = null;
      renderPricingResult(result);
      status.className = 'inline-status is-success';
      status.innerHTML = `<span class="status-dot is-success"></span><span>模拟完成：${formatNumber(result.summary.eligible)} 个候选，${formatNumber(result.summary.excluded)} 个已排除</span>`;
      toast('调价模拟完成', `${result.scope.storeName || 'Amazon seller'} · ${result.scope.countryCode} · ${formatNumber(result.summary.eligible)} 个候选`, 'success');
    } catch (error) {
      state.pricingResult = null;
      status.className = 'inline-status is-danger';
      status.innerHTML = `<span class="status-dot is-danger"></span><span>${escapeHtml(error.message)}</span>`;
      toast('调价模拟失败', error.message, 'danger');
      setPricingStep('filter', 'error', '模拟失败');
    } finally {
      setLoading(button, false);
      updatePricingWorkflow();
    }
  }

  function formatPrice(value, currency = '') {
    if (value == null || value === '') return '—';
    return `${Number(value).toFixed(2)}${currency ? ` ${currency}` : ''}`;
  }

  function renderPricingResult(result) {
    const summary = result.summary;
    const currency = result.scope.currency || '';
    $('#pricing-results').classList.remove('is-hidden');
    $('#pricing-total').textContent = formatNumber(summary.totalRows);
    $('#pricing-eligible').textContent = formatNumber(summary.eligible);
    $('#pricing-excluded').textContent = formatNumber(summary.excluded);
    $('#pricing-risk').textContent = summary.overallRisk;
    $('#pricing-file-summary').textContent = result.fileName;
    $('#pricing-scope-summary').textContent = `${result.scope.storeName || 'Amazon seller'} · ${result.scope.countryCode} · ${currency}`;
    $('#pricing-exclusion-count').textContent = `${formatNumber(summary.excluded)} 条`;
    const maxExclusion = Math.max(...result.exclusions.map(item => item.count), 1);
    $('#pricing-exclusion-list').innerHTML = result.exclusions.map(item => `
      <div class="exclusion-row">
        <div><span>${escapeHtml(item.label)}</span><div class="exclusion-track"><div class="exclusion-fill" style="width:${Math.max(2, Math.round(item.count / maxExclusion * 100))}%"></div></div></div>
        <strong>${formatNumber(item.count)}</strong>
      </div>`).join('');
    const items = result.eligibleItems.slice(0, 250);
    $('#pricing-preview-count').textContent = `${formatNumber(summary.eligible)} 条候选${summary.eligible > items.length ? ` · 显示前 ${items.length} 条` : ''}`;
    $('#pricing-preview-body').innerHTML = items.map(item => {
      const deltaClass = Number(item.delta) >= 0 ? 'is-up' : 'is-down';
      const deltaPrefix = Number(item.delta) > 0 ? '+' : '';
      const businessChange = item.currentBusinessPrice == null
        ? '—'
        : item.businessPriceMode === 'DO_NOT_CHANGE'
          ? `${formatPrice(item.currentBusinessPrice)}（不修改）`
          : `${formatPrice(item.currentBusinessPrice)} → ${formatPrice(item.newBusinessPrice)}`;
      return `<tr>
        <td><span class="pricing-item-id"><code>${escapeHtml(item.sku)}</code><small>${escapeHtml(item.asin)} · ${escapeHtml(String(item.quantity))} 件</small></span></td>
        <td class="align-right">${escapeHtml(formatPrice(item.currentPrice, currency))}</td>
        <td class="align-right"><strong>${escapeHtml(formatPrice(item.newPrice, currency))}</strong></td>
        <td class="align-right"><span class="price-delta ${deltaClass}">${deltaPrefix}${escapeHtml(formatPrice(item.delta))}<br><small>${escapeHtml(String(item.deltaPercent))}%</small></span></td>
        <td class="align-right">${escapeHtml(businessChange)}</td>
        <td><span class="risk-label is-${String(item.risk).toLowerCase()}">${escapeHtml(item.risk)}</span></td>
      </tr>`;
    }).join('');
    const missing = Array.isArray(summary.missingColumns) ? summary.missingColumns : [];
    $('#pricing-gate-message').textContent = missing.length
      ? `缺少必需列：${missing.join('、')}。所有不完整记录已阻断；生产提交保持锁定。`
      : result.gate.message;
    $('#pricing-export-button').disabled = !items.length;
    updatePricingProductionControls();
    updatePricingWorkflow();
    refreshIcons();
  }

  function exportPricingCsv() {
    const result = state.pricingResult;
    if (!result?.eligibleItems?.length) return;
    if (result.previewTruncated) {
      toast('导出被阻止', '当前批次超过安全预览上限，请缩小文件范围后重新模拟', 'warning');
      return;
    }
    const rows = [['SKU', 'ASIN', 'Currency', 'CurrentPrice', 'NewPrice', 'Delta', 'DeltaPercent', 'CurrentBusinessPrice', 'NewBusinessPrice', 'Risk']];
    result.eligibleItems.forEach(item => rows.push([
      item.sku, item.asin, result.scope.currency, item.currentPrice, item.newPrice, item.delta,
      item.deltaPercent, item.currentBusinessPrice ?? '', item.newBusinessPrice ?? '', item.risk,
    ]));
    const csv = rows.map(row => row.map(value => `"${String(value ?? '').replaceAll('"', '""')}"`).join(',')).join('\r\n');
    const url = URL.createObjectURL(new Blob([`\ufeff${csv}`], { type: 'text/csv;charset=utf-8' }));
    const link = document.createElement('a');
    link.href = url;
    link.download = `Klanata-Pricing-${result.scope.countryCode}-${result.simulationId.slice(0, 8)}.csv`;
    link.click();
    URL.revokeObjectURL(url);
  }

  async function createPricingBatch() {
    const button = $('#pricing-approval-button');
    const result = state.pricingResult;
    const marketplace = selectedPricingMarketplace();
    if (!result || !marketplace || !pricingContextReady(marketplace)) return;

    setLoading(button, true, '正在预检');
    try {
      const batch = await api('/api/pricing/batches', {
        method: 'POST',
        body: JSON.stringify({
          simulationId: result.simulationId,
          authSessionId: marketplace.authSessionId,
        }),
      });
      state.pricingBatch = batch;
      $('#pricing-production-phrase').value = '';
      updatePricingProductionControls();
      updatePricingWorkflow();
      toast('调价审批批次已创建', `Amazon VALIDATION_PREVIEW 已通过 ${batch.validationPreview?.accepted || 0} 条样本`, 'success');
    } catch (error) {
      toast('调价审批创建失败', error.message, 'danger');
    } finally {
      setLoading(button, false);
      updatePricingProductionControls();
    }
  }

  async function advancePricingBatch() {
    const batch = state.pricingBatch;
    if (!batch) return;
    const button = $('#pricing-production-action');
    const phrase = $('#pricing-production-phrase').value.trim();
    setLoading(button, true, batch.status === 'APPROVAL_PENDING' ? '正在审批' : '正在提交');
    try {
      if (batch.status === 'APPROVAL_PENDING') {
        state.pricingBatch = await api(`/api/pricing/batches/${batch.id}/approve`, {
          method: 'POST',
          body: JSON.stringify({ confirmation: phrase }),
        });
        $('#pricing-production-phrase').value = '';
        toast('调价批次已审批', '请再次复核目标后提交调价 Feed', 'success');
      } else if (batch.status === 'APPROVED') {
        const marketplace = selectedPricingMarketplace();
        const job = await api(`/api/pricing/batches/${batch.id}/submit`, {
          method: 'POST',
          body: JSON.stringify({
            confirmation: phrase,
            accountValidationId: batch.accountValidationId,
            authSessionId: marketplace?.authSessionId || batch.authSessionId || '',
          }),
        });
        state.selectedJobId = job.id;
        $('#pricing-production-phrase').value = '';
        toast('调价 Feed 已提交', job.feedId || job.id, 'success');
        await loadJobs();
        setView('jobs');
        startPolling(job.id);
      }
    } catch (error) {
      toast('调价批次处理失败', error.message, 'danger');
    } finally {
      if (button.isConnected) setLoading(button, false);
      updatePricingProductionControls();
      updatePricingWorkflow();
    }
  }

  function accountAuthorizationIds() {
    if (!state.account) return [];
    const ids = Array.isArray(state.account.authSessionIds) && state.account.authSessionIds.length
      ? state.account.authSessionIds
      : [state.account.authSessionId];
    const operationalIds = new Set(operationalAuthSessions().map(session => session.authSessionId));
    return [...new Set(ids.filter(id => id && operationalIds.has(id)))];
  }

  function renderSubmissionAuthorizations() {
    const select = $('#submission-auth-select');
    const detail = $('#submission-auth-detail');
    const currentValue = select.value;
    const ids = accountAuthorizationIds();
    if (!ids.length) {
      select.innerHTML = '<option value="">先完成目标检查</option>';
      select.disabled = true;
      detail.textContent = '同一店铺可保留多个已验证授权';
      $('#dialog-auth-profile').textContent = '—';
      return;
    }

    const regionNames = { na: '北美', eu: '欧洲', fe: '远东' };
    select.innerHTML = ids.map((id, index) => {
      const session = operationalAuthSessions().find(item => item.authSessionId === id);
      const region = session ? regionNames[session.region] || session.region.toUpperCase() : '授权';
      const stores = session ? verifiedSessionStoreName(session) : state.account.marketplace?.storeName || allowedAmazonStoreName();
      return `<option value="${escapeHtml(id)}">授权 ${index + 1} · ${escapeHtml(region)} · ${escapeHtml(stores)}</option>`;
    }).join('');
    select.value = ids.includes(currentValue) ? currentValue : ids.includes(state.account.authSessionId)
      ? state.account.authSessionId
      : ids[0];
    select.disabled = ids.length === 1;
    detail.textContent = ids.length > 1
      ? `已连接 ${ids.length} 个授权；本次提交只使用所选授权，不会重复提交 Feed`
      : '已连接 1 个授权';
    $('#dialog-auth-profile').textContent = select.selectedOptions[0]?.textContent || '—';
  }

  function updateReview() {
    const marketplace = selectedMarketplace();
    const submitDestination = state.account?.marketplace?.name || marketplace?.name || marketplace?.countryCode || '目标站点';
    const reviewStore = state.account?.marketplace?.storeName || marketplace?.storeName || '—';
    const reviewMarketplace = state.account?.marketplace?.countryCode || marketplace?.countryCode || '—';
    const risk = submissionRisk();
    $('#submit-context').textContent = `JSON_LISTINGS_FEED · ${submitDestination}`;
    $('#review-store').textContent = reviewStore;
    $('#review-marketplace').textContent = reviewMarketplace;
    $('#review-seller').textContent = state.account ? 'Amazon 已确认' : '—';
    $('#review-rows').textContent = state.analysis ? formatNumber(state.analysis.summary.rows) : '—';
    $('#review-zero').textContent = state.analysis ? `${formatNumber(risk.zeroQuantity)} (${(risk.zeroRate * 100).toFixed(1)}%)` : '—';
    $('#review-compact').textContent = state.account
      ? `${reviewStore} · ${reviewMarketplace} · ${formatNumber(risk.rows)} SKU`
      : '等待目标检查';
    $('#dialog-store').textContent = state.account?.marketplace?.storeName || '—';
    $('#dialog-marketplace').textContent = state.account?.marketplace?.countryCode || '—';
    $('#dialog-rows').textContent = state.analysis ? formatNumber(state.analysis.summary.rows) : '—';
    $('#dialog-zero').textContent = state.analysis ? `${formatNumber(risk.zeroQuantity)} (${(risk.zeroRate * 100).toFixed(1)}%)` : '—';
    $('#submission-risk').classList.toggle('is-hidden', !risk.high);
    $('#submission-risk-text').textContent = risk.high
      ? `高风险变更：共 ${formatNumber(risk.rows)} 个 SKU，其中 ${formatNumber(risk.zeroQuantity)} 个将设为零库存。`
      : '';
    $('#confirmation-label').textContent = `输入 ${risk.phrase}`;
    $('#confirmation-input').placeholder = risk.phrase;
    $('#confirmation-input').value = state.account ? risk.phrase : '';
    renderSubmissionAuthorizations();
    updateHeaderTarget();
    updateSubmitButton();
  }

  function updateSubmitButton() {
    const expectedConfirmation = submissionRisk().phrase;
    const ready = Boolean(
      state.analysis && accountAuthorizationIds().length && state.account && $('#submission-auth-select').value &&
      $('#confirm-checkbox').checked && $('#confirmation-input').value.trim() === expectedConfirmation
    );
    $('#submit-feed-button').disabled = !ready;
    if (state.account) setSectionState('#submit-state', ready ? '可以提交' : '等待确认', ready ? 'success' : 'warning');
    else setSectionState('#submit-state', '未就绪');
  }

  async function submitFeed() {
    if (!state.account) return;
    const button = $('#confirm-submit-button');
    setLoading(button, true, '正在提交');
    $('#submit-message').className = 'submit-message';
    $('#submit-message').textContent = '正在创建 Feed 文档并上传数据';
    try {
      const job = await api('/api/feeds/submit', {
        method: 'POST',
        body: JSON.stringify({
          accountValidationId: state.account.accountValidationId,
          authSessionId: $('#submission-auth-select').value,
          confirmation: submissionRisk().phrase
        })
      });
      $('#submit-dialog').close();
      state.selectedJobId = job.id;
      $('#confirm-checkbox').checked = false;
      $('#confirmation-input').value = '';
      $('#submit-message').className = 'submit-message is-success';
      $('#submit-message').textContent = `Feed ${job.feedId} 已进入队列`;
      setSectionState('#submit-state', '已提交', 'success');
      toast('Feed 已提交', job.feedId, 'success');
      await loadJobs();
      setView('jobs');
      startPolling(job.id);
    } catch (error) {
      $('#submit-message').className = 'submit-message is-danger';
      $('#submit-message').textContent = error.message;
      toast('Feed 提交失败', error.message, 'danger');
    } finally {
      setLoading(button, false);
      updateSubmitButton();
    }
  }

  function statusMeta(status) {
    if (status === 'DONE') return { label: '已完成', className: 'is-success' };
    if (status === 'IN_QUEUE') return { label: '队列中', className: 'is-progress' };
    if (status === 'IN_PROGRESS') return { label: '处理中', className: 'is-progress' };
    if (status === 'FATAL') return { label: '处理失败', className: 'is-danger' };
    if (status === 'CANCELLED') return { label: '已取消', className: 'is-danger' };
    if (status === 'RECONNECT_REQUIRED') return { label: '需重新授权', className: 'is-warning' };
    if (status === 'PREPARING_SUBMISSION') return { label: '准备提交', className: 'is-progress' };
    if (status === 'SUBMITTING') return { label: '正在提交', className: 'is-progress' };
    if (status === 'SUBMISSION_FAILED') return { label: '提交失败', className: 'is-danger' };
    if (status === 'SUBMISSION_UNKNOWN') return { label: '提交结果待确认', className: 'is-warning' };
    return { label: status || '未知', className: '' };
  }

  function jobKindLabel(job) {
    return job?.kind === 'PRICING' ? '调价' : '商品上传';
  }

  function shouldPollJob(job) {
    return Boolean(job) && (
      ['IN_QUEUE', 'IN_PROGRESS'].includes(job.status) ||
      (job.status === 'DONE' && !job.reportAvailable)
    );
  }

  function isFinalJob(job) {
    if (!job) return false;
    if (job.status === 'DONE') return job.reportAvailable;
    return ['FATAL', 'CANCELLED', 'RECONNECT_REQUIRED', 'SUBMISSION_FAILED', 'SUBMISSION_UNKNOWN'].includes(job.status);
  }

  async function loadJobs() {
    try {
      const result = await api('/api/jobs');
      state.jobs = result.jobs || [];
      $('#job-count').textContent = String(state.jobs.length);
      if (!state.selectedJobId && state.jobs.length) state.selectedJobId = state.jobs[0].id;
      renderJobs();
      updateWorkflow();
      const selectedJob = state.jobs.find(item => item.id === state.selectedJobId);
      if (!state.pollJobId && shouldPollJob(selectedJob)) startPolling(selectedJob.id);
    } catch (error) {
      toast('任务读取失败', error.message, 'danger');
    }
  }

  function renderJobs() {
    const body = $('#jobs-body');
    const empty = $('#jobs-empty');
    empty.classList.toggle('is-hidden', state.jobs.length > 0);
    body.innerHTML = state.jobs.map(job => {
      const meta = statusMeta(job.status);
      const kindLabel = jobKindLabel(job);
      return `<tr data-job-id="${escapeHtml(job.id)}" class="${job.id === state.selectedJobId ? 'is-selected' : ''}">
        <td>${escapeHtml(formatDate(job.createdAt))}</td>
        <td><span class="job-feed-cell"><span class="status-badge ${job.kind === 'PRICING' ? 'is-warning' : ''}">${escapeHtml(kindLabel)}</span><code>${escapeHtml(job.feedId || '—')}</code></span></td>
        <td>${escapeHtml(job.marketplaceId)}</td>
        <td class="align-right">${formatNumber(job.rows)}</td>
        <td><span class="status-badge ${meta.className}">${escapeHtml(meta.label)}</span></td>
      </tr>`;
    }).join('');
    $$('[data-job-id]', body).forEach(row => row.addEventListener('click', () => selectJob(row.dataset.jobId)));
    renderJobDetail();
  }

  function selectJob(jobId) {
    state.selectedJobId = jobId;
    renderJobs();
    const job = state.jobs.find(item => item.id === jobId);
    if (shouldPollJob(job)) startPolling(jobId, true);
    else stopPolling();
  }

  function matchingValidatedSessionForJob(job) {
    if (!job) return null;
    return operationalAuthSessions().find(session => session.sellerId === job.sellerId &&
      session.region === job.region &&
      (Array.isArray(session.marketplaces) ? session.marketplaces : []).some(item => item.id === job.marketplaceId && item.isParticipating)) || null;
  }

  function renderJobDetail() {
    const job = state.jobs.find(item => item.id === state.selectedJobId);
    const container = $('#job-detail');
    if (!job) {
      container.innerHTML = '<div class="empty-state"><i data-lucide="mouse-pointer-click" aria-hidden="true"></i><span>选择任务查看处理状态</span></div>';
      refreshIcons();
      return;
    }

    const meta = statusMeta(job.status);
    const summary = job.reportSummary || {};
    const reconnectAuth = matchingValidatedSessionForJob(job);
    const kindLabel = jobKindLabel(job);
    const secondaryMetricLabel = job.kind === 'PRICING' ? '方向 / 币种' : '零库存';
    const secondaryMetricValue = job.kind === 'PRICING'
      ? `${escapeHtml(job.direction || '—')} / ${escapeHtml(job.currency || '—')}`
      : formatNumber(job.zeroQuantity);
    container.innerHTML = `
      <div class="job-detail-header">
        <div><h3>${escapeHtml(job.fileName)}</h3><code>${escapeHtml(kindLabel)} · ${escapeHtml(job.feedId || job.id)}</code></div>
        <span class="status-badge ${meta.className}">${escapeHtml(meta.label)}</span>
      </div>
      ${renderJobProgress(job)}
      <dl class="job-summary">
        <div><dt>SKU</dt><dd>${formatNumber(job.rows)}</dd></div>
        <div><dt>${secondaryMetricLabel}</dt><dd>${secondaryMetricValue}</dd></div>
        <div><dt>已接受</dt><dd>${summary.messagesAccepted == null ? '—' : formatNumber(summary.messagesAccepted)}</dd></div>
        <div><dt>无效消息</dt><dd>${summary.messagesInvalid == null ? '—' : formatNumber(summary.messagesInvalid)}</dd></div>
        <div><dt>错误 / 警告</dt><dd>${summary.errors == null ? '—' : `${formatNumber(summary.errors)} / ${formatNumber(summary.warnings)}`}</dd></div>
        <div><dt>更新时间</dt><dd>${escapeHtml(formatDate(job.updatedAt))}</dd></div>
      </dl>
      ${job.error ? `<div class="inline-status is-danger" style="margin-top:14px"><span class="status-dot is-danger"></span><span>${escapeHtml(job.error)}</span></div>` : ''}
      <div class="job-actions">
        ${job.reportAvailable ? `<a class="button" href="/api/jobs/${escapeHtml(job.id)}/report"><i data-lucide="download" aria-hidden="true"></i>下载处理报告</a>` : ''}
        ${['IN_QUEUE', 'IN_PROGRESS'].includes(job.status) ? `<button class="button" type="button" data-refresh-job="${escapeHtml(job.id)}"><i data-lucide="refresh-cw" aria-hidden="true"></i>更新状态</button>` : ''}
        ${job.status === 'RECONNECT_REQUIRED' && reconnectAuth ? `<button class="button button-primary" type="button" data-reconnect-job="${escapeHtml(job.id)}"><i data-lucide="plug-zap" aria-hidden="true"></i>使用匹配授权继续</button>` : ''}
        ${job.status === 'RECONNECT_REQUIRED' && !reconnectAuth ? `<button class="button" type="button" data-open-auth><i data-lucide="shield-check" aria-hidden="true"></i>前往授权</button>` : ''}
      </div>`;
    const refresh = $('[data-refresh-job]', container);
    if (refresh) refresh.addEventListener('click', () => refreshJob(job.id));
    const reconnect = $('[data-reconnect-job]', container);
    if (reconnect) reconnect.addEventListener('click', () => reconnectJob(job.id, reconnect));
    const openAuth = $('[data-open-auth]', container);
    if (openAuth) openAuth.addEventListener('click', () => {
      setView('settings');
      $('#auth-heading').scrollIntoView({ behavior: 'smooth', block: 'start' });
    });
    refreshIcons();
  }

  function renderJobProgress(job) {
    const status = job.status;
    const terminalError = ['FATAL', 'CANCELLED', 'SUBMISSION_FAILED', 'SUBMISSION_UNKNOWN'].includes(status);
    const processingText = job.kind === 'PRICING' ? '正在校验并更新价格' : '正在校验并更新库存';
    const submittedTitle = job.kind === 'PRICING' ? '调价 Feed 已提交' : 'Feed 已提交';
    const stages = [
      { key: 'submitted', title: submittedTitle, detail: job.feedId || '等待 Feed ID' },
      { key: 'queue', title: 'Amazon 队列', detail: status === 'IN_QUEUE' ? '等待处理' : '已离开队列' },
      { key: 'processing', title: '数据处理', detail: status === 'IN_PROGRESS' ? processingText : terminalError ? status : status === 'DONE' ? '处理完成' : '等待处理' },
      { key: 'report', title: '处理报告', detail: job.reportAvailable ? '报告已生成' : terminalError ? '检查失败详情' : status === 'DONE' ? '正在获取报告' : '等待生成' }
    ];

    const currentIndex = status === 'IN_QUEUE' ? 1 : status === 'IN_PROGRESS' ? 2 : 3;
    return `<div class="job-progress">${stages.map((stage, index) => {
      let className = '';
      if (terminalError && index === 3) className = 'is-error';
      else if (status === 'DONE') className = index < 3 || job.reportAvailable ? 'is-complete' : 'is-active';
      else if (index < currentIndex) className = 'is-complete';
      else if (index === currentIndex) className = 'is-active';
      return `<div class="progress-step ${className}"><span class="progress-node">${className === 'is-complete' ? '✓' : index + 1}</span><strong>${escapeHtml(stage.title)}</strong><span>${escapeHtml(stage.detail)}</span></div>`;
    }).join('')}</div>`;
  }

  async function refreshJob(jobId, { silent = false } = {}) {
    try {
      const job = await api(`/api/jobs/${jobId}`);
      const index = state.jobs.findIndex(item => item.id === jobId);
      if (index >= 0) state.jobs[index] = job;
      else state.jobs.unshift(job);
      renderJobs();
      updateWorkflow();
      if (isFinalJob(job) && !silent) {
        toast('Feed 状态已更新', statusMeta(job.status).label, job.status === 'DONE' ? 'success' : 'danger');
      }
      return job;
    } catch (error) {
      if (!silent) toast('状态更新失败', error.message, 'danger');
      throw error;
    }
  }

  async function reconnectJob(jobId, button) {
    const currentJob = state.jobs.find(item => item.id === jobId);
    const matchingAuth = matchingValidatedSessionForJob(currentJob);
    if (!matchingAuth) {
      toast('需要授权', '请先在设置中重新授权对应店铺，再选择目标站点', 'danger');
      return;
    }

    setLoading(button, true, '正在重连');
    try {
      const job = await api(`/api/jobs/${jobId}/reconnect`, {
        method: 'POST',
        body: JSON.stringify({ authSessionId: matchingAuth.authSessionId })
      });
      const index = state.jobs.findIndex(item => item.id === jobId);
      if (index >= 0) state.jobs[index] = job;
      else state.jobs.unshift(job);
      renderJobs();
      updateWorkflow();
      if (shouldPollJob(job)) startPolling(jobId, true);
      toast('任务已重新连接', statusMeta(job.status).label, 'success');
    } catch (error) {
      toast('任务重连失败', error.message, 'danger');
    } finally {
      if (button.isConnected) setLoading(button, false);
    }
  }

  function schedulePoll(delay = 6000) {
    if (!state.pollJobId) return;
    if (state.pollTimer) window.clearTimeout(state.pollTimer);
    state.pollTimer = window.setTimeout(pollJob, delay);
  }

  async function pollJob() {
    const jobId = state.pollJobId;
    if (!jobId) return;
    if (state.pollInFlight) {
      schedulePoll(1000);
      return;
    }
    if (document.hidden) {
      schedulePoll(12000);
      return;
    }

    state.pollInFlight = true;
    try {
      const job = await refreshJob(jobId, { silent: true });
      if (state.pollJobId !== jobId) return;
      if (job.status === 'DONE' && !job.reportAvailable && job.error) {
        state.pollFailures++;
        if (state.pollFailures >= 5) {
          stopPolling();
          toast('处理报告获取失败', '库存 Feed 已处理，但报告需要手动重试下载', 'warning');
        } else {
          schedulePoll(Math.min(30000, 6000 * Math.pow(2, state.pollFailures)));
        }
        return;
      }
      state.pollFailures = 0;
      if (isFinalJob(job)) {
        stopPolling();
        toast('Feed 状态已更新', statusMeta(job.status).label, job.status === 'DONE' ? 'success' : 'danger');
      } else {
        schedulePoll();
      }
    } catch (error) {
      if (state.pollJobId !== jobId) return;
      state.pollFailures++;
      if (state.pollFailures === 1) {
        toast('状态更新暂时失败', '系统将自动重试，不会重复提交 Feed', 'warning');
      }
      schedulePoll(Math.min(30000, 6000 * Math.pow(2, Math.min(state.pollFailures, 3))));
    } finally {
      state.pollInFlight = false;
    }
  }

  function startPolling(jobId, immediate = false) {
    stopPolling();
    state.pollJobId = jobId;
    state.pollFailures = 0;
    schedulePoll(immediate ? 0 : 6000);
  }

  function stopPolling() {
    if (state.pollTimer) window.clearTimeout(state.pollTimer);
    state.pollTimer = null;
    state.pollJobId = null;
    state.pollFailures = 0;
  }

  function bindEvents() {
    window.addEventListener('hashchange', () => setView(viewFromHash(), false));
    $$('[data-flow-jump]').forEach(button => button.addEventListener('click', () => {
      setExpandedWorkflowStep(button.dataset.flowJump, true);
    }));
    $$('[data-flow-toggle]').forEach(button => button.addEventListener('click', () => {
      toggleExpandedWorkflowStep(button.dataset.flowToggle);
    }));
    $('#analysis-toggle').addEventListener('click', () => setAnalysisDetails(!state.analysisDetailsOpen));

    $('#refresh-button').addEventListener('click', async () => {
      if (state.view === 'jobs') await loadJobs();
      else if (state.view === 'pricing') {
        renderPricingMarketplaces();
        updatePricingButton();
      }
      else await loadServerStatus();
    });
    $('#refresh-jobs-button').addEventListener('click', loadJobs);

    $('#choose-file-button').addEventListener('click', () => $('#file-input').click());
    $('#file-input').addEventListener('change', event => {
      const file = event.target.files?.[0];
      if (file) analyzeFile(file);
    });
    $('#load-default-button').addEventListener('click', () => analyzeDefault(false));

    const dropZone = $('#drop-zone');
    ['dragenter', 'dragover'].forEach(type => dropZone.addEventListener(type, event => {
      event.preventDefault();
      dropZone.classList.add('is-dragging');
    }));
    ['dragleave', 'drop'].forEach(type => dropZone.addEventListener(type, event => {
      event.preventDefault();
      dropZone.classList.remove('is-dragging');
    }));
    dropZone.addEventListener('drop', event => {
      const file = event.dataTransfer.files?.[0];
      if (file) analyzeFile(file);
    });

    $$('[data-password-toggle]').forEach(button => button.addEventListener('click', () => {
      const input = $(`#${button.dataset.passwordToggle}`);
      input.type = input.type === 'password' ? 'text' : 'password';
      button.innerHTML = `<i data-lucide="${input.type === 'password' ? 'eye' : 'eye-off'}"></i>`;
      button.setAttribute('aria-label', `${input.type === 'password' ? '显示' : '隐藏'} ${button.dataset.passwordToggle.replaceAll('-', ' ')}`);
      button.setAttribute('aria-pressed', String(input.type !== 'password'));
      refreshIcons();
    }));

    $('#oauth-auth-button').addEventListener('click', startOAuthAuthorization);
    $('#save-application-button').addEventListener('click', saveDeveloperApplication);
    $('#verify-auth-button').addEventListener('click', verifyAuth);
    $('#seller-id').addEventListener('input', () => {
      if (state.account) invalidateAccount();
      updateAccountButton();
      updateReview();
    });
    $('#marketplace-select').addEventListener('change', () => {
      void prepareSelectedTarget();
    });

    $('#pricing-choose-file-button').addEventListener('click', () => $('#pricing-file-input').click());
    $('#pricing-file-input').addEventListener('change', event => selectPricingFile(event.target.files?.[0]));
    $('#pricing-marketplace-select').addEventListener('change', () => {
      state.pricingResult = null;
      state.pricingBatch = null;
      $('#pricing-results').classList.add('is-hidden');
      updatePricingButton();
      updateHeaderTarget();
    });
    $$('[data-pricing-direction]').forEach(button => button.addEventListener('click', () => {
      state.pricingDirection = button.dataset.pricingDirection;
      $$('[data-pricing-direction]').forEach(item => {
        const selected = item === button;
        item.classList.toggle('is-selected', selected);
        item.setAttribute('aria-pressed', String(selected));
      });
      state.pricingResult = null;
      state.pricingBatch = null;
      $('#pricing-results').classList.add('is-hidden');
      updatePricingButton();
    }));
    $$('[data-pricing-preset]').forEach(button => button.addEventListener('click', () => {
      applyPricingPreset(button.dataset.pricingPreset);
    }));
    ['pricing-threshold', 'pricing-lower-mode', 'pricing-lower-value', 'pricing-upper-mode', 'pricing-upper-value', 'pricing-max-change', 'pricing-business-mode']
      .forEach(id => $(`#${id}`).addEventListener('change', () => {
        state.pricingPreset = 'custom';
        $$('[data-pricing-preset]').forEach(button => {
          button.classList.remove('is-selected');
          button.setAttribute('aria-pressed', 'false');
        });
        state.pricingResult = null;
        state.pricingBatch = null;
        $('#pricing-results').classList.add('is-hidden');
        updatePricingButton();
      }));
    $('#pricing-run-button').addEventListener('click', runPricingSimulation);
    $('#pricing-export-button').addEventListener('click', exportPricingCsv);
    $('#pricing-approval-button').addEventListener('click', createPricingBatch);
    $('#pricing-production-action').addEventListener('click', openPricingActionDialog);
    $('#confirm-pricing-action').addEventListener('click', async () => {
      $('#pricing-action-dialog').close();
      await advancePricingBatch();
    });

    $('#confirm-checkbox').addEventListener('change', updateSubmitButton);
    $('#confirmation-input').addEventListener('input', updateSubmitButton);
    $('#submission-auth-select').addEventListener('change', () => {
      $('#dialog-auth-profile').textContent = $('#submission-auth-select').selectedOptions[0]?.textContent || '—';
      updateSubmitButton();
    });
    $('#submit-feed-button').addEventListener('click', () => {
      updateReview();
      $('#submit-dialog').showModal();
    });
    $('#confirm-submit-button').addEventListener('click', submitFeed);
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden && state.pollJobId && !state.pollInFlight) schedulePoll(0);
    });
  }

  async function init() {
    const oauthReturn = consumeOAuthReturn();
    const localHost = ['localhost', '127.0.0.1', '::1'].includes(window.location.hostname);
    $('#server-host').textContent = window.location.host || '本地服务';
    $('#environment-label').textContent = localHost ? '本地工作站' : '生产环境';
    mountSettingsAuth();
    bindEvents();
    setView(viewFromHash());
    refreshIcons();
    updateWorkflow();
    updatePricingWorkflow();
    updatePricingButton();
    updateSubmitButton();
    try {
      await Promise.all([loadServerStatus(), loadJobs()]);
      await restoreWorkflow();
      if (oauthReturn?.success) {
        toast('Carkee 已连接', '可销售站点已自动发现，可以直接在工作台选择', 'success');
      } else if (oauthReturn) {
        toast('Amazon 授权未完成', oauthReasonMessage(oauthReturn.reason), 'danger');
      }
    } finally {
      $('#main-content').setAttribute('aria-busy', 'false');
      document.body.classList.remove('is-booting');
    }
  }

  init();
})();
