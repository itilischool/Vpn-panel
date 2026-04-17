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

// Ensure data directory exists
const dataDir = path.join(__dirname, '../data');
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });

// Initialize config
function loadConfig() {
  if (!fs.existsSync(DATA_FILE)) {
    const defaultConfig = {
      installed: false,
      domain: '',
      email: '',
      serverIp: '',
      adminPassword: '',
      proxyUsers: []
    };
    fs.writeFileSync(DATA_FILE, JSON.stringify(defaultConfig, null, 2));
    return defaultConfig;
  }
  return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
}

function saveConfig(config) {
  fs.writeFileSync(DATA_FILE, JSON.stringify(config, null, 2));
}

function loadUsers() {
  if (!fs.existsSync(USERS_FILE)) {
    const defaultUsers = {
      admin: {
        password: bcrypt.hashSync('admin', 10),
        role: 'admin'
      }
    };
    fs.writeFileSync(USERS_FILE, JSON.stringify(defaultUsers, null, 2));
    return defaultUsers;
  }
  return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
}

function saveUsers(users) {
  fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2));
}

// Middleware
app.use(cors());
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(session({
  secret: 'naiveproxy-rixxx-secret-2024',
  resave: false,
  saveUninitialized: false,
  cookie: { secure: false, maxAge: 24 * 60 * 60 * 1000 }
}));
app.use(express.static(path.join(__dirname, '../public')));

// Auth middleware
function requireAuth(req, res, next) {
  if (req.session && req.session.authenticated) {
    return next();
  }
  res.status(401).json({ error: 'Unauthorized' });
}

// ─────────────────────────────────────────────
//  AUTH ROUTES
// ─────────────────────────────────────────────
app.post('/api/login', (req, res) => {
  const { username, password } = req.body;
  const users = loadUsers();
  const user = users[username];
  if (!user) return res.json({ success: false, message: 'Неверный логин или пароль' });
  if (!bcrypt.compareSync(password, user.password)) {
    return res.json({ success: false, message: 'Неверный логин или пароль' });
  }
  req.session.authenticated = true;
  req.session.username = username;
  req.session.role = user.role;
  res.json({ success: true });
});

app.post('/api/logout', (req, res) => {
  req.session.destroy();
  res.json({ success: true });
});

app.get('/api/me', requireAuth, (req, res) => {
  res.json({ username: req.session.username, role: req.session.role });
});

// ─────────────────────────────────────────────
//  CONFIG ROUTES
// ─────────────────────────────────────────────
app.get('/api/config', requireAuth, (req, res) => {
  const config = loadConfig();
  // Don't send passwords
  const safe = { ...config };
  res.json(safe);
});

app.post('/api/config/change-password', requireAuth, (req, res) => {
  const { currentPassword, newPassword } = req.body;
  if (!currentPassword || !newPassword) {
    return res.json({ success: false, message: 'Заполните все поля' });
  }
  if (newPassword.length < 6) {
    return res.json({ success: false, message: 'Новый пароль минимум 6 символов' });
  }
  const users = loadUsers();
  const user = users[req.session.username];
  if (!user) {
    return res.json({ success: false, message: 'Пользователь не найден' });
  }
  if (!bcrypt.compareSync(currentPassword, user.password)) {
    return res.json({ success: false, message: 'Текущий пароль неверен' });
  }
  // Hash and save new password
  users[req.session.username].password = bcrypt.hashSync(newPassword, 10);
  saveUsers(users);
  res.json({ success: true, message: 'Пароль успешно изменён' });
});

// ─────────────────────────────────────────────
//  PROXY USERS ROUTES
// ─────────────────────────────────────────────
app.get('/api/proxy-users', requireAuth, (req, res) => {
  const config = loadConfig();
  res.json({ users: config.proxyUsers || [] });
});

app.post('/api/proxy-users/add', requireAuth, (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) {
    return res.json({ success: false, message: 'Логин и пароль обязательны' });
  }
  const config = loadConfig();
  if (!config.proxyUsers) config.proxyUsers = [];
  
  // Check duplicate
  if (config.proxyUsers.find(u => u.username === username)) {
    return res.json({ success: false, message: 'Пользователь уже существует' });
  }
  
  config.proxyUsers.push({ username, password, createdAt: new Date().toISOString() });
  saveConfig(config);
  
  // If installed, update Caddyfile
  if (config.installed) {
    updateCaddyfile(config, res, () => {
      res.json({ success: true, link: `naive+https://${username}:${password}@${config.domain}:443` });
    });
  } else {
    res.json({ success: true, link: username + ':' + password });
  }
});

