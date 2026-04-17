/* ═══════════════════════════════════════════════
   Panel NaiveProxy by RIXXX — Frontend App
   ═══════════════════════════════════════════════ */

'use strict';

// ─── STATE ───────────────────────────────────────
let currentPage = 'dashboard';
let ws = null;
let installRunning = false;
let deleteUserTarget = null;
let currentConfig = null;

// ─── INIT ─────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  checkAuth();

  // Login form
  document.getElementById('loginForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    await doLogin();
  });

  // Logout
  document.getElementById('logoutBtn').addEventListener('click', doLogout);

  // Nav items
  document.querySelectorAll('.nav-item').forEach(item => {
    item.addEventListener('click', (e) => {
      e.preventDefault();
      goToPage(item.dataset.page);
    });
  });

  // Refresh status button
  document.getElementById('refreshStatusBtn').addEventListener('click', () => {
    loadDashboard();
  });
});

// ─── AUTH ─────────────────────────────────────────
async function checkAuth() {
  try {
    const res = await fetch('/api/me');
    if (res.ok) {
      const data = await res.json();
      showApp(data.username);
    } else {
      showLogin();
    }
  } catch {
    showLogin();
  }
}

function showLogin() {
  document.getElementById('loginPage').classList.remove('hidden');
  document.getElementById('app').classList.add('hidden');
}

function showApp(username) {
  document.getElementById('loginPage').classList.add('hidden');
  document.getElementById('app').classList.remove('hidden');
  // Set username in sidebar
  if (username) {
    document.getElementById('sidebarUsername').textContent = username;
    document.getElementById('sidebarUserAvatar').textContent = username[0].toUpperCase();
  }
  goToPage('dashboard');
}

async function doLogin() {
  const username = document.getElementById('loginUsername').value.trim();
  const password = document.getElementById('loginPassword').value;
  const errEl = document.getElementById('loginError');
  const btn = document.querySelector('#loginForm button[type="submit"]');
  const btnText = btn.querySelector('.btn-text');
  const btnLoader = btn.querySelector('.btn-loader');

  if (!username || !password) {
    showAlert(errEl, 'Заполните все поля', 'error');
    return;
  }

  btn.disabled = true;
  btnText.classList.add('hidden');
  btnLoader.classList.remove('hidden');
  errEl.classList.add('hidden');

  try {
    const res = await fetch('/api/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password })
    });
    const data = await res.json();
    if (data.success) {
      showApp(username);
    } else {
      showAlert(errEl, data.message || 'Ошибка входа', 'error');
    }
  } catch {
    showAlert(errEl, 'Ошибка соединения с сервером', 'error');
  } finally {
    btn.disabled = false;
    btnText.classList.remove('hidden');
    btnLoader.classList.add('hidden');
  }
}

async function doLogout() {
  await fetch('/api/logout', { method: 'POST' });
  showLogin();
}

// ─── NAVIGATION ──────────────────────────────────
function goToPage(page) {
  currentPage = page;
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));

  const pageEl = document.getElementById(page + 'Page');
  if (pageEl) pageEl.classList.add('active');

  const navEl = document.querySelector(`.nav-item[data-page="${page}"]`);
  if (navEl) navEl.classList.add('active');

  if (page === 'dashboard') loadDashboard();
  if (page === 'users') loadUsers();
}

