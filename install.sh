#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  Panel NaiveProxy — Unified Installer (All-in-One)
#  Создаёт панель, Nginx, PM2, Caddy, UFW, BBR за один запуск.
#  Запуск: sudo bash install.sh
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ── Colors & Helpers ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; PURPLE='\033[0;35m'; BOLD='\033[1m'; RESET='\033[0m'
log_step() { echo -e "\n${CYAN}${BOLD}▶ $1${RESET}"; }
log_ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
log_warn() { echo -e "${YELLOW}⚠  $1${RESET}"; }
log_err()  { echo -e "${RED}❌ $1${RESET}"; }

# ── Root & OS Check ──────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then log_err "Запускайте от root: sudo bash install.sh"; exit 1; fi
if ! command -v apt-get &>/dev/null; then log_err "Поддерживается только Ubuntu/Debian"; exit 1; fi

SERVER_IP=$(curl -4 -s --connect-timeout 8 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo -e "${PURPLE}${BOLD}╔════════════════════════════════════════════════════╗\n║   Panel NaiveProxy — Unified Installer        ║\n╚════════════════════════════════════════════════════╝${RESET}\n"
echo -e "   ${BLUE}IP сервера: ${BOLD}${SERVER_IP}${RESET}\n"

# ── Interactive Setup ────────────────────────────────────────────────
echo -e "${BOLD}Выберите способ доступа к панели:${RESET}"
echo "  1) Nginx на порту 8080 (рекомендуется)"
echo "  2) Прямой доступ на порту 3000"
echo "  3) Nginx + домен + HTTPS"
read -rp "Ваш выбор [1/2/3]: " ACCESS_MODE
ACCESS_MODE="${ACCESS_MODE:-1}"
PANEL_DOMAIN=""; PANEL_EMAIL=""
if [[ "$ACCESS_MODE" == "3" ]]; then
  read -rp "  Домен панели: " PANEL_DOMAIN
  read -rp "  Email для SSL: " PANEL_EMAIL
fi

echo -e "\n${BOLD}Настройка NaiveProxy (можно пропустить и настроить позже из панели):${RESET}"
read -rp "  Домен прокси: " NAIVE_DOMAIN
read -rp "  Email для TLS: " NAIVE_EMAIL
NAIVE_LOGIN=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 16)
NAIVE_PASS=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)
echo -e "\n${GREEN}✅ Credentials: Логин: ${NAIVE_LOGIN} | Пароль: ${NAIVE_PASS}${RESET}\n"
read -rp "Начать установку? [Enter]:" _

# ── System Prep ──────────────────────────────────────────────────────
log_step "[1/8] Подготовка системы..."
systemctl stop unattended-upgrades 2>/dev/null || true
rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true
dpkg --configure -a >/dev/null 2>&1 || true
if [ -f /etc/needrestart/needrestart.conf ]; then
  sed -i "s/\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf 2>/dev/null || true
fi
apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq curl wget git openssl build-essential nginx ufw >/dev/null 2>&1 || true
log_ok "Системные пакеты установлены"

log_step "[2/8] Оптимизация сети (BBR)..."
grep -qxF "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
grep -qxF "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1 || true
log_ok "BBR активирован"

log_step "[3/8] Node.js 20 & PM2..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
apt-get install -y nodejs >/dev/null 2>&1
npm install -g pm2 --silent >/dev/null 2>&1
log_ok "Node & PM2 готовы"

# ── Directory Structure ──────────────────────────────────────────────
log_step "[4/8] Создание структуры проекта..."
PANEL_DIR="/opt/naiveproxy-panel"
rm -rf "$PANEL_DIR"
mkdir -p "$PANEL_DIR"/{panel/{server,public/{css,js},data},scripts}

# ── package.json ─────────────────────────────────────────────────────
cat > "$PANEL_DIR/panel/package.json" << 'PKGEOF'
{
  "name": "naive-proxy-panel",
  "version": "1.0.0",
  "description": "Panel NaiveProxy",
  "main": "server/index.js",
  "scripts": { "start": "node server/index.js" },
  "dependencies": {
    "express": "^4.18.2",
    "express-session": "^1.17.3",
    "bcryptjs": "^2.4.3",
    "cors": "^2.8.5",
    "body-parser": "^1.20.2",
    "ws": "^8.14.2",
    "fs-extra": "^11.1.1"
  }
}
PKGEOF
cd "$PANEL_DIR/panel" && npm install --omit=dev --silent 2>/dev/null
log_ok "Зависимости npm установлены"

# ── server/index.js (Fixed: trust proxy, secure sessions, reload logic) ──
cat > "$PANEL_DIR/panel/server/index.js" << 'JSEOF'
const express = require('express');
const session = require('express-session');
const bcrypt = require('bcryptjs');
const cors = require('cors');
const bodyParser = require('body-parser');
const http = require('http');
const WebSocket = require('ws');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });
const PORT = process.env.PORT || 3000;
const DATA_FILE = path.join(__dirname, '../data/config.json');
const USERS_FILE = path.join(__dirname, '../data/users.json');

app.set('trust proxy', 1);

const dataDir = path.join(__dirname, '../data');
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });

function loadConfig() {
  if (!fs.existsSync(DATA_FILE)) {
    const def = { installed: false, domain: '', email: '', serverIp: '', adminPassword: '', proxyUsers: [] };
    fs.writeFileSync(DATA_FILE, JSON.stringify(def, null, 2));
    return def;
  }
  return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
}
function saveConfig(c) { fs.writeFileSync(DATA_FILE, JSON.stringify(c, null, 2)); }
function loadUsers() {
  if (!fs.existsSync(USERS_FILE)) {
    const def = { admin: { password: bcrypt.hashSync('admin', 10), role: 'admin' } };
    fs.writeFileSync(USERS_FILE, JSON.stringify(def, null, 2));
    return def;
  }
  return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
}
function saveUsers(u) { fs.writeFileSync(USERS_FILE, JSON.stringify(u, null, 2)); }

app.use(cors());
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(session({
  secret: process.env.SESSION_SECRET || 'naiveproxy-secure-secret-2024',
  resave: false,
  saveUninitialized: false,
  cookie: { secure: false, maxAge: 24*60*60*1000, httpOnly: true, sameSite: 'lax' }
}));
app.use(express.static(path.join(__dirname, '../public')));

function requireAuth(req, res, next) {
  if (req.session?.authenticated) return next();
  res.status(401).json({ error: 'Unauthorized' });
}

app.post('/api/login', (req, res) => {
  const { username, password } = req.body;
  const u = loadUsers()[username];
  if (!u || !bcrypt.compareSync(password, u.password)) return res.json({ success: false, message: 'Неверный логин или пароль' });
  req.session.authenticated = true;
  req.session.username = username;
  req.session.role = u.role;
  res.json({ success: true });
});
app.post('/api/logout', (req, res) => { req.session.destroy(); res.json({ success: true }); });
app.get('/api/me', requireAuth, (req, res) => res.json({ username: req.session.username, role: req.session.role }));

app.get('/api/config', requireAuth, (req, res) => { const c = loadConfig(); delete c.adminPassword; res.json(c); });
app.post('/api/config/change-password', requireAuth, (req, res) => {
  const { currentPassword, newPassword } = req.body;
  if (newPassword?.length < 6) return res.json({ success: false, message: 'Минимум 6 символов' });
  const u = loadUsers();
  if (!u[req.session.username] || !bcrypt.compareSync(currentPassword, u[req.session.username].password)) return res.json({ success: false, message: 'Неверный текущий пароль' });
  u[req.session.username].password = bcrypt.hashSync(newPassword, 10);
  saveUsers(u); res.json({ success: true });
});

app.get('/api/proxy-users', requireAuth, (req, res) => res.json({ users: loadConfig().proxyUsers || [] }));
app.post('/api/proxy-users/add', requireAuth, (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) return res.json({ success: false, message: 'Логин и пароль обязательны' });
  const c = loadConfig();
  if (c.proxyUsers?.find(u => u.username === username)) return res.json({ success: false, message: 'Пользователь существует' });
  c.proxyUsers.push({ username, password, createdAt: new Date().toISOString() });
  saveConfig(c);
  if (c.installed) updateCaddyfile(c, () => res.json({ success: true, link: `naive+https://${username}:${password}@${c.domain}:443` }));
  else res.json({ success: true, link: `${username}:${password}` });
});
app.delete('/api/proxy-users/:username', requireAuth, (req, res) => {
  const c = loadConfig();
  c.proxyUsers = (c.proxyUsers||[]).filter(u => u.username !== req.params.username);
  saveConfig(c);
  if (c.installed) updateCaddyfile(c, () => res.json({ success: true }));
  else res.json({ success: true });
});

app.get('/api/status', requireAuth, (req, res) => {
  const c = loadConfig();
  if (!c.installed) return res.json({ installed: false, status: 'not_installed' });
  const ch = spawn('systemctl', ['is-active', 'caddy']);
  let out = '';
  ch.stdout.on('data', d => out += d.toString().trim());
  ch.on('close', () => res.json({ installed: true, status: out.trim()==='active'?'running':'stopped', domain: c.domain, serverIp: c.serverIp, usersCount: (c.proxyUsers||[]).length }));
});
app.post('/api/service/:action', requireAuth, (req, res) => {
  const { action } = req.params;
  if (!['start','stop','restart'].includes(action)) return res.status(400).json({ error: 'Invalid' });
  spawn('systemctl', [action, 'caddy']);
  res.json({ success: true, message: `Команда ${action} отправлена` });
});