app.delete('/api/proxy-users/:username', requireAuth, (req, res) => {
  const { username } = req.params;
  const config = loadConfig();
  const before = (config.proxyUsers || []).length;
  config.proxyUsers = (config.proxyUsers || []).filter(u => u.username !== username);
  if (config.proxyUsers.length === before) {
    return res.json({ success: false, message: 'Пользователь не найден' });
  }
  saveConfig(config);
  
  if (config.installed) {
    updateCaddyfile(config, res, () => {
      res.json({ success: true });
    });
  } else {
    res.json({ success: true });
  }
});

// ─────────────────────────────────────────────
//  SERVER STATUS
// ─────────────────────────────────────────────
app.get('/api/status', requireAuth, (req, res) => {
  const config = loadConfig();
  if (!config.installed) {
    return res.json({ installed: false, status: 'not_installed' });
  }
  
  const child = spawn('systemctl', ['is-active', 'caddy']);
  let output = '';
  child.stdout.on('data', d => output += d.toString().trim());
  child.on('close', () => {
    const running = output.trim() === 'active';
    res.json({
      installed: true,
      status: running ? 'running' : 'stopped',
      domain: config.domain,
      serverIp: config.serverIp,
      email: config.email,
      usersCount: (config.proxyUsers || []).length
    });
  });
  child.on('error', () => {
    res.json({ installed: config.installed, status: 'unknown', domain: config.domain });
  });
});

app.post('/api/service/:action', requireAuth, (req, res) => {
  const { action } = req.params;
  if (!['start', 'stop', 'restart'].includes(action)) {
    return res.status(400).json({ error: 'Invalid action' });
  }
  const child = spawn('systemctl', [action, 'caddy']);
  child.on('close', (code) => {
    res.json({ success: code === 0, message: code === 0 ? `Caddy ${action} выполнен` : 'Ошибка управления сервисом' });
  });
  child.on('error', () => {
    res.json({ success: false, message: 'systemctl недоступен (вы не на сервере?)' });
  });
});

// ─────────────────────────────────────────────
//  INSTALL VIA WEBSOCKET
// ─────────────────────────────────────────────
wss.on('connection', (ws, req) => {
  ws.on('message', (message) => {
    try {
      const data = JSON.parse(message);
      if (data.type === 'install') {
        handleInstall(ws, data);
      }
    } catch (e) {
      ws.send(JSON.stringify({ type: 'error', message: 'Invalid message' }));
    }
  });
});

function sendLog(ws, text, step = null, progress = null, level = 'info') {
  ws.send(JSON.stringify({ type: 'log', text, step, progress, level }));
}

function updateCaddyfile(config, res, callback) {
  let basicAuthLines = '';
  if (config.proxyUsers && config.proxyUsers.length > 0) {
    basicAuthLines = config.proxyUsers
      .map(u => `    basic_auth ${u.username} ${u.password}`)
      .join('\n');
  }

  const caddyfileContent = `{
  order forward_proxy before file_server
}

:443, ${config.domain} {
  tls ${config.email}

  forward_proxy {
${basicAuthLines}
    hide_ip
    hide_via
    probe_resistance
  }

  file_server {
    root /var/www/html
  }
}
`;

  try {
    fs.writeFileSync('/etc/caddy/Caddyfile', caddyfileContent, 'utf8');
  } catch (e) {
    // Not running as root or Caddy not installed — skip silently
  }

  // Reload Caddy to apply new config
  const reload = spawn('bash', ['-c',
    'caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || systemctl restart caddy 2>/dev/null || true'
  ]);
  reload.on('close', () => { if (callback) callback(); });
  reload.on('error', () => { if (callback) callback(); });
}