// ─── DASHBOARD ───────────────────────────────────
async function loadDashboard() {
  const statusEl = document.getElementById('serviceStatus');
  const domainEl = document.getElementById('serverDomain');
  const ipEl = document.getElementById('serverIp');
  const countEl = document.getElementById('usersCount');
  const notInstalled = document.getElementById('notInstalledMsg');
  const serviceBtns = document.getElementById('serviceBtns');
  const quickLinksEmpty = document.getElementById('quickLinksEmpty');
  const quickLinksList = document.getElementById('quickLinksList');

  statusEl.innerHTML = '<span class="dot dot-gray"></span> Загрузка...';

  try {
    const res = await fetch('/api/status');
    const data = await res.json();
    currentConfig = data;

    if (!data.installed) {
      statusEl.innerHTML = '<span class="dot dot-gray"></span> Не установлен';
      domainEl.textContent = '—';
      ipEl.textContent = '—';
      countEl.textContent = '0';
      notInstalled.classList.remove('hidden');
      serviceBtns.style.display = 'none';
      quickLinksEmpty.classList.remove('hidden');
      quickLinksList.classList.add('hidden');
    } else {
      const isRunning = data.status === 'running';
      statusEl.innerHTML = isRunning
        ? `<span class="dot dot-green"></span> Работает`
        : `<span class="dot dot-red"></span> Остановлен`;
      domainEl.textContent = data.domain || '—';
      ipEl.textContent = data.serverIp || '—';
      countEl.textContent = data.usersCount || '0';
      notInstalled.classList.add('hidden');
      serviceBtns.style.display = 'flex';

      // Quick links
      const usersRes = await fetch('/api/proxy-users');
      const usersData = await usersRes.json();
      if (usersData.users && usersData.users.length > 0) {
        quickLinksEmpty.classList.add('hidden');
        quickLinksList.classList.remove('hidden');
        quickLinksList.innerHTML = '';
        usersData.users.slice(0, 5).forEach(u => {
          const link = `naive+https://${u.username}:${u.password}@${data.domain}:443`;
          quickLinksList.innerHTML += `
            <div class="quick-link-item">
              <span style="min-width:70px;color:var(--text-primary);font-weight:600">${u.username}</span>
              <span style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${link}</span>
              <button class="quick-link-copy" onclick="copyText('${link}')">Копировать</button>
            </div>`;
        });
      } else {
        quickLinksEmpty.classList.remove('hidden');
        quickLinksList.classList.add('hidden');
      }
    }
  } catch (err) {
    statusEl.innerHTML = '<span class="dot dot-yellow"></span> Ошибка';
  }
}

async function serviceAction(action) {
  showToast(`Выполняем: ${action}...`, 'info');
  try {
    const res = await fetch(`/api/service/${action}`, { method: 'POST' });
    const data = await res.json();
    showToast(data.message, data.success ? 'success' : 'error');
    setTimeout(loadDashboard, 1500);
  } catch {
    showToast('Ошибка соединения', 'error');
  }
}

// ─── INSTALL ──────────────────────────────────────
function generatePassword() {
  const chars = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789@#$';
  let pwd = '';
  for (let i = 0; i < 20; i++) {
    pwd += chars[Math.floor(Math.random() * chars.length)];
  }
  document.getElementById('installPassword').value = pwd;
}

// Auto-generate password on install page load if empty
document.addEventListener('DOMContentLoaded', () => {
  generatePassword();
});

function startInstall() {
  if (installRunning) return;

  const domain = document.getElementById('installDomain').value.trim();
  const email = document.getElementById('installEmail').value.trim();
  const login = document.getElementById('installLogin').value.trim();
  const password = document.getElementById('installPassword').value.trim();
  const alertEl = document.getElementById('installAlert');

  if (!domain || !email || !login || !password) {
    showAlert(alertEl, '❌ Заполните все поля', 'error');
    return;
  }
  if (!domain.includes('.')) {
    showAlert(alertEl, '❌ Введите корректный домен (например: naive.yourdomain.com)', 'error');
    return;
  }
  if (!email.includes('@')) {
    showAlert(alertEl, '❌ Введите корректный email', 'error');
    return;
  }
  if (password.length < 8) {
    showAlert(alertEl, '❌ Пароль должен быть минимум 8 символов', 'error');
    return;
  }

  alertEl.classList.add('hidden');
  installRunning = true;

  // UI: show progress, hide done
  document.getElementById('installDone').classList.add('hidden');
  document.getElementById('installLog').innerHTML = '';
  document.getElementById('progressBar').style.width = '0%';
  document.getElementById('progressPercent').textContent = '0%';

  // Reset steps
  document.querySelectorAll('.install-step').forEach(s => {
    s.classList.remove('active', 'done');
  });

  // Disable button
  const btn = document.getElementById('startInstallBtn');
  btn.disabled = true;
  btn.innerHTML = `
    <svg class="spin" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
      <path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83"/>
    </svg>
    Установка...`;

  // Connect WebSocket
  const wsProto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${wsProto}//${location.host}`);

  ws.onopen = () => {
    ws.send(JSON.stringify({
      type: 'install',
      domain, email,
      adminLogin: login,
      adminPassword: password
    }));
  };

  ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    handleWsMessage(msg);
  };

  ws.onerror = () => {
    appendLog('❌ Ошибка WebSocket соединения', 'error');
    resetInstallBtn();
  };

  ws.onclose = () => {
    if (installRunning) {
      installRunning = false;
    }
  };
}