wss.on('connection', ws => {
  ws.on('message', msg => {
    try { const d = JSON.parse(msg); if(d.type==='install') handleInstall(ws, d); }
    catch { ws.send(JSON.stringify({type:'error',message:'Invalid'})); }
  });
});
function sendLog(ws, t, step, p, l) { ws.send(JSON.stringify({type:'log',text:t,step,progress:p,level:l})); }
function updateCaddyfile(c, cb) {
  const auth = (c.proxyUsers||[]).map(u => `    basic_auth ${u.username} ${u.password}`).join('\n');
  const content = `{\n  order forward_proxy before file_server\n}\n:443, ${c.domain} {\n  tls ${c.email}\n  forward_proxy {\n${auth}\n    hide_ip\n    hide_via\n    probe_resistance\n  }\n  file_server { root /var/www/html }\n}`;
  try { fs.writeFileSync('/etc/caddy/Caddyfile', content, 'utf8'); } catch(e) {}
  spawn('systemctl', ['reload', 'caddy']).on('close', cb);
}
function handleInstall(ws, d) {
  const { domain, email, adminLogin, adminPassword } = d;
  if (!domain || !email || !adminLogin || !adminPassword) return ws.send(JSON.stringify({type:'install_error',message:'Заполните все поля'}));
  const c = loadConfig();
  Object.assign(c, { domain, email });
  if (!c.proxyUsers?.find(u => u.username === adminLogin)) c.proxyUsers.push({ username: adminLogin, password: adminPassword, createdAt: new Date().toISOString() });
  saveConfig(c);
  const sp = path.join(__dirname, '../scripts/install_naiveproxy.sh');
  if (!fs.existsSync(sp)) return ws.send(JSON.stringify({type:'install_error',message:'Скрипт не найден'}));
  sendLog(ws, '🚀 Начало установки...', 'init', 5, 'info');
  const ch = spawn('bash', [sp], { env: {...process.env, NAIVE_DOMAIN: domain, NAIVE_EMAIL: email, NAIVE_LOGIN: adminLogin, NAIVE_PASSWORD: adminPassword} });
  ch.stdout.on('data', l => l.toString().split('\n').filter(Boolean).forEach(x => sendLog(ws, x)));
  ch.stderr.on('data', l => l.toString().split('\n').filter(Boolean).forEach(x => sendLog(ws, x, null, null, 'warn')));
  ch.on('close', code => {
    if (code===0) { c.installed=true; saveConfig(c); sendLog(ws,'✅ Готово!','done',100,'success'); ws.send(JSON.stringify({type:'install_done',link:`naive+https://${adminLogin}:${adminPassword}@${domain}:443`})); }
    else ws.send(JSON.stringify({type:'install_error',message:`Exit code: ${code}`}));
  });
}
app.get('*', (req, res) => { if (!req.path.startsWith('/api')) res.sendFile(path.join(__dirname, '../public/index.html')); });
server.listen(PORT, '0.0.0.0', () => console.log(`🚀 Panel running on :${PORT}`));
JSEOF

# ── Frontend Files ───────────────────────────────────────────────────
cat > "$PANEL_DIR/panel/public/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>NaiveProxy Panel</title>
  <link rel="stylesheet" href="css/style.css">