function handleInstall(ws, data) {
  const { domain, email, adminLogin, adminPassword } = data;

  if (!domain || !email || !adminLogin || !adminPassword) {
    sendLog(ws, '❌ Заполните все поля!', null, null, 'error');
    ws.send(JSON.stringify({ type: 'install_error', message: 'Заполните все поля' }));
    return;
  }

  const config = loadConfig();
  config.domain = domain;
  config.email = email;
  if (!config.proxyUsers) config.proxyUsers = [];
  
  // Add first proxy user if not exists
  const existingUser = config.proxyUsers.find(u => u.username === adminLogin);
  if (!existingUser) {
    config.proxyUsers.push({ username: adminLogin, password: adminPassword, createdAt: new Date().toISOString() });
  }
  saveConfig(config);

  // Get server IP
  const getIp = spawn('bash', ['-c', "curl -4 -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'"]);
  let serverIp = '';
  getIp.stdout.on('data', d => serverIp += d.toString().trim());
  getIp.on('close', () => {
    config.serverIp = serverIp;
    saveConfig(config);
  });

  const scriptPath = path.join(__dirname, '../scripts/install_naiveproxy.sh');
  
  if (!fs.existsSync(scriptPath)) {
    sendLog(ws, '❌ Скрипт установки не найден!', null, null, 'error');
    ws.send(JSON.stringify({ type: 'install_error', message: 'install_naiveproxy.sh не найден' }));
    return;
  }

  sendLog(ws, '🚀 Начинаем установку NaiveProxy...', 'init', 2, 'info');

  const env = {
    ...process.env,
    NAIVE_DOMAIN: domain,
    NAIVE_EMAIL: email,
    NAIVE_LOGIN: adminLogin,
    NAIVE_PASSWORD: adminPassword,
    DEBIAN_FRONTEND: 'noninteractive'
  };

  const install = spawn('bash', [scriptPath], { env });

  install.stdout.on('data', (data) => {
    const lines = data.toString().split('\n').filter(l => l.trim());
    lines.forEach(line => {
      const parsed = parseLogLine(line);
      sendLog(ws, parsed.text, parsed.step, parsed.progress, parsed.level);
    });
  });

  install.stderr.on('data', (data) => {
    const lines = data.toString().split('\n').filter(l => l.trim());
    lines.forEach(line => {
      if (!line.includes('WARNING') && line.trim()) {
        sendLog(ws, line, null, null, 'warn');
      }
    });
  });

  install.on('close', (code) => {
    if (code === 0) {
      config.installed = true;
      saveConfig(config);
      sendLog(ws, '✅ Установка завершена успешно!', 'done', 100, 'success');
      ws.send(JSON.stringify({
        type: 'install_done',
        link: `naive+https://${adminLogin}:${adminPassword}@${domain}:443`
      }));
    } else {
      sendLog(ws, `❌ Установка завершилась с ошибкой (код ${code})`, null, null, 'error');
      ws.send(JSON.stringify({ type: 'install_error', message: `Exit code: ${code}` }));
    }
  });

  install.on('error', (err) => {
    sendLog(ws, `❌ Ошибка запуска скрипта: ${err.message}`, null, null, 'error');
    ws.send(JSON.stringify({ type: 'install_error', message: err.message }));
  });
}

function parseLogLine(line) {
  const stepMap = [
    { pattern: /STEP:1/, step: 'update', progress: 10, text: '📦 Обновление системы и зависимостей...' },
    { pattern: /STEP:2/, step: 'bbr', progress: 18, text: '⚡ Включение BBR...' },
    { pattern: /STEP:3/, step: 'firewall', progress: 25, text: '🔥 Настройка файрволла...' },
    { pattern: /STEP:4/, step: 'golang', progress: 35, text: '🐹 Установка Go...' },
    { pattern: /STEP:5/, step: 'caddy', progress: 55, text: '🔨 Сборка Caddy с naive-плагином (это займёт 3-7 мин)...' },
    { pattern: /STEP:6/, step: 'caddyfile', progress: 70, text: '📝 Создание конфигурации...' },
    { pattern: /STEP:7/, step: 'service', progress: 80, text: '⚙️ Настройка systemd сервиса...' },
    { pattern: /STEP:8/, step: 'start', progress: 90, text: '🟢 Запуск и включение автостарта...' },
    { pattern: /STEP:DONE/, step: 'done', progress: 100, text: '✅ Готово!' },
  ];

  for (const s of stepMap) {
    if (s.pattern.test(line)) {
      return { text: s.text, step: s.step, progress: s.progress, level: 'step' };
    }
  }

  if (/error|ошибка|failed|fail/i.test(line)) {
    return { text: line, step: null, progress: null, level: 'error' };
  }
  if (/warn|warning/i.test(line)) {
    return { text: line, step: null, progress: null, level: 'warn' };
  }
  if (/ok|done|success|✅|✓/i.test(line)) {
    return { text: line, step: null, progress: null, level: 'success' };
  }

  return { text: line, step: null, progress: null, level: 'info' };
}

// Serve index for all non-api routes (SPA)
app.get('*', (req, res) => {
  if (!req.path.startsWith('/api')) {
    res.sendFile(path.join(__dirname, '../public/index.html'));
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`\n╔══════════════════════════════════════╗`);
  console.log(`║   Panel NaiveProxy by RIXXX          ║`);
  console.log(`║   Running on http://0.0.0.0:${PORT}     ║`);
  console.log(`╚══════════════════════════════════════╝\n`);
});
