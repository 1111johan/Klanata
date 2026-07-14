(() => {
  'use strict';

  const state = {
    view: 'workspace',
    region: 'na',
    server: null,
    analysis: null,
    auth: null,
    account: null,
    jobs: [],
    selectedJobId: null,
    pollTimer: null,
    defaultAutoLoaded: false
  };

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
  const numberFormatter = new Intl.NumberFormat('zh-CN');
  const dateFormatter = new Intl.DateTimeFormat('zh-CN', {
    month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false
  });

  const pageMeta = {
    workspace: ['库存 Feed 工作台', 'JSON_LISTINGS_FEED · 加拿大站'],
    jobs: ['任务记录', 'Feed 处理状态与报告'],
    system: ['系统状态', '本地服务与接口端点']
  };

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
    button.innerHTML = loading
      ? `<span class="button-spinner" aria-hidden="true"></span>${escapeHtml(label || '处理中')}`
      : button.dataset.originalHtml;
    refreshIcons();
  }

  function refreshIcons() {
    if (window.lucide) window.lucide.createIcons({ attrs: { width: 16, height: 16, 'stroke-width': 1.8 } });
  }

  function setView(view) {
    state.view = view;
    $$('.view').forEach(node => node.classList.toggle('is-visible', node.dataset.view === view));
    $$('.nav-item').forEach(button => {
      const active = button.dataset.viewTarget === view;
      button.classList.toggle('is-active', active);
      if (active) button.setAttribute('aria-current', 'page');
      else button.removeAttribute('aria-current');
    });
    $('#page-title').textContent = pageMeta[view][0];
    $('#page-subtitle').textContent = pageMeta[view][1];
    if (view === 'jobs') loadJobs();
    if (view === 'system') renderSystem();
  }

  function setSectionState(elementId, text, type = '') {
    const element = $(elementId);
    element.textContent = text;
    element.className = `section-state ${type ? `is-${type}` : ''}`;
  }

  function setWorkflowStep(step, status, detail) {
    const element = $(`[data-workflow-step="${step}"]`);
    element.classList.remove('is-active', 'is-complete', 'is-error');
    if (status) element.classList.add(`is-${status}`);
    const target = $(`#step-${step}-status`);
    if (target && detail) target.textContent = detail;
  }

  function updateWorkflow() {
    if (state.analysis) setWorkflowStep('file', 'complete', `${formatNumber(state.analysis.summary.rows)} SKU`);
    else setWorkflowStep('file', 'active', '待载入');

    if (state.auth) setWorkflowStep('auth', 'complete', state.auth.storeNames.join(', ') || '已授权');
    else setWorkflowStep('auth', state.analysis ? 'active' : '', '待验证');

    if (state.account) setWorkflowStep('account', 'complete', '已匹配');
    else setWorkflowStep('account', state.auth ? 'active' : '', '待验证');

    const activeJob = state.jobs.find(job => job.id === state.selectedJobId);
    if (activeJob) {
      if (activeJob.status === 'DONE') setWorkflowStep('submit', 'complete', '已完成');
      else if (['FATAL', 'CANCELLED'].includes(activeJob.status)) setWorkflowStep('submit', 'error', activeJob.status);
      else setWorkflowStep('submit', 'active', activeJob.status);
    } else {
      setWorkflowStep('submit', state.account ? 'active' : '', '未提交');
    }
  }

  async function loadServerStatus() {
    try {
      state.server = await api('/api/status');
      $('#server-dot').className = 'status-dot is-success';
      $('#server-label').textContent = '服务正常';
      $('#load-default-button').disabled = !state.server.defaultFileAvailable;
      renderSystem();
      if (state.server.defaultFileAvailable && !state.defaultAutoLoaded) {
        state.defaultAutoLoaded = true;
        await analyzeDefault(true);
      }
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
      const content = await file.text();
      const result = await api('/api/analyze', {
        method: 'POST', body: JSON.stringify({ fileName: file.name, content })
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
    invalidateAccount(false);
    $('#drop-title').textContent = result.fileName;
    $('#drop-meta').textContent = `${formatNumber(result.summary.rows)} 行 · ${result.summary.columnCount} 列`;
    setSectionState('#file-state', '校验通过', 'success');
    $('#file-summary').innerHTML = `
      <dl class="file-facts">
        <div><dt>文件</dt><dd>${escapeHtml(result.fileName)}</dd></div>
        <div><dt>有效数据</dt><dd>${formatNumber(result.summary.rows)} 行</dd></div>
        <div><dt>唯一 SKU</dt><dd>${formatNumber(result.summary.uniqueSkus)}</dd></div>
        <div><dt>示例行</dt><dd>已跳过 ${formatNumber(result.summary.skippedExampleRows)}</dd></div>
        <div><dt>有效字段</dt><dd>${result.nonEmptyColumns.map(item => escapeHtml(item.label)).join(' / ')}</dd></div>
      </dl>`;
    $('#analysis-area').classList.remove('is-hidden');
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
    updateReview();
    updateWorkflow();
    updateAccountButton();
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

  function selectRegion(region) {
    state.region = region;
    state.auth = null;
    invalidateAccount(false);
    $$('.segment').forEach(button => {
      const selected = button.dataset.region === region;
      button.classList.toggle('is-selected', selected);
      button.setAttribute('aria-pressed', String(selected));
    });
    setSectionState('#auth-state', '未验证');
    $('#auth-result').className = 'inline-status';
    $('#auth-result').innerHTML = '<span class="status-dot" aria-hidden="true"></span><span>等待授权验证</span>';
    $('#marketplace-select').innerHTML = '<option value="">先验证接口授权</option>';
    $('#marketplace-select').disabled = true;
    updateWorkflow();
    updateReview();
  }

  async function verifyAuth() {
    const button = $('#verify-auth-button');
    const clientId = $('#client-id').value.trim();
    const clientSecret = $('#client-secret').value.trim();
    const refreshToken = $('#refresh-token').value.trim();
    if (!clientId || !clientSecret || !refreshToken) {
      toast('缺少凭证', '请填写 Client identifier、Client secret 和 Refresh token', 'danger');
      return;
    }

    setLoading(button, true, '验证中');
    $('#auth-result').className = 'inline-status';
    $('#auth-result').innerHTML = '<span class="status-dot is-warning" aria-hidden="true"></span><span>正在连接 Amazon SP-API</span>';
    try {
      const result = await api('/api/auth/verify', {
        method: 'POST', body: JSON.stringify({ clientId, clientSecret, refreshToken, region: state.region })
      });
      state.auth = result;
      invalidateAccount(false);
      setSectionState('#auth-state', '授权有效', 'success');
      $('#auth-result').className = 'inline-status is-success';
      const countries = [...new Set(result.marketplaces.map(item => item.countryCode))].join(', ');
      $('#auth-result').innerHTML = `<span class="status-dot is-success" aria-hidden="true"></span><span>${escapeHtml(result.storeNames.join(', ') || '已授权')} · ${escapeHtml(countries)}</span>`;
      renderMarketplaces(result.marketplaces);
      $('#client-secret').value = '';
      $('#refresh-token').value = '';
      toast('授权验证通过', `${result.storeNames.join(', ') || 'Amazon seller'} · ${result.region.toUpperCase()}`, 'success');
      updateWorkflow();
      updateReview();
      updateAccountButton();
    } catch (error) {
      state.auth = null;
      setSectionState('#auth-state', '授权失败', 'danger');
      $('#auth-result').className = 'inline-status is-danger';
      $('#auth-result').innerHTML = `<span class="status-dot is-danger" aria-hidden="true"></span><span>${escapeHtml(error.message)}</span>`;
      toast('授权验证失败', error.message, 'danger');
      updateWorkflow();
    } finally {
      setLoading(button, false);
    }
  }

  function renderMarketplaces(items) {
    const select = $('#marketplace-select');
    const active = items.filter(item => item.isParticipating);
    select.innerHTML = '<option value="">选择 Marketplace</option>' + active.map(item =>
      `<option value="${escapeHtml(item.id)}">${escapeHtml(item.countryCode)} · ${escapeHtml(item.name)} · ${escapeHtml(item.storeName)}</option>`
    ).join('');
    const canada = active.find(item => item.id === 'A2EUQ1WTGCTBG2');
    if (canada) select.value = canada.id;
    select.disabled = false;
  }

  function updateAccountButton() {
    $('#validate-account-button').disabled = !(state.analysis && state.auth && $('#seller-id').value.trim() && $('#marketplace-select').value);
  }

  function invalidateAccount(update = true) {
    state.account = null;
    setSectionState('#account-state', '未验证');
    $('#account-result').innerHTML = '<div class="empty-state compact"><i data-lucide="link-2" aria-hidden="true"></i><span>等待 Seller ID 与授权账户匹配</span></div>';
    if (update) {
      updateWorkflow();
      updateReview();
      updateSubmitButton();
    }
    refreshIcons();
  }

  async function validateAccount() {
    if (!state.analysis || !state.auth) return;
    const button = $('#validate-account-button');
    const sellerId = $('#seller-id').value.trim();
    const marketplaceId = $('#marketplace-select').value;
    setLoading(button, true, '验证中');
    setSectionState('#account-state', '正在验证', 'warning');
    try {
      const result = await api('/api/account/validate', {
        method: 'POST',
        body: JSON.stringify({
          authSessionId: state.auth.authSessionId,
          analysisId: state.analysis.analysisId,
          sellerId,
          marketplaceId
        })
      });
      const marketplace = state.auth.marketplaces.find(item => item.id === marketplaceId);
      state.account = { ...result, marketplace, sellerId, marketplaceId };
      setSectionState('#account-state', '匹配通过', 'success');
      $('#account-result').innerHTML = `
        <div class="account-match">
          <div><span>店铺</span><strong>${escapeHtml(marketplace?.storeName || '—')}</strong></div>
          <div><span>Marketplace</span><strong>${escapeHtml(marketplace?.countryCode || marketplaceId)}</strong></div>
          <div><span>Seller ID</span><strong>${escapeHtml(sellerId)}</strong></div>
          <div><span>预检 SKU</span><strong>${escapeHtml(result.sku || state.analysis.preview[0]?.sku || '—')}</strong></div>
        </div>
        ${renderIssues(result.issues)}`;
      toast('账户匹配通过', `${marketplace?.storeName || 'Amazon seller'} · ${marketplace?.countryCode || marketplaceId}`, 'success');
      updateWorkflow();
      updateReview();
      updateSubmitButton();
    } catch (error) {
      state.account = null;
      setSectionState('#account-state', '账户不匹配', 'danger');
      $('#account-result').innerHTML = `<div class="inline-status is-danger" style="padding-top:14px"><span class="status-dot is-danger"></span><span>${escapeHtml(error.message)}</span></div>`;
      setWorkflowStep('account', 'error', '不匹配');
      toast('账户匹配失败', error.message, 'danger');
      updateReview();
      updateSubmitButton();
    } finally {
      setLoading(button, false);
    }
  }

  function renderIssues(issues) {
    if (!Array.isArray(issues) || !issues.length) return '';
    return `<ul class="issue-list">${issues.map(issue =>
      `<li>${escapeHtml(issue.severity || 'ISSUE')} · ${escapeHtml(issue.code || '')} · ${escapeHtml(issue.message || '')}</li>`
    ).join('')}</ul>`;
  }

  function selectedMarketplace() {
    if (!state.auth) return null;
    return state.auth.marketplaces.find(item => item.id === $('#marketplace-select').value) || null;
  }

  function updateReview() {
    const marketplace = selectedMarketplace();
    $('#review-store').textContent = state.account?.marketplace?.storeName || marketplace?.storeName || '—';
    $('#review-marketplace').textContent = state.account?.marketplace?.countryCode || marketplace?.countryCode || '—';
    $('#review-seller').textContent = state.account?.sellerId || $('#seller-id').value.trim() || '—';
    $('#review-rows').textContent = state.analysis ? formatNumber(state.analysis.summary.rows) : '—';
    $('#review-zero').textContent = state.analysis ? formatNumber(state.analysis.summary.zeroQuantity) : '—';
    $('#dialog-store').textContent = state.account?.marketplace?.storeName || '—';
    $('#dialog-marketplace').textContent = state.account?.marketplace?.countryCode || '—';
    $('#dialog-rows').textContent = state.analysis ? formatNumber(state.analysis.summary.rows) : '—';
    updateSubmitButton();
  }

  function updateSubmitButton() {
    const ready = Boolean(
      state.analysis && state.auth && state.account &&
      $('#confirm-checkbox').checked && $('#confirmation-input').value.trim() === 'SUBMIT'
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
        body: JSON.stringify({ accountValidationId: state.account.accountValidationId, confirmation: 'SUBMIT' })
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
    return { label: status || '未知', className: '' };
  }

  async function loadJobs() {
    try {
      const result = await api('/api/jobs');
      state.jobs = result.jobs || [];
      $('#job-count').textContent = String(state.jobs.length);
      if (!state.selectedJobId && state.jobs.length) state.selectedJobId = state.jobs[0].id;
      renderJobs();
      updateWorkflow();
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
      return `<tr data-job-id="${escapeHtml(job.id)}" class="${job.id === state.selectedJobId ? 'is-selected' : ''}">
        <td>${escapeHtml(formatDate(job.createdAt))}</td>
        <td><code>${escapeHtml(job.feedId || '—')}</code></td>
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
    if (job && ['IN_QUEUE', 'IN_PROGRESS'].includes(job.status)) startPolling(jobId);
    else stopPolling();
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
    container.innerHTML = `
      <div class="job-detail-header">
        <div><h3>${escapeHtml(job.fileName)}</h3><code>${escapeHtml(job.feedId || job.id)}</code></div>
        <span class="status-badge ${meta.className}">${escapeHtml(meta.label)}</span>
      </div>
      ${renderJobProgress(job)}
      <dl class="job-summary">
        <div><dt>SKU</dt><dd>${formatNumber(job.rows)}</dd></div>
        <div><dt>零库存</dt><dd>${formatNumber(job.zeroQuantity)}</dd></div>
        <div><dt>已接受</dt><dd>${summary.messagesAccepted == null ? '—' : formatNumber(summary.messagesAccepted)}</dd></div>
        <div><dt>无效消息</dt><dd>${summary.messagesInvalid == null ? '—' : formatNumber(summary.messagesInvalid)}</dd></div>
        <div><dt>更新时间</dt><dd>${escapeHtml(formatDate(job.updatedAt))}</dd></div>
      </dl>
      ${job.error ? `<div class="inline-status is-danger" style="margin-top:14px"><span class="status-dot is-danger"></span><span>${escapeHtml(job.error)}</span></div>` : ''}
      <div class="job-actions">
        ${job.reportAvailable ? `<a class="button" href="/api/jobs/${escapeHtml(job.id)}/report"><i data-lucide="download" aria-hidden="true"></i>下载处理报告</a>` : ''}
        ${['IN_QUEUE', 'IN_PROGRESS'].includes(job.status) ? `<button class="button" type="button" data-refresh-job="${escapeHtml(job.id)}"><i data-lucide="refresh-cw" aria-hidden="true"></i>更新状态</button>` : ''}
      </div>`;
    const refresh = $('[data-refresh-job]', container);
    if (refresh) refresh.addEventListener('click', () => refreshJob(job.id));
    refreshIcons();
  }

  function renderJobProgress(job) {
    const status = job.status;
    const terminalError = ['FATAL', 'CANCELLED'].includes(status);
    const stages = [
      { key: 'submitted', title: 'Feed 已提交', detail: job.feedId || '等待 Feed ID' },
      { key: 'queue', title: 'Amazon 队列', detail: status === 'IN_QUEUE' ? '等待处理' : '已离开队列' },
      { key: 'processing', title: '数据处理', detail: status === 'IN_PROGRESS' ? '正在校验并更新库存' : terminalError ? status : status === 'DONE' ? '处理完成' : '等待处理' },
      { key: 'report', title: '处理报告', detail: job.reportAvailable ? '报告已生成' : terminalError ? '检查失败详情' : '等待生成' }
    ];

    const currentIndex = status === 'IN_QUEUE' ? 1 : status === 'IN_PROGRESS' ? 2 : 3;
    return `<div class="job-progress">${stages.map((stage, index) => {
      let className = '';
      if (terminalError && index === 3) className = 'is-error';
      else if (status === 'DONE' || index < currentIndex) className = 'is-complete';
      else if (index === currentIndex) className = 'is-active';
      return `<div class="progress-step ${className}"><span class="progress-node">${className === 'is-complete' ? '✓' : index + 1}</span><strong>${escapeHtml(stage.title)}</strong><span>${escapeHtml(stage.detail)}</span></div>`;
    }).join('')}</div>`;
  }

  async function refreshJob(jobId) {
    try {
      const job = await api(`/api/jobs/${jobId}`);
      const index = state.jobs.findIndex(item => item.id === jobId);
      if (index >= 0) state.jobs[index] = job;
      else state.jobs.unshift(job);
      renderJobs();
      updateWorkflow();
      if (['DONE', 'FATAL', 'CANCELLED', 'RECONNECT_REQUIRED'].includes(job.status)) {
        stopPolling();
        toast('Feed 状态已更新', statusMeta(job.status).label, job.status === 'DONE' ? 'success' : 'danger');
      }
    } catch (error) {
      stopPolling();
      toast('状态更新失败', error.message, 'danger');
    }
  }

  function startPolling(jobId) {
    stopPolling();
    state.pollTimer = window.setInterval(() => refreshJob(jobId), 6000);
  }

  function stopPolling() {
    if (state.pollTimer) window.clearInterval(state.pollTimer);
    state.pollTimer = null;
  }

  function bindEvents() {
    $$('.nav-item').forEach(button => button.addEventListener('click', () => setView(button.dataset.viewTarget)));
    $$('.segment').forEach(button => button.addEventListener('click', () => selectRegion(button.dataset.region)));

    $('#refresh-button').addEventListener('click', async () => {
      if (state.view === 'jobs') await loadJobs();
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
      refreshIcons();
    }));

    $('#verify-auth-button').addEventListener('click', verifyAuth);
    $('#validate-account-button').addEventListener('click', validateAccount);
    $('#seller-id').addEventListener('input', () => {
      if (state.account) invalidateAccount();
      updateAccountButton();
      updateReview();
    });
    $('#marketplace-select').addEventListener('change', () => {
      if (state.account) invalidateAccount();
      updateAccountButton();
      updateReview();
    });

    $('#confirm-checkbox').addEventListener('change', updateSubmitButton);
    $('#confirmation-input').addEventListener('input', updateSubmitButton);
    $('#submit-feed-button').addEventListener('click', () => $('#submit-dialog').showModal());
    $('#confirm-submit-button').addEventListener('click', submitFeed);
  }

  async function init() {
    bindEvents();
    refreshIcons();
    updateWorkflow();
    updateSubmitButton();
    await Promise.all([loadServerStatus(), loadJobs()]);
  }

  init();
})();