function handleWsMessage(msg) {
  if (msg.type === 'log') {
    appendLog(msg.text, msg.level);
    if (msg.step) activateStep(msg.step);
    if (msg.progress !== null && msg.progress !== undefined) {
      setProgress(msg.progress);
    }
  } else if (msg.type === 'install_done') {
    installRunning = false;
    setProgress(100);
    markStepDone('done');
    showInstallDone(msg.link);
    resetInstallBtn();
  } else if (msg.type === 'install_error') {
    installRunning = false;
    appendLog(`❌ ${msg.message}`, 'error');
    resetInstallBtn();
    showAlert(document.getElementById('installAlert'), `Ошибка установки: ${msg.message}`, 'error');
  }
}

function appendLog(text, level = 'info') {
  const terminal = document.getElementById('installLog');
  const line = document.createElement('div');
  line.className = `log-line log-${level}`;
  line.textContent = `› ${text}`;
  terminal.appendChild(line);
  terminal.scrollTop = terminal.scrollHeight;
}

function setProgress(pct) {
  document.getElementById('progressBar').style.width = pct + '%';
  document.getElementById('progressPercent').textContent = pct + '%';
}

let currentActiveStep = null;
function activateStep(stepName) {
  if (currentActiveStep && currentActiveStep !== stepName) {
    markStepDone(currentActiveStep);
  }
  const el = document.getElementById('step-' + stepName);
  if (el) {
    el.classList.add('active');
    el.classList.remove('done');
    currentActiveStep = stepName;
  }
}

function markStepDone(stepName) {
  const el = document.getElementById('step-' + stepName);
  if (el) {
    el.classList.remove('active');
    el.classList.add('done');
  }
}

function showInstallDone(link) {
  document.getElementById('doneLink').textContent = link || '';
  document.getElementById('installDone').classList.remove('hidden');
  // Mark all steps done
  document.querySelectorAll('.install-step').forEach(s => {
    s.classList.remove('active');
    s.classList.add('done');
  });
  showToast('✅ NaiveProxy успешно установлен!', 'success');
}

function copyLink() {
  const link = document.getElementById('doneLink').textContent;
  copyText(link);
}

function resetInstallBtn() {
  const btn = document.getElementById('startInstallBtn');
  btn.disabled = false;
  btn.innerHTML = `
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="16 16 12 12 8 16"/><line x1="12" y1="12" x2="12" y2="21"/><path d="M20.39 18.39A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.3"/></svg>
    Начать установку`;
}

// ─── USERS ───────────────────────────────────────
async function loadUsers() {
  const tbody = document.getElementById('usersTableBody');
  const table = document.getElementById('usersTable');
  const empty = document.getElementById('emptyUsers');

  try {
    const [usersRes, statusRes] = await Promise.all([
      fetch('/api/proxy-users'),
      fetch('/api/status')
    ]);
    const { users } = await usersRes.json();
    const status = await statusRes.json();

    if (!users || users.length === 0) {
      table.style.display = 'none';
      empty.style.display = 'flex';
      return;
    }

    table.style.display = 'table';
    empty.style.display = 'none';
    tbody.innerHTML = '';

    users.forEach((u, i) => {
      const link = status.installed && status.domain
        ? `naive+https://${u.username}:${u.password}@${status.domain}:443`
        : `(установите сервер)`;
      const date = u.createdAt ? new Date(u.createdAt).toLocaleDateString('ru') : '—';
      tbody.innerHTML += `
        <tr>
          <td>${i + 1}</td>
          <td class="td-login">${escapeHtml(u.username)}</td>
          <td class="td-pwd">${escapeHtml(u.password)}</td>
          <td class="td-link" title="${escapeHtml(link)}">
            ${status.installed ? `<span style="cursor:pointer" onclick="copyText('${escapeHtml(link)}')" title="Нажмите для копирования">${escapeHtml(link)}</span>` : '<span style="color:var(--text-muted)">Сервер не установлен</span>'}
          </td>
          <td>${date}</td>
          <td>
            ${status.installed ? `<button class="btn btn-outline btn-sm" onclick="copyText('${escapeHtml(link)}')" title="Копировать ссылку">
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
            </button>` : ''}
            <button class="btn btn-danger btn-sm" onclick="showDeleteModal('${escapeHtml(u.username)}')">
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6M14 11v6"/><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg>
            </button>
          </td>
        </tr>`;
    });
  } catch (err) {
    showToast('Ошибка загрузки пользователей', 'error');
  }
}

function showAddUserModal() {
  document.getElementById('newUserLogin').value = '';
  generateUserPassword();
  document.getElementById('addUserAlert').classList.add('hidden');
  openModal('addUserModal');
}

function generateUserPassword() {
  const chars = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  let pwd = '';
  for (let i = 0; i < 18; i++) pwd += chars[Math.floor(Math.random() * chars.length)];
  document.getElementById('newUserPassword').value = pwd;
}