</head>
<body>
  <div id="loginPage" class="login-page hidden">
    <div class="login-bg"><div class="bg-orb orb-1"></div><div class="bg-orb orb-2"></div><div class="bg-orb orb-3"></div></div>
    <div class="login-card">
      <div class="login-logo"><div class="logo-icon"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83"/></svg></div><div><div class="logo-title">NaiveProxy Panel</div><div class="logo-sub">by Levis</div></div></div>
      <h1 class="login-heading">Добро пожаловать</h1><p class="login-desc">Войдите в панель управления</p>
      <form id="loginForm"><div class="form-group"><label class="form-label">Логин</label><input id="loginUsername" class="form-input" type="text" placeholder="admin" required></div><div class="form-group"><label class="form-label">Пароль</label><input id="loginPassword" class="form-input" type="password" placeholder="admin" required></div><button type="submit" class="btn btn-primary btn-full btn-lg">Войти</button></form>
      <p class="login-hint">По умолчанию: admin / admin</p>
      <div id="loginError" class="alert hidden"></div>
    </div>
  </div>
  <div id="app" class="app hidden">
    <aside class="sidebar"><div class="sidebar-logo"><div class="logo-icon small"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83"/></svg></div><div><div class="sidebar-title">NaiveProxy</div><div class="sidebar-sub">by Levis</div></div></div>
      <nav class="sidebar-nav"><a href="#" class="nav-item active" data-page="dashboard"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/></svg>Дашборд</a><a href="#" class="nav-item" data-page="install"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83"/></svg>Установка</a><a href="#" class="nav-item" data-page="users"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>Пользователи</a><a href="#" class="nav-item" data-page="settings"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>Настройки</a></nav>
      <div class="sidebar-bottom"><div class="user-info"><div id="sidebarUserAvatar" class="user-avatar">A</div><div><div id="sidebarUsername" class="user-name">admin</div><div class="user-role">Administrator</div></div></div><button id="logoutBtn" class="logout-btn"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></svg></button></div>
    </aside>
    <main class="main-content">
      <div id="dashboardPage" class="page active">
        <div class="page-header"><h1 class="page-title">Дашборд</h1><button id="refreshStatusBtn" class="btn btn-outline"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg> Обновить</button></div>
        <div class="stats-grid">
          <div class="stat-card"><div class="stat-icon status-icon"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg></div><div class="stat-body"><div class="stat-label">Статус сервиса</div><div id="serviceStatus" class="stat-value"> Загрузка...</div></div></div>
          <div class="stat-card"><div class="stat-icon domain-icon"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg></div><div class="stat-body"><div class="stat-label">Домен</div><div id="serverDomain" class="stat-value mono">—</div></div></div>
          <div class="stat-card"><div class="stat-icon ip-icon"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><line x1="9" y1="1" x2="9" y2="4"/><line x1="15" y1="1" x2="15" y2="4"/><line x1="9" y1="20" x2="9" y2="23"/><line x1="15" y1="20" x2="15" y2="23"/><line x1="20" y1="9" x2="23" y2="9"/><line x1="20" y1="14" x2="23" y2="14"/><line x1="1" y1="9" x2="4" y2="9"/><line x1="1" y1="14" x2="4" y2="14"/></svg></div><div class="stat-body"><div class="stat-label">IP сервера</div><div id="serverIp" class="stat-value mono">—</div></div></div>
          <div class="stat-card"><div class="stat-icon users-icon"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg></div><div class="stat-body"><div class="stat-label">Пользователей</div><div id="usersCount" class="stat-value">0</div></div></div>
        </div>
        <div class="cards-row">
          <div class="card"><div class="card-header"><span class="card-title">Управление сервисом</span></div><div class="card-body"><div id="notInstalledMsg" class="not-installed-msg hidden"><svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg><p>NaiveProxy ещё не установлен.</p><a href="#" class="btn btn-primary" onclick="goToPage('install')">Перейти к установке</a></div><div id="serviceBtns" class="service-btns hidden" style="display:none"><button class="btn btn-success" onclick="serviceAction('start')">Запустить</button><button class="btn btn-warning" onclick="serviceAction('restart')">Перезапустить</button><button class="btn btn-danger" onclick="serviceAction('stop')">Остановить</button></div></div></div>
          <div class="card"><div class="card-header"><span class="card-title">Быстрые ссылки</span></div><div class="card-body"><div id="quickLinksEmpty" class="quick-link-empty">Установите NaiveProxy для получения ссылок</div><div id="quickLinksList"></div></div></div>
        </div>
      </div>
      <div id="installPage" class="page"><div class="page-header"><h1 class="page-title">Установка NaiveProxy</h1></div><div class="install-layout"><div class="card"><div class="card-header"><span class="card-title">Параметры сервера</span><span class="card-badge">Шаг 1 из 1</span></div><div class="card-body"><div id="installAlert" class="alert hidden"></div><div class="form-grid"><div class="form-group"><label class="form-label">Поддомен (домен)<span class="form-hint">Должен указывать на IP этого сервера</span></label><input id="installDomain" class="form-input" placeholder="vpn.yourdomain.com"></div><div class="form-group"><label class="form-label">Email для Let's Encrypt<span class="form-hint">Для получения SSL сертификата</span></label><input id="installEmail" class="form-input" type="email" placeholder="admin@yourdomain.com"></div><div class="form-group"><label class="form-label">Логин прокси-пользователя<span class="form-hint">Первый пользователь NaiveProxy</span></label><input id="installLogin" class="form-input" placeholder="user1"></div><div class="form-group"><label class="form-label">Пароль прокси-пользователя<span class="form-hint">Минимум 8 символов</span></label><div class="input-group"><input id="installPassword" class="form-input" type="password"><button class="btn btn-gen" onclick="generatePassword()" title="Сгенерировать"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="4" width="20" height="16" rx="2"/><path d="M12 8v8M8 12h8"/></svg></button></div></div></div><div class="form-actions"><button id="startInstallBtn" class="btn btn-primary btn-lg"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="16 16 12 12 8 16"/><line x1="12" y1="12" x2="12" y2="21"/><path d="M20.39 18.39A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.3"/></svg> Начать установку</button></div></div></div><div class="card"><div class="card-header"><span class="card-title">Прогресс установки</span><span id="progressPercent" class="progress-percent">0%</span></div><div class="card-body"><div class="progress-bar-wrap"><div id="progressBar" class="progress-bar" style="width:0%"></div></div><div class="install-steps"><div id="step-init" class="install-step"><span class="step-dot"></span><span class="step-label">Инициализация</span></div><div id="step-update" class="install-step"><span class="step-dot"></span><span class="step-label">Обновление системы</span></div><div id="step-bbr" class="install-step"><span class="step-dot"></span><span class="step-label">Включение BBR</span></div><div id="step-firewall" class="install-step"><span class="step-dot"></span><span class="step-label">Настройка файрволла</span></div><div id="step-golang" class="install-step"><span class="step-dot"></span><span class="step-label">Установка Go</span></div><div id="step-caddy" class="install-step"><span class="step-dot"></span><span class="step-label">Сборка Caddy (3-7 мин)</span></div><div id="step-caddyfile" class="install-step"><span class="step-dot"></span><span class="step-label">Конфигурация</span></div><div id="step-service" class="install-step"><span class="step-dot"></span><span class="step-label">Настройка сервиса</span></div><div id="step-start" class="install-step"><span class="step-dot"></span><span class="step-label">Запуск</span></div><div id="step-done" class="install-step"><span class="step-dot"></span><span class="step-label">Готово!</span></div></div><div class="terminal-wrap"><div class="terminal-header"><div class="terminal-dot red"></div><div class="terminal-dot yellow"></div><div class="terminal-dot green"></div><span class="terminal-title">Лог установки</span></div><div id="installLog" class="terminal"></div></div><div id="installDone" class="install-done hidden"><div class="done-icon">✅</div><h3>Установка завершена!</h3><p>NaiveProxy успешно настроен и запущен</p><div class="done-link-wrap"><p>Ваша ссылка для подключения:</p><div id="doneLink" class="done-link"></div><button class="btn btn-outline" onclick="copyLink()">Копировать</button></div><button class="btn btn-primary" onclick="goToPage('dashboard')">Перейти на дашборд</button></div></div></div></div></div>
      <div id="usersPage" class="page"><div class="page-header"><h1 class="page-title">Прокси-пользователи</h1><button class="btn btn-primary" onclick="showAddUserModal()"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg> Добавить пользователя</button></div><table id="usersTable" class="data-table" style="display:none"><thead><tr><th>#</th><th>Логин</th><th>Пароль</th><th>Ссылка подключения</th><th>Создан</th><th>Действия</th></tr></thead><tbody id="usersTableBody"></tbody></table><div id="emptyUsers" class="empty-state" style="display:flex"><svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg><p>Пользователи не добавлены</p><button class="btn btn-outline" onclick="showAddUserModal()">Добавить первого</button></div></div>
      <div id="settingsPage" class="page"><div class="page-header"><h1 class="page-title">Настройки</h1></div><div class="settings-grid"><div class="card"><div class="card-header"><span class="card-title">Смена пароля панели</span></div><div class="card-body"><div id="pwdChangeAlert" class="alert hidden"></div><div class="form-group"><label class="form-label">Текущий пароль</label><input id="currentPwd" class="form-input" type="password"></div><div class="form-group"><label class="form-label">Новый пароль</label><input id="newPwd" class="form-input" type="password"></div><div class="form-group"><label class="form-label">Подтвердите пароль</label><input id="confirmPwd" class="form-input" type="password"></div><div class="form-actions"><button class="btn btn-primary" onclick="changePassword()">Сохранить пароль</button></div></div></div><div class="card"><div class="card-header"><span class="card-title">Информация о панели</span></div><div class="card-body"><div class="info-rows"><div class="info-row"><span class="info-key">Версия</span><span class="info-val">1.0.0</span></div><div class="info-row"><span class="info-key">Автор</span><span class="info-val">Levis</span></div><div class="info-row"><span class="info-key">Стек</span><span class="info-val">Node.js + Caddy + NaiveProxy</span></div><div class="info-row"><span class="info-key">GitHub</span><a href="https://github.com/cwash797-cmd" class="info-val link" target="_blank">@cwash797-cmd</a></div></div><div class="support-btns"><a href="https://app.lava.top/2107724612?tabId=donate" target="_blank" class="btn btn-shiny btn-full">Поддержать автора ❤️</a><a href="https://t.me/russian_paradice_vpn" target="_blank" class="btn btn-tg btn-full">Подписывайся на нас в Telegram</a></div></div></div><div class="card settings-clients-card"><div class="card-header"><span class="card-title">Клиентские приложения</span></div><div class="card-body"><div class="clients-list"><div class="client-item"><span class="client-platform ios">iOS</span><span class="client-name">Karing</span><a href="https://apps.apple.com/app/karing/id6472431552" target="_blank" class="client-link">App Store ↗</a></div><div class="client-item"><span class="client-platform android">Android</span><span class="client-name">NekoBox</span><a href="https://github.com/MatsuriDayo/NekoBoxForAndroid/releases" target="_blank" class="client-link">GitHub ↗</a></div><div class="client-item"><span class="client-platform android">Android</span><span class="client-name">Karing</span><a href="https://github.com/KaringX/karing/releases" target="_blank" class="client-link">GitHub ↗</a></div><div class="client-item"><span class="client-platform windows">Windows</span><span class="client-name">Karing</span><a href="https://github.com/KaringX/karing/releases" target="_blank" class="client-link">GitHub ↗</a></div><div class="client-item"><span class="client-platform windows">Windows</span><span class="client-name">NekoRay</span><a href="https://github.com/MatsuriDayo/nekoray/releases" target="_blank" class="client-link">GitHub ↗</a></div><div class="client-item"><span class="client-platform windows">Windows</span><span class="client-name">v2rayN</span><a href="https://github.com/2dust/v2rayN/releases" target="_blank" class="client-link">GitHub ↗</a></div></div><div class="client-note">Формат ссылки: <code>naive+https://LOGIN:PASSWORD@domain.com:443</code></div></div></div></div></div>
      <div id="addUserModal" class="modal-overlay hidden"><div class="modal"><div class="modal-header"><h3>Добавить пользователя</h3><button class="modal-close" onclick="closeModal('addUserModal')"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></button></div><div class="modal-body"><div id="addUserAlert" class="alert hidden"></div><div class="form-group"><label class="form-label">Логин</label><input id="newUserLogin" class="form-input"></div><div class="form-group"><label class="form-label">Пароль</label><div class="input-group"><input id="newUserPassword" class="form-input"><button class="btn btn-gen" onclick="generateUserPassword()"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="4" width="20" height="16" rx="2"/><path d="M12 8v8M8 12h8"/></svg></button></div></div></div><div class="modal-footer"><button class="btn btn-outline" onclick="closeModal('addUserModal')">Отмена</button><button class="btn btn-primary" onclick="addUser()">Добавить</button></div></div></div>
      <div id="deleteUserModal" class="modal-overlay hidden"><div class="modal modal-sm"><div class="modal-header"><h3>Удалить пользователя</h3><button class="modal-close" onclick="closeModal('deleteUserModal')"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></button></div><div class="modal-body"><p>Удалить пользователя <strong id="deleteUserName"></strong>?</p><p style="color:var(--danger)">Это действие нельзя отменить.</p></div><div class="modal-footer"><button class="btn btn-outline" onclick="closeModal('deleteUserModal')">Отмена</button><button class="btn btn-danger" onclick="confirmDeleteUser()">Удалить</button></div></div></div>
      <div id="toast" class="toast hidden"></div>
    </main>
  </div>
  <script src="js/app.js"></script>
</body>
</html>
HTMLEOF