async function addUser() {
  const username = document.getElementById('newUserLogin').value.trim();
  const password = document.getElementById('newUserPassword').value.trim();
  const alertEl = document.getElementById('addUserAlert');

  if (!username || !password) {
    showAlert(alertEl, 'Введите логин и пароль', 'error');
    return;
  }

  try {
    const res = await fetch('/api/proxy-users/add', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password })
    });
    const data = await res.json();
    if (data.success) {
      closeModal('addUserModal');
      showToast(`✅ Пользователь ${username} добавлен`, 'success');
      loadUsers();
    } else {
      showAlert(alertEl, data.message || 'Ошибка', 'error');
    }
  } catch {
    showAlert(alertEl, 'Ошибка соединения', 'error');
  }
}

function showDeleteModal(username) {
  deleteUserTarget = username;
  document.getElementById('deleteUserName').textContent = username;
  openModal('deleteUserModal');
}

async function confirmDeleteUser() {
  if (!deleteUserTarget) return;
  try {
    const res = await fetch(`/api/proxy-users/${encodeURIComponent(deleteUserTarget)}`, { method: 'DELETE' });
    const data = await res.json();
    if (data.success) {
      closeModal('deleteUserModal');
      showToast(`Пользователь ${deleteUserTarget} удалён`, 'success');
      deleteUserTarget = null;
      loadUsers();
    } else {
      showToast(data.message || 'Ошибка удаления', 'error');
    }
  } catch {
    showToast('Ошибка соединения', 'error');
  }
}

// ─── SETTINGS ────────────────────────────────────
async function changePassword() {
  const currentPwd = document.getElementById('currentPwd').value;
  const newPwd = document.getElementById('newPwd').value;
  const confirmPwd = document.getElementById('confirmPwd').value;
  const alertEl = document.getElementById('pwdChangeAlert');

  if (!currentPwd || !newPwd || !confirmPwd) {
    showAlert(alertEl, 'Заполните все поля', 'error');
    return;
  }
  if (newPwd !== confirmPwd) {
    showAlert(alertEl, 'Новые пароли не совпадают', 'error');
    return;
  }
  if (newPwd.length < 6) {
    showAlert(alertEl, 'Пароль должен быть минимум 6 символов', 'error');
    return;
  }

  try {
    const res = await fetch('/api/config/change-password', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ currentPassword: currentPwd, newPassword: newPwd })
    });
    const data = await res.json();
    if (data.success) {
      showAlert(alertEl, '✅ Пароль изменён', 'success');
      document.getElementById('currentPwd').value = '';
      document.getElementById('newPwd').value = '';
      document.getElementById('confirmPwd').value = '';
    } else {
      showAlert(alertEl, data.message || 'Ошибка', 'error');
    }
  } catch {
    showAlert(alertEl, 'Ошибка соединения', 'error');
  }
}

// ─── HELPERS ─────────────────────────────────────
function openModal(id) {
  document.getElementById(id).classList.remove('hidden');
}

function closeModal(id) {
  document.getElementById(id).classList.add('hidden');
}

// Close modal on backdrop click
document.querySelectorAll('.modal-overlay').forEach(overlay => {
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay) {
      overlay.classList.add('hidden');
    }
  });
});

function showAlert(el, message, type = 'error') {
  el.className = `alert alert-${type}`;
  el.textContent = message;
  el.classList.remove('hidden');
}

function copyText(text) {
  if (navigator.clipboard) {
    navigator.clipboard.writeText(text).then(() => {
      showToast('✅ Скопировано!', 'success');
    }).catch(() => fallbackCopy(text));
  } else {
    fallbackCopy(text);
  }
}

function fallbackCopy(text) {
  const ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  document.execCommand('copy');
  document.body.removeChild(ta);
  showToast('✅ Скопировано!', 'success');
}

let toastTimer = null;
let toastFadeTimer = null;
function showToast(message, type = 'info') {
  const toast = document.getElementById('toast');
  // Reset any pending fade
  if (toastTimer) clearTimeout(toastTimer);
  if (toastFadeTimer) clearTimeout(toastFadeTimer);
  toast.classList.remove('hidden');
  toast.style.opacity = '';
  toast.textContent = message;
  toast.className = `toast toast-${type}`;
  toastTimer = setTimeout(() => {
    toast.style.opacity = '0';
    toastFadeTimer = setTimeout(() => {
      toast.classList.add('hidden');
      toast.style.opacity = '';
    }, 220);
  }, 2800);
}

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