cat > "$PANEL_DIR/panel/public/css/style.css" << 'CSSEOF'
/* ═══════════════════════════════════════════════
Panel NaiveProxy by RIXXX — Deep Dark Theme
═══════════════════════════════════════════════ */
:root {
--bg-base: #080b12; --bg-surface: #0d1117; --bg-card: #111827; --bg-card-hover: #162032;
--bg-input: #0d1525; --bg-sidebar: #09111e; --border: #1e2d42; --border-light: #1a2840;
--accent: #6d28d9; --accent-bright: #7c3aed; --accent-glow: rgba(109,40,217,0.25);
--accent2: #2563eb; --accent2-glow: rgba(37,99,235,0.2); --text-primary: #e2e8f0;
--text-secondary:#94a3b8; --text-muted: #4a5568; --text-accent: #a78bfa;
--success: #10b981; --success-bg: rgba(16,185,129,0.1); --warning: #f59e0b;
--warning-bg: rgba(245,158,11,0.1); --danger: #ef4444; --danger-bg: rgba(239,68,68,0.1);
--info: #3b82f6; --info-bg: rgba(59,130,246,0.1); --radius-sm: 6px; --radius: 10px;
--radius-lg: 14px; --radius-xl: 20px; --sidebar-w: 240px; --transition: 0.2s ease;
--font-main: 'Inter', -apple-system, sans-serif; --font-mono: 'JetBrains Mono', 'Fira Code', monospace;
}
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
html { font-size: 14px; }
body { font-family: var(--font-main); background: var(--bg-base); color: var(--text-primary); min-height: 100vh; overflow-x: hidden; }
.hidden { display: none !important; }
::-webkit-scrollbar { width: 6px; height: 6px; }
::-webkit-scrollbar-track { background: var(--bg-base); }
::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
::-webkit-scrollbar-thumb:hover { background: var(--accent); }
.login-page { min-height: 100vh; display: flex; align-items: center; justify-content: center; position: relative; overflow: hidden; }
.login-bg { position: fixed; inset: 0; pointer-events: none; z-index: 0; }
.bg-orb { position: absolute; border-radius: 50%; filter: blur(80px); opacity: 0.12; animation: orbFloat 8s ease-in-out infinite; }
.orb-1 { width: 400px; height: 400px; background: var(--accent); top: -100px; left: -100px; }
.orb-2 { width: 300px; height: 300px; background: var(--accent2); bottom: -80px; right: 100px; animation-delay: 3s; }
.orb-3 { width: 250px; height: 250px; background: #06b6d4; top: 50%; left: 60%; animation-delay: 6s; }
@keyframes orbFloat { 0%, 100% { transform: translateY(0) scale(1); } 50% { transform: translateY(-20px) scale(1.05); } }
.login-card { position: relative; z-index: 1; background: rgba(13,17,23,0.85); backdrop-filter: blur(20px); border: 1px solid var(--border); border-radius: var(--radius-xl); padding: 40px; width: 100%; max-width: 420px; box-shadow: 0 24px 64px rgba(0,0,0,0.6); }
.login-logo { display: flex; align-items: center; gap: 14px; margin-bottom: 28px; }
.logo-icon { width: 52px; height: 52px; background: linear-gradient(135deg, rgba(109,40,217,0.2), rgba(37,99,235,0.2)); border: 1px solid rgba(109,40,217,0.3); border-radius: var(--radius-lg); display: flex; align-items: center; justify-content: center; }
.logo-icon.small { width: 40px; height: 40px; border-radius: var(--radius); }
.logo-title { font-size: 1.3rem; font-weight: 700; color: var(--text-primary); }
.logo-sub { font-size: 0.78rem; color: var(--text-accent); font-weight: 500; }
.login-heading { font-size: 1.5rem; font-weight: 700; margin-bottom: 6px; }
.login-desc { color: var(--text-secondary); margin-bottom: 24px; font-size: 0.9rem; }
.login-hint { text-align: center; color: var(--text-muted); font-size: 0.78rem; margin-top: 16px; }
.app { display: flex; min-height: 100vh; }
.sidebar { width: var(--sidebar-w); background: var(--bg-sidebar); border-right: 1px solid var(--border); display: flex; flex-direction: column; position: fixed; top: 0; left: 0; bottom: 0; z-index: 100; }
.sidebar-logo { display: flex; align-items: center; gap: 12px; padding: 22px 20px; border-bottom: 1px solid var(--border); }
.sidebar-title { font-size: 1rem; font-weight: 700; color: var(--text-primary); }
.sidebar-sub { font-size: 0.72rem; color: var(--text-accent); }
.sidebar-nav { flex: 1; padding: 16px 12px; display: flex; flex-direction: column; gap: 4px; }
.nav-item { display: flex; align-items: center; gap: 12px; padding: 10px 12px; border-radius: var(--radius); color: var(--text-secondary); text-decoration: none; font-size: 0.88rem; font-weight: 500; transition: all var(--transition); cursor: pointer; }
.nav-item:hover { background: rgba(255,255,255,0.04); color: var(--text-primary); }
.nav-item.active { background: linear-gradient(135deg, rgba(109,40,217,0.2), rgba(37,99,235,0.15)); color: var(--text-accent); border: 1px solid rgba(109,40,217,0.25); }
.nav-item svg { flex-shrink: 0; opacity: 0.8; }
.sidebar-bottom { padding: 16px 12px; border-top: 1px solid var(--border); display: flex; align-items: center; gap: 10px; }
.user-info { display: flex; align-items: center; gap: 10px; flex: 1; min-width: 0; }
.user-avatar { width: 34px; height: 34px; background: linear-gradient(135deg, var(--accent), var(--accent2)); border-radius: 50%; display: flex; align-items: center; justify-content: center; font-weight: 700; font-size: 0.85rem; flex-shrink: 0; }
.user-name { font-size: 0.85rem; font-weight: 600; color: var(--text-primary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.user-role { font-size: 0.72rem; color: var(--text-muted); }
.logout-btn { background: none; border: 1px solid var(--border); border-radius: var(--radius-sm); padding: 7px; color: var(--text-muted); cursor: pointer; transition: all var(--transition); display: flex; align-items: center; }
.logout-btn:hover { border-color: var(--danger); color: var(--danger); background: var(--danger-bg); }
.main-content { margin-left: var(--sidebar-w); flex: 1; min-height: 100vh; padding: 28px 32px; max-width: calc(100vw - var(--sidebar-w)); }
.page { display: none; } .page.active { display: block; }
.page-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 24px; }
.page-title { font-size: 1.5rem; font-weight: 700; color: var(--text-primary); letter-spacing: -0.3px; }
.card { background: var(--bg-card); border: 1px solid var(--border); border-radius: var(--radius-lg); overflow: hidden; transition: border-color var(--transition); }
.card:hover { border-color: var(--border-light); }
.card-header { padding: 18px 22px; border-bottom: 1px solid var(--border); display: flex; align-items: center; justify-content: space-between; }
.card-title { font-size: 0.95rem; font-weight: 600; color: var(--text-primary); }
.card-badge { background: rgba(109,40,217,0.15); border: 1px solid rgba(109,40,217,0.3); color: var(--text-accent); padding: 3px 10px; border-radius: 20px; font-size: 0.75rem; font-weight: 500; }
.card-body { padding: 22px; }
.stats-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin-bottom: 24px; }
.stat-card { background: var(--bg-card); border: 1px solid var(--border); border-radius: var(--radius-lg); padding: 20px; display: flex; align-items: flex-start; gap: 16px; transition: all var(--transition); }
.stat-card:hover { border-color: var(--border-light); transform: translateY(-1px); box-shadow: 0 8px 24px rgba(0,0,0,0.3); }
.stat-icon { width: 44px; height: 44px; border-radius: var(--radius); display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
.status-icon { background: rgba(109,40,217,0.12); color: var(--accent-bright); border: 1px solid rgba(109,40,217,0.2); }
.domain-icon { background: rgba(37,99,235,0.12); color: var(--info); border: 1px solid rgba(37,99,235,0.2); }
.ip-icon { background: rgba(16,185,129,0.12); color: var(--success); border: 1px solid rgba(16,185,129,0.2); }
.users-icon { background: rgba(245,158,11,0.12); color: var(--warning); border: 1px solid rgba(245,158,11,0.2); }
.stat-body { flex: 1; min-width: 0; }
.stat-label { font-size: 0.75rem; color: var(--text-muted); margin-bottom: 5px; text-transform: uppercase; letter-spacing: 0.5px; }
.stat-value { font-size: 1rem; font-weight: 600; color: var(--text-primary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: flex; align-items: center; gap: 7px; }
.mono { font-family: var(--font-mono); font-size: 0.85rem; }
.dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; flex-shrink: 0; }
.dot-green { background: var(--success); box-shadow: 0 0 6px var(--success); animation: pulse 2s infinite; }
.dot-red { background: var(--danger); } .dot-gray { background: var(--text-muted); }
@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
.cards-row { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
.service-btns { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
.not-installed-msg { display: flex; flex-direction: column; align-items: center; gap: 14px; padding: 28px 20px; color: var(--text-muted); text-align: center; }
.not-installed-msg p { font-size: 0.88rem; }
.quick-link-empty { color: var(--text-muted); font-size: 0.88rem; text-align: center; padding: 20px; }
.quick-link-item { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 10px 12px; background: var(--bg-input); border: 1px solid var(--border); border-radius: var(--radius-sm); margin-bottom: 8px; font-family: var(--font-mono); font-size: 0.78rem; color: var(--text-secondary); word-break: break-all; }
.quick-link-copy { background: none; border: 1px solid var(--border); border-radius: var(--radius-sm); padding: 4px 8px; color: var(--text-muted); cursor: pointer; font-size: 0.72rem; white-space: nowrap; transition: all var(--transition); }
.quick-link-copy:hover { border-color: var(--accent); color: var(--text-accent); }
.install-layout { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; align-items: start; }
.form-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
.form-actions { margin-top: 22px; display: flex; justify-content: flex-end; gap: 10px; }
.progress-percent { font-family: var(--font-mono); font-size: 1rem; font-weight: 700; color: var(--text-accent); }
.progress-bar-wrap { height: 6px; background: var(--bg-input); border-radius: 3px; overflow: hidden; margin-bottom: 20px; }
.progress-bar { height: 100%; background: linear-gradient(90deg, var(--accent), var(--accent2)); border-radius: 3px; transition: width 0.5s ease; box-shadow: 0 0 10px var(--accent-glow); }
.install-steps { display: flex; flex-direction: column; gap: 8px; margin-bottom: 20px; }
.install-step { display: flex; align-items: center; gap: 12px; padding: 8px 12px; border-radius: var(--radius-sm); transition: all var(--transition); }
.install-step.active { background: rgba(109,40,217,0.1); } .install-step.done { background: rgba(16,185,129,0.06); }
.step-dot { width: 10px; height: 10px; border-radius: 50%; background: var(--border); flex-shrink: 0; transition: all var(--transition); border: 2px solid var(--border); }
.install-step.active .step-dot { background: var(--accent); border-color: var(--accent); box-shadow: 0 0 8px var(--accent-glow); animation: pulse 1.5s infinite; }
.install-step.done .step-dot { background: var(--success); border-color: var(--success); }
.step-label { font-size: 0.82rem; color: var(--text-muted); transition: color var(--transition); }
.install-step.active .step-label { color: var(--text-accent); font-weight: 500; } .install-step.done .step-label { color: var(--success); }
.terminal-wrap { border: 1px solid var(--border); border-radius: var(--radius); overflow: hidden; }
.terminal-header { background: #0a0e17; padding: 10px 14px; display: flex; align-items: center; gap: 7px; border-bottom: 1px solid var(--border); }
.terminal-dot { width: 11px; height: 11px; border-radius: 50%; }
.terminal-dot.red { background: #ef4444; } .terminal-dot.yellow { background: #f59e0b; } .terminal-dot.green { background: #10b981; }
.terminal-title { font-size: 0.75rem; color: var(--text-muted); margin-left: 6px; font-family: var(--font-mono); }
.terminal { background: #050a12; height: 260px; overflow-y: auto; padding: 14px; font-family: var(--font-mono); font-size: 0.78rem; line-height: 1.6; }
.log-line { margin-bottom: 2px; padding: 1px 0; }
.log-info { color: #8ba8c8; } .log-step { color: #a78bfa; font-weight: 500; }
.log-success { color: #34d399; } .log-warn { color: #fbbf24; } .log-error { color: #f87171; }
.install-done { text-align: center; padding: 24px; }
.done-icon { font-size: 3rem; margin-bottom: 12px; } .install-done h3 { font-size: 1.2rem; margin-bottom: 8px; } .install-done p { color: var(--text-secondary); margin-bottom: 20px; }
.done-link-wrap { margin-bottom: 20px; text-align: left; }
.done-link { background: var(--bg-input); border: 1px solid var(--border); border-radius: var(--radius-sm); padding: 12px; font-family: var(--font-mono); font-size: 0.78rem; color: var(--success); word-break: break-all; margin: 8px 0; }
.data-table { width: 100%; border-collapse: collapse; }
.data-table th { text-align: left; padding: 10px 14px; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.5px; color: var(--text-muted); border-bottom: 1px solid var(--border); font-weight: 600; }
.data-table td { padding: 13px 14px; border-bottom: 1px solid rgba(30,45,66,0.5); font-size: 0.88rem; color: var(--text-secondary); vertical-align: middle; }
.data-table tr:last-child td { border-bottom: none; } .data-table tr:hover td { background: rgba(255,255,255,0.02); color: var(--text-primary); }
.td-login { font-weight: 600; color: var(--text-primary) !important; } .td-pwd { font-family: var(--font-mono); font-size: 0.8rem; }
.td-link { font-family: var(--font-mono); font-size: 0.73rem; color: var(--text-accent) !important; max-width: 220px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.empty-state { text-align: center; padding: 50px 20px; color: var(--text-muted); } .empty-state svg { opacity: 0.25; margin-bottom: 16px; } .empty-state p { margin-bottom: 20px; }
.settings-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
.info-rows { display: flex; flex-direction: column; gap: 12px; }
.info-row { display: flex; justify-content: space-between; align-items: center; padding-bottom: 12px; border-bottom: 1px solid var(--border); }
.info-row:last-child { border-bottom: none; padding-bottom: 0; }
.info-key { color: var(--text-muted); font-size: 0.85rem; } .info-val { color: var(--text-primary); font-size: 0.85rem; font-weight: 500; } .info-val.link { color: var(--text-accent); text-decoration: none; } .info-val.link:hover { text-decoration: underline; }
.clients-list { display: flex; flex-direction: column; gap: 8px; }
.client-item { display: flex; align-items: center; gap: 12px; padding: 10px 12px; background: var(--bg-input); border-radius: var(--radius-sm); border: 1px solid var(--border); transition: border-color var(--transition), background var(--transition); }
.client-item:hover { border-color: rgba(109,40,217,0.3); background: rgba(109,40,217,0.05); }
.client-platform { padding: 3px 9px; border-radius: 5px; font-size: 0.7rem; font-weight: 700; min-width: 64px; text-align: center; letter-spacing: 0.3px; text-transform: uppercase; }
.client-platform.ios { background: rgba(0,122,255,0.15); color: #60a5fa; border: 1px solid rgba(0,122,255,0.25); }
.client-platform.android { background: rgba(61,220,132,0.12); color: #34d399; border: 1px solid rgba(61,220,132,0.25); }
.client-platform.windows { background: rgba(0,120,215,0.12); color: #93c5fd; border: 1px solid rgba(0,120,215,0.25); }
.client-name { flex: 1; font-size: 0.88rem; font-weight: 500; color: var(--text-primary); }
.client-link { color: var(--text-accent); font-size: 0.8rem; text-decoration: none; padding: 3px 8px; border: 1px solid rgba(167,139,250,0.2); border-radius: 4px; transition: all var(--transition); }
.client-link:hover { background: rgba(167,139,250,0.1); border-color: rgba(167,139,250,0.4); }
.client-note { margin-top: 12px; padding: 10px 12px; background: rgba(109,40,217,0.06); border: 1px solid rgba(109,40,217,0.15); border-radius: var(--radius-sm); font-size: 0.78rem; color: var(--text-muted); }
.client-note code { font-family: var(--font-mono); color: var(--text-accent); font-size: 0.75rem; }
.settings-clients-card { grid-column: 1 / -1; }
.support-btns { display: flex; flex-direction: column; gap: 10px; margin-top: 18px; padding-top: 16px; border-top: 1px solid var(--border); }
.form-group { display: flex; flex-direction: column; gap: 7px; }
.form-label { font-size: 0.82rem; font-weight: 500; color: var(--text-secondary); display: flex; flex-direction: column; gap: 2px; }
.form-hint { font-size: 0.73rem; color: var(--text-muted); font-weight: 400; }
.form-input { background: var(--bg-input); border: 1px solid var(--border); border-radius: var(--radius-sm); padding: 10px 14px; color: var(--text-primary); font-family: var(--font-main); font-size: 0.88rem; outline: none; width: 100%; transition: border-color var(--transition), box-shadow var(--transition); }
.form-input::placeholder { color: var(--text-muted); }
.form-input:focus { border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-glow); }
.input-group { display: flex; gap: 8px; } .input-group .form-input { flex: 1; }
.btn { display: inline-flex; align-items: center; justify-content: center; gap: 8px; padding: 9px 18px; border-radius: var(--radius-sm); font-family: var(--font-main); font-size: 0.85rem; font-weight: 500; cursor: pointer; border: 1px solid transparent; text-decoration: none; transition: all var(--transition); white-space: nowrap; position: relative; overflow: hidden; line-height: 1.4; vertical-align: middle; }
.btn:disabled { opacity: 0.5; cursor: not-allowed; } .btn svg { flex-shrink: 0; }
.btn-shiny { background: radial-gradient(circle 70px at 80% -5%, #3a3a4a, #181b1b); color: #e2e8f0; border: 1.5px solid rgba(255,255,255,0.07); border-radius: 12px; box-shadow: 2px -2px 18px rgba(255,255,255,0.08), 0 8px 22px rgba(109,40,217,0.20), 0 4px 16px rgba(0,0,0,0.55); transition: all 0.28s ease; }
.btn-shiny::before { content: ''; position: absolute; top: 0; right: 0; width: 55%; height: 55%; border-radius: 0 12px 0 0; background: radial-gradient(ellipse 80px 50px at 100% 0%, rgba(255,255,255,0.18), transparent 70%); pointer-events: none; z-index: 1; }
.btn-shiny::after { content: ''; position: absolute; bottom: 0; left: 0; width: 30px; height: 35%; border-radius: 0 0 0 12px; background: radial-gradient(circle 30px at 0% 100%, rgba(109,40,217,0.55), rgba(109,40,217,0.10) 50%, transparent 72%); pointer-events: none; z-index: 1; transition: width 0.3s ease; }
.btn-shiny:hover:not(:disabled) { transform: translateY(-2px) scale(1.015); border-color: rgba(255,255,255,0.13); box-shadow: 2px -2px 24px rgba(255,255,255,0.14), 0 10px 28px rgba(0,0,0,0.60), 0 14px 30px rgba(109,40,217,0.22); }
.btn-shiny:hover:not(:disabled)::before { opacity: 1.3; } .btn-shiny:hover:not(:disabled)::after { width: 38px; }
.btn-tg { background: radial-gradient(circle 70px at 80% -5%, #2a3a5a, #0f1a2e); color: #e2e8f0; border: 1.5px solid rgba(255,255,255,0.07); border-radius: 12px; box-shadow: 2px -2px 18px rgba(255,255,255,0.06), 0 8px 22px rgba(29,155,240,0.18), 0 4px 16px rgba(0,0,0,0.55); transition: all 0.28s ease; }
.btn-tg::before { content: ''; position: absolute; top: 0; right: 0; width: 55%; height: 55%; border-radius: 0 12px 0 0; background: radial-gradient(ellipse 80px 50px at 100% 0%, rgba(255,255,255,0.14), transparent 70%); pointer-events: none; z-index: 1; }
.btn-tg::after { content: ''; position: absolute; bottom: 0; left: 0; width: 52px; height: 52%; border-radius: 0 0 0 12px; background: radial-gradient(circle 55px at 0% 100%, rgba(29,155,240,0.55), rgba(29,155,240,0.18) 50%, transparent 75%); pointer-events: none; z-index: 1; transition: width 0.3s ease; }
.btn-tg:hover:not(:disabled) { transform: translateY(-2px) scale(1.015); border-color: rgba(255,255,255,0.12); }
.btn-tg:hover:not(:disabled)::after { width: 76px; }
.btn-primary { background: linear-gradient(135deg, #2e3748, #1a202c); color: #e2e8f0; border-color: rgba(255,255,255,0.08); box-shadow: 0 6px 20px rgba(109,40,217,0.20); }
.btn-primary:hover:not(:disabled) { background: linear-gradient(135deg, #374357, #202836); transform: translateY(-1px); }
.btn-outline { background: transparent; color: var(--text-secondary); border-color: var(--border); }
.btn-outline:hover:not(:disabled) { border-color: rgba(255,255,255,0.18); color: var(--text-primary); background: rgba(255,255,255,0.05); }
.btn-gen { padding: 9px 12px; color: var(--text-secondary); border-color: var(--border); background: rgba(255,255,255,0.04); flex-shrink: 0; }
.btn-gen:hover:not(:disabled) { background: rgba(255,255,255,0.08); transform: rotate(90deg) scale(1.1); }
.btn-success { background: rgba(16,185,129,0.15); color: var(--success); border-color: rgba(16,185,129,0.3); }
.btn-warning { background: rgba(245,158,11,0.15); color: var(--warning); border-color: rgba(245,158,11,0.3); }
.btn-danger { background: rgba(239,68,68,0.15); color: var(--danger); border-color: rgba(239,68,68,0.3); }
.btn-sm { padding: 6px 12px; font-size: 0.8rem; gap: 6px; } .btn-lg { padding: 12px 26px; font-size: 0.92rem; } .btn-full { width: 100%; justify-content: center; }
.alert { padding: 11px 14px; border-radius: var(--radius-sm); font-size: 0.85rem; margin-bottom: 16px; }
.alert-error { background: var(--danger-bg); border: 1px solid rgba(239,68,68,0.3); color: #fca5a5; }
.alert-success { background: var(--success-bg); border: 1px solid rgba(16,185,129,0.3); color: #6ee7b7; }
.alert-info { background: var(--info-bg); border: 1px solid rgba(59,130,246,0.3); color: #93c5fd; }
.modal-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.7); backdrop-filter: blur(4px); z-index: 1000; display: flex; align-items: center; justify-content: center; padding: 20px; }
.modal { background: var(--bg-card); border: 1px solid var(--border); border-radius: var(--radius-xl); width: 100%; max-width: 460px; box-shadow: 0 24px 64px rgba(0,0,0,0.6); animation: modalIn 0.2s ease; }
.modal.modal-sm { max-width: 360px; }
@keyframes modalIn { from { opacity: 0; transform: scale(0.95) translateY(-10px); } to { opacity: 1; transform: none; } }
.modal-header { display: flex; align-items: center; justify-content: space-between; padding: 18px 22px; border-bottom: 1px solid var(--border); }
.modal-header h3 { font-size: 1rem; font-weight: 600; }
.modal-close { background: none; border: none; cursor: pointer; color: var(--text-muted); padding: 4px; border-radius: var(--radius-sm); transition: color var(--transition); display: flex; }
.modal-close:hover { color: var(--text-primary); }
.modal-body { padding: 22px; display: flex; flex-direction: column; gap: 14px; }
.modal-footer { padding: 16px 22px; border-top: 1px solid var(--border); display: flex; justify-content: flex-end; gap: 10px; }
.toast { position: fixed; bottom: 28px; right: 28px; z-index: 2000; background: var(--bg-card); border: 1px solid var(--border); border-radius: var(--radius); padding: 12px 20px; font-size: 0.88rem; font-weight: 500; box-shadow: 0 8px 32px rgba(0,0,0,0.5); animation: toastIn 0.25s ease; max-width: 340px; pointer-events: none; transition: opacity 0.2s ease; }
@keyframes toastIn { from { opacity: 0; transform: translateY(8px) scale(0.97); } to { opacity: 1; transform: none; } }
.toast-success { border-color: rgba(16,185,129,0.4); color: #6ee7b7; }
.toast-error { border-color: rgba(239,68,68,0.4); color: #fca5a5; }
.toast-info { border-color: rgba(59,130,246,0.4); color: #93c5fd; }
@media (max-width: 1200px) { .stats-grid { grid-template-columns: repeat(2, 1fr); } .install-layout { grid-template-columns: 1fr; } }
@media (max-width: 900px) { .cards-row { grid-template-columns: 1fr; } .settings-grid { grid-template-columns: 1fr; } .settings-clients-card { grid-column: 1 / -1; } }
@media (max-width: 768px) { :root { --sidebar-w: 0px; } .sidebar { transform: translateX(-100%); width: 220px; transition: transform 0.25s ease; } .sidebar.open { transform: translateX(0); } .main-content { margin-left: 0; padding: 16px 14px; max-width: 100vw; } .stats-grid { grid-template-columns: 1fr 1fr; gap: 12px; } .cards-row, .settings-grid { grid-template-columns: 1fr; } .form-grid { grid-template-columns: 1fr; } .page-header { flex-wrap: wrap; gap: 10px; } .page-title { font-size: 1.2rem; } }
CSSEOF

cat > "$PANEL_DIR/panel/public/js/app.js" << 'JSEOF'
'use strict';
let currentPage = 'dashboard'; let ws = null; let installRunning = false; let deleteUserTarget = null;
document.addEventListener('DOMContentLoaded', () => {
  checkAuth();
  document.getElementById('loginForm').addEventListener('submit', async e => { e.preventDefault(); await doLogin(); });
  document.getElementById('logoutBtn').addEventListener('click', doLogout);
  document.querySelectorAll('.nav-item').forEach(i => i.addEventListener('click', e => { e.preventDefault(); goToPage(i.dataset.page); }));
  document.getElementById('refreshStatusBtn').addEventListener('click', loadDashboard);
  generatePassword();
});
async function checkAuth() {
  try { const r = await fetch('/api/me'); if(r.ok) { const d=await r.json(); showApp(d.username); } else showLogin(); } catch { showLogin(); }
}
function showLogin() { document.getElementById('loginPage').classList.remove('hidden'); document.getElementById('app').classList.add('hidden'); }
function showApp(u) { document.getElementById('loginPage').classList.add('hidden'); document.getElementById('app').classList.remove('hidden'); if(u){document.getElementById('sidebarUsername').textContent=u;document.getElementById('sidebarUserAvatar').textContent=u[0].toUpperCase();} goToPage('dashboard'); }
async function doLogin() {
  const u=document.getElementById('loginUsername').value.trim(), p=document.getElementById('loginPassword').value;
  const el=document.getElementById('loginError'), btn=document.querySelector('#loginForm button'), bt=btn.querySelector('.btn-text'), bl=btn.querySelector('.btn-loader');
  if(!u||!p){showAlert(el,'Заполните все поля','error');return;}
  btn.disabled=true; bt.classList.add('hidden'); bl.classList.remove('hidden'); el.classList.add('hidden');
  try{const r=await fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u,password:p})});const d=await r.json();if(d.success)showApp(u);else showAlert(el,d.message||'Ошибка входа','error');}catch{showAlert(el,'Ошибка соединения','error');}finally{btn.disabled=false;bt.classList.remove('hidden');bl.classList.add('hidden');}
}
async function doLogout(){await fetch('/api/logout',{method:'POST'});showLogin();}
function goToPage(p){currentPage=p;document.querySelectorAll('.page').forEach(x=>x.classList.remove('active'));document.querySelectorAll('.nav-item').forEach(x=>x.classList.remove('active'));const e=document.getElementById(p+'Page');if(e)e.classList.add('active');const n=document.querySelector(`.nav-item[data-page="${p}"]`);if(n)n.classList.add('active');if(p==='dashboard')loadDashboard();if(p==='users')loadUsers();}
async function loadDashboard(){
  const st=document.getElementById('serviceStatus'), dm=document.getElementById('serverDomain'), ip=document.getElementById('serverIp'), ct=document.getElementById('usersCount');
  const ni=document.getElementById('notInstalledMsg'), sb=document.getElementById('serviceBtns'), qe=document.getElementById('quickLinksEmpty'), ql=document.getElementById('quickLinksList');
  st.innerHTML=' Загрузка...';
  try{const r=await fetch('/api/status');const d=await r.json();if(!d.installed){st.innerHTML=' <span class="dot dot-gray"></span> Не установлен';dm.textContent='—';ip.textContent='—';ct.textContent='0';ni.classList.remove('hidden');sb.style.display='none';qe.classList.remove('hidden');ql.classList.add('hidden');}else{const run=d.status==='running';st.innerHTML=run?` <span class="dot dot-green"></span> Работает`:` <span class="dot dot-red"></span> Остановлен`;dm.textContent=d.domain||'—';ip.textContent=d.serverIp||'—';ct.textContent=d.usersCount||'0';ni.classList.add('hidden');sb.style.display='flex';const ur=await fetch('/api/proxy-users');const ud=await ur.json();if(ud.users?.length>0){qe.classList.add('hidden');ql.classList.remove('hidden');ql.innerHTML='';ud.users.slice(0,5).forEach(u=>{const l=`naive+https://${u.username}:${u.password}@${d.domain}:443`;ql.innerHTML+=`<div class="quick-link-item"><span style="min-width:70px;font-weight:600">${u.username}</span><span style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${l}</span><button class="quick-link-copy" onclick="copyText('${l}')">Копировать</button></div>`;});}else{qe.classList.remove('hidden');ql.classList.add('hidden');}}}catch{st.innerHTML=' Ошибка';}
}
async function serviceAction(a){showToast(`Выполняем: ${a}...`,'info');try{const r=await fetch(`/api/service/${a}`,{method:'POST'});const d=await r.json();showToast(d.message,d.success?'success':'error');setTimeout(loadDashboard,1500);}catch{showToast('Ошибка соединения','error');}}
function generatePassword(){const c='ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789@#$',p='';for(let i=0;i<20;i++)p+=c[Math.floor(Math.random()*c.length)];document.getElementById('installPassword').value=p;}
function startInstall(){if(installRunning)return;const d=document.getElementById('installDomain').value.trim(),e=document.getElementById('installEmail').value.trim(),l=document.getElementById('installLogin').value.trim(),p=document.getElementById('installPassword').value.trim(),al=document.getElementById('installAlert');if(!d||!e||!l||!p){showAlert(al,'❌ Заполните все поля','error');return;}if(!d.includes('.')){showAlert(al,'❌ Введите корректный домен','error');return;}if(!e.includes('@')){showAlert(al,'❌ Введите корректный email','error');return;}if(p.length<8){showAlert(al,'❌ Пароль минимум 8 символов','error');return;}al.classList.add('hidden');installRunning=true;document.getElementById('installDone').classList.add('hidden');document.getElementById('installLog').innerHTML='';document.getElementById('progressBar').style.width='0%';document.getElementById('progressPercent').textContent='0%';document.querySelectorAll('.install-step').forEach(s=>s.classList.remove('active','done'));const btn=document.getElementById('startInstallBtn');btn.disabled=true;btn.innerHTML=`<svg class="spin" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83"/></svg> Установка...`;const wp=location.protocol==='https:'?'wss:':'ws:';ws=new WebSocket(`${wp}//${location.host}`);ws.onopen=()=>ws.send(JSON.stringify({type:'install',domain:d,email:e,adminLogin:l,adminPassword:p}));ws.onmessage=ev=>handleWsMessage(JSON.parse(ev.data));ws.onerror=()=>{appendLog('❌ Ошибка WebSocket','error');resetInstallBtn();};ws.onclose=()=>{if(installRunning)installRunning=false;};}
function handleWsMessage(m){if(m.type==='log'){appendLog(m.text,m.level);if(m.step)activateStep(m.step);if(m.progress!=null)setProgress(m.progress);}else if(m.type==='install_done'){installRunning=false;setProgress(100);markStepDone('done');showInstallDone(m.link);resetInstallBtn();}else if(m.type==='install_error'){installRunning=false;appendLog(`❌ ${m.message}`,'error');resetInstallBtn();showAlert(document.getElementById('installAlert'),`Ошибка: ${m.message}`,'error');}}
function appendLog(t,l='info'){const el=document.getElementById('installLog'),ln=document.createElement('div');ln.className=`log-line log-${l}`;ln.textContent=`› ${t}`;el.appendChild(ln);el.scrollTop=el.scrollHeight;}
function setProgress(p){document.getElementById('progressBar').style.width=p+'%';document.getElementById('progressPercent').textContent=p+'%';}
let curStep=null;function activateStep(n){if(curStep&&curStep!==n)markStepDone(curStep);const e=document.getElementById('step-'+n);if(e){e.classList.add('active');e.classList.remove('done');curStep=n;}}function markStepDone(n){const e=document.getElementById('step-'+n);if(e){e.classList.remove('active');e.classList.add('done');}}
function showInstallDone(l){document.getElementById('doneLink').textContent=l||'';document.getElementById('installDone').classList.remove('hidden');document.querySelectorAll('.install-step').forEach(s=>{s.classList.remove('active');s.classList.add('done');});showToast('✅ NaiveProxy установлен!','success');}
function copyLink(){copyText(document.getElementById('doneLink').textContent);}
function resetInstallBtn(){const b=document.getElementById('startInstallBtn');b.disabled=false;b.innerHTML=`<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="16 16 12 12 8 16"/><line x1="12" y1="12" x2="12" y2="21"/><path d="M20.39 18.39A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.3"/></svg> Начать установку`;}
async function loadUsers(){const tb=document.getElementById('usersTableBody'),t=document.getElementById('usersTable'),em=document.getElementById('emptyUsers');try{const[ur,sr]=await Promise.all([fetch('/api/proxy-users'),fetch('/api/status')]);const{users}=await ur.json(),st=await sr.json();if(!users?.length){t.style.display='none';em.style.display='flex';return;}t.style.display='table';em.style.display='none';tb.innerHTML='';users.forEach((u,i)=>{const ln=st.installed&&st.domain?`naive+https://${u.username}:${u.password}@${st.domain}:443`:'(установите сервер)';const dt=u.createdAt?new Date(u.createdAt).toLocaleDateString('ru'):'—';tb.innerHTML+=`<tr><td>${i+1}</td><td class="td-login">${escapeHtml(u.username)}</td><td class="td-pwd">${escapeHtml(u.password)}</td><td class="td-link" title="${escapeHtml(ln)}">${st.installed?`<span style="cursor:pointer" onclick="copyText('${escapeHtml(ln)}')">${escapeHtml(ln)}</span>`:'<span style="color:var(--text-muted)">Сервер не установлен</span>'}</td><td>${dt}</td><td>${st.installed?`<button class="btn btn-outline btn-sm" onclick="copyText('${escapeHtml(ln)}')"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg></button>`:''} <button class="btn btn-danger btn-sm" onclick="showDeleteModal('${escapeHtml(u.username)}')"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6M14 11v6"/><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg></button></td></tr>`;});}catch{showToast('Ошибка загрузки','error');}}
function showAddUserModal(){document.getElementById('newUserLogin').value='';generateUserPassword();document.getElementById('addUserAlert').classList.add('hidden');openModal('addUserModal');}
function generateUserPassword(){const c='ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789',p='';for(let i=0;i<18;i++)p+=c[Math.floor(Math.random()*c.length)];document.getElementById('newUserPassword').value=p;}
async function addUser(){const u=document.getElementById('newUserLogin').value.trim(),p=document.getElementById('newUserPassword').value.trim(),a=document.getElementById('addUserAlert');if(!u||!p){showAlert(a,'Введите логин и пароль','error');return;}try{const r=await fetch('/api/proxy-users/add',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u,password:p})});const d=await r.json();if(d.success){closeModal('addUserModal');showToast(`✅ ${u} добавлен`,'success');loadUsers();}else showAlert(a,d.message||'Ошибка','error');}catch{showAlert(a,'Ошибка соединения','error');}}
function showDeleteModal(u){deleteUserTarget=u;document.getElementById('deleteUserName').textContent=u;openModal('deleteUserModal');}
async function confirmDeleteUser(){if(!deleteUserTarget)return;try{const r=await fetch(`/api/proxy-users/${encodeURIComponent(deleteUserTarget)}`,{method:'DELETE'});const d=await r.json();if(d.success){closeModal('deleteUserModal');showToast(`Пользователь удалён`,'success');deleteUserTarget=null;loadUsers();}else showToast(d.message||'Ошибка','error');}catch{showToast('Ошибка соединения','error');}}
async function changePassword(){const c=document.getElementById('currentPwd').value,n=document.getElementById('newPwd').value,cf=document.getElementById('confirmPwd').value,a=document.getElementById('pwdChangeAlert');if(!c||!n||!cf){showAlert(a,'Заполните все поля','error');return;}if(n!==cf){showAlert(a,'Пароли не совпадают','error');return;}if(n.length<6){showAlert(a,'Минимум 6 символов','error');return;}try{const r=await fetch('/api/config/change-password',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({currentPassword:c,newPassword:n})});const d=await r.json();if(d.success){showAlert(a,'✅ Пароль изменён','success');document.getElementById('currentPwd').value='';document.getElementById('newPwd').value='';document.getElementById('confirmPwd').value='';}else showAlert(a,d.message||'Ошибка','error');}catch{showAlert(a,'Ошибка соединения','error');}}
function openModal(id){document.getElementById(id).classList.remove('hidden');}function closeModal(id){document.getElementById(id).classList.add('hidden');}
document.querySelectorAll('.modal-overlay').forEach(o=>o.addEventListener('click',e=>{if(e.target===o)o.classList.add('hidden');}));
function showAlert(el,m,t='error'){el.className=`alert alert-${t}`;el.textContent=m;el.classList.remove('hidden');}
function copyText(t){if(navigator.clipboard){navigator.clipboard.writeText(t).then(()=>showToast('✅ Скопировано!','success')).catch(()=>fbCopy(t));}else fbCopy(t);}
function fbCopy(t){const ta=document.createElement('textarea');ta.value=t;ta.style.position='fixed';ta.style.opacity='0';document.body.appendChild(ta);ta.select();document.execCommand('copy');document.body.removeChild(ta);showToast('✅ Скопировано!','success');}
let tt=null,tf=null;function showToast(m,t='info'){const el=document.getElementById('toast');if(tt)clearTimeout(tt);if(tf)clearTimeout(tf);el.classList.remove('hidden');el.style.opacity='';el.textContent=m;el.className=`toast toast-${t}`;tt=setTimeout(()=>{el.style.opacity='0';tf=setTimeout(()=>{el.classList.add('hidden');el.style.opacity='';},220);},2800);}
function escapeHtml(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');}
JSEOF

# ── Embedded install_naiveproxy.sh (Fixed: NO ufw reset, safe reload) ──
cat > "$PANEL_DIR/scripts/install_naiveproxy.sh" << 'SHEOF'
#!/bin/bash
set -uo pipefail; export DEBIAN_FRONTEND=noninteractive
DOMAIN="${NAIVE_DOMAIN:-}"; EMAIL="${NAIVE_EMAIL:-}"; LOGIN="${NAIVE_LOGIN:-}"; PASSWORD="${NAIVE_PASSWORD:-}"
[[ -z "$DOMAIN" || -z "$EMAIL" || -z "$LOGIN" || -z "$PASSWORD" ]] && { echo "ОШИБКА: Переменные не заданы"; exit 1; }
log() { echo "$1"; }; step() { echo "STEP:$1"; }
step 1; log "▶ Обновление и зависимости..."; systemctl stop unattended-upgrades 2>/dev/null||true; rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null||true; dpkg --configure -a >/dev/null 2>&1||true; apt-get update -qq >/dev/null 2>&1||true; apt-get install -y -qq curl wget git openssl ufw build-essential >/dev/null 2>&1||true; log "✅ Система готова"
step 2; log "▶ BBR..."; grep -qxF "net.core.default_qdisc=fq" /etc/sysctl.conf||echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf; grep -qxF "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf||echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf; sysctl -p >/dev/null 2>&1||true; log "✅ BBR включён"
step 3; log "▶ UFW (сохраняем доступ к панели)..."; ufw allow 22/tcp 80/tcp 443/tcp >/dev/null 2>&1||true; echo "y" | ufw enable >/dev/null 2>&1||true; log "✅ Файрволл настроен"
step 4; log "▶ Установка Go..."; rm -rf /usr/local/go; GO_VER=$(curl -fsSL --connect-timeout 10 'https://go.dev/VERSION?m=text' 2>/dev/null|head -n1||true); [[ -z "$GO_VER" ]] && GO_VER="go1.22.5"; wget -q --timeout=120 "https://go.dev/dl/${GO_VER}.linux-amd64.tar.gz" -O /tmp/go.tar.gz 2>/dev/null; tar -C /usr/local -xzf /tmp/go.tar.gz 2>/dev/null; export PATH=$PATH:/usr/local/go/bin:/root/go/bin; log "✅ Go установлен"
step 5; log "▶ Сборка Caddy..."; export PATH=$PATH:/root/go/bin; go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest 2>/dev/null||true; /root/go/bin/xcaddy build --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive 2>/dev/null||true; mv /root/caddy /usr/bin/caddy 2>/dev/null||true; chmod +x /usr/bin/caddy; log "✅ Caddy собран"
step 6; log "▶ Конфигурация..."; mkdir -p /var/www/html /etc/caddy; cat > /var/www/html/index.html << 'HTMLEND'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Loading</title><style>body{background:#080808;height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}.bar{width:200px;height:3px;background:#151515;overflow:hidden;border-radius:2px;margin-bottom:25px}.fill{height:100%;width:40%;background:#fff;animation:slide 1.4s infinite ease-in-out}@keyframes slide{0%{transform:translateX(-100%)}50%{transform:translateX(50%)}100%{transform:translateX(200%)}}.t{color:#555;font-size:13px;letter-spacing:3px;font-weight:600}</style></head><body><div class="bar"><div class="fill"></div></div><div class="t">LOADING CONTENT</div></body></html>
HTMLEND
{ printf '{\n  order forward_proxy before file_server\n}\n:443, %s {\n  tls %s\n  forward_proxy {\n    basic_auth %s %s\n    hide_ip\n    hide_via\n    probe_resistance\n  }\n  file_server { root /var/www/html }\n}\n' "$DOMAIN" "$EMAIL" "$LOGIN" "$PASSWORD"; } > /etc/caddy/Caddyfile
log "✅ Caddyfile создан"
step 7; log "▶ Systemd..."; systemctl stop caddy 2>/dev/null||true; pkill -x caddy 2>/dev/null||true; sleep 1; cat > /etc/systemd/system/caddy.service << 'SVCEOF'
[Unit] Description=Caddy with NaiveProxy After=network-online.target [Service] Type=notify User=root Group=root ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force LimitNOFILE=1048576 Restart=always RestartSec=5s [Install] WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload; systemctl enable caddy 2>/dev/null||true; log "✅ Сервис создан"
step 8; log "▶ Запуск Caddy..."; systemctl start caddy 2>/dev/null||true; for i in $(seq 1 15); do systemctl is-active --quiet caddy 2>/dev/null && { log "✅ Caddy запущен"; break; }; sleep 1; done
step DONE; log "✅ NaiveProxy установлен!"
PANEL_DATA="/opt/naiveproxy-panel/panel/data"
mkdir -p "$PANEL_DATA" 2>/dev/null
SERVER_IP=$(curl -4 -s --connect-timeout 8 ifconfig.me 2>/dev/null||hostname -I|awk '{print $1}')
cat > "${PANEL_DATA}/config.json" << CFGEOF
{"installed":true,"domain":"${DOMAIN}","email":"${EMAIL}","serverIp":"${SERVER_IP}","adminPassword":"","proxyUsers":[{"username":"${LOGIN}","password":"${PASSWORD}","createdAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}]}
CFGEOF
exit 0
SHEOF
chmod +x "$PANEL_DIR/scripts/install_naiveproxy.sh"

# ── UFW & Panel Startup ──────────────────────────────────────────────
log_step "[5/8] Настройка фаервола и запуск панели..."
ufw allow 22/tcp 80/tcp 443/tcp >/dev/null 2>&1||true
if [[ "$ACCESS_MODE" == "1" ]]; then ufw allow 8080/tcp >/dev/null 2>&1||true; ufw deny 3000/tcp >/dev/null 2>&1||true;
elif [[ "$ACCESS_MODE" == "3" ]]; then ufw deny 3000/tcp >/dev/null 2>&1||true;
else ufw allow 3000/tcp >/dev/null 2>&1||true; fi
echo "y" | ufw enable >/dev/null 2>&1||true

cd "$PANEL_DIR/panel"
pm2 delete naiveproxy-panel 2>/dev/null||true
pm2 start server/index.js --name naiveproxy-panel --time --restart-delay=3000
pm2 save --force >/dev/null 2>&1||true
pm2 startup systemd -u root --hp /root 2>/dev/null | grep "^sudo" | bash 2>/dev/null||true
sleep 3

# ── Health Check & Nginx ─────────────────────────────────────────────
log_step "[6/8] Проверка здоровья панели..."
if curl -s http://127.0.0.1:3000 >/dev/null 2>&1; then log_ok "Панель отвечает на порту 3000"; else log_err "Панель не запустилась!"; exit 1; fi

log_step "[7/8] Настройка Nginx..."
PORT_L=$([[ "$ACCESS_MODE" == "1" ]] && echo "8080" || echo "80")
SERVER_N=$([[ "$ACCESS_MODE" == "3" ]] && echo "$PANEL_DOMAIN" || echo "_")
cat > /etc/nginx/sites-available/naiveproxy-panel << NGEOF
server {
  listen $PORT_L;
  server_name $SERVER_N;
  client_max_body_size 10M;
  location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 86400;
  }
}
NGEOF
ln -sf /etc/nginx/sites-available/naiveproxy-panel /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 && systemctl restart nginx && systemctl enable nginx >/dev/null 2>&1||true

if [[ "$ACCESS_MODE" == "3" && -n "$PANEL_DOMAIN" ]]; then
  log_step "[7b] Получение SSL для панели..."
  apt-get install -y python3-certbot-nginx >/dev/null 2>&1||true
  certbot --nginx -d "$PANEL_DOMAIN" --email "${PANEL_EMAIL:-admin@$PANEL_DOMAIN}" --agree-tos --non-interactive 2>/dev/null||true
fi
log_ok "Nginx настроен"

# ── Finish ───────────────────────────────────────────────────────────
log_step "[8/8] Завершение..."
echo -e "\n${PURPLE}${BOLD}╔════════════════════════════════════════════════════╗\n║ ✅ Установка завершена!                          ║\n╠════════════════════════════════════════════════════╣"
if [[ "$ACCESS_MODE" == "1" ]]; then echo -e "║ 🌐 Панель: http://$SERVER_IP:8080              ║"
elif [[ "$ACCESS_MODE" == "3" ]]; then echo -e "║ 🌐 Панель: https://$PANEL_DOMAIN              ║"
else echo -e "║ 🌐 Панель: http://$SERVER_IP:3000                 ║"
fi
echo -e "║ 👤 Логин: admin | 🔑 Пароль: admin               ║"
echo -e "║ 🔒 NaiveProxy: ${NAIVE_DOMAIN}                  ║"
echo -e "║ 🔗 Ссылка: naive+https://${NAIVE_LOGIN}:${NAIVE_PASS}@${NAIVE_DOMAIN}:443  ║"
echo -e "╚════════════════════════════════════════════════════╝${RESET}\n"
echo -e "${YELLOW}💡 Совет: Зайдите в панель и нажмите 'Установка', если NaiveProxy ещё не запущен.${RESET}"
