#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  Panel NaiveProxy by RIXXX — Полный установщик
#  Устанавливает: панель управления + NaiveProxy (Caddy + forwardproxy)
#  Запуск: bash <(curl -fsSL https://raw.githubusercontent.com/cwash797-cmd/Panel-NaiveProxy-by-RIXXX/main/install.sh)
#  Требования: Ubuntu 22.04 / 24.04, root, чистый сервер
# ═══════════════════════════════════════════════════════════════════════

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

REPO_URL="https://github.com/cwash797-cmd/Panel-NaiveProxy-by-RIXXX"
PANEL_DIR="/opt/naiveproxy-panel"
SERVICE_NAME="naiveproxy-panel"
INTERNAL_PORT=3000

# ── Colors ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

header() {
  clear
  echo ""
  echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${PURPLE}${BOLD}║        Panel NaiveProxy by RIXXX — Установщик           ║${RESET}"
  echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

log_step() { echo -e "\n${CYAN}${BOLD}▶ $1${RESET}"; }
log_ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
log_warn() { echo -e "${YELLOW}⚠  $1${RESET}"; }
log_err()  { echo -e "${RED}❌ $1${RESET}"; }
log_info() { echo -e "   ${BLUE}$1${RESET}"; }

header

# ── Root check ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  log_err "Запускайте скрипт от root: sudo bash install.sh"
  exit 1
fi

# ── OS check ────────────────────────────────────────────────────────────
if ! command -v apt-get &>/dev/null; then
  log_err "Поддерживается только Ubuntu/Debian"
  exit 1
fi

# ── Определяем IP ───────────────────────────────────────────────────────
SERVER_IP=$(curl -4 -s --connect-timeout 8 ifconfig.me 2>/dev/null \
  || curl -4 -s --connect-timeout 8 icanhazip.com 2>/dev/null \
  || hostname -I | awk '{print $1}')

echo -e "   ${BLUE}IP сервера: ${BOLD}${SERVER_IP}${RESET}"
echo ""

# ════════════════════════════════════════════════════════════════════════
# РАЗДЕЛ А — НАСТРОЙКИ (собираем всё сразу, потом устанавливаем)
# ════════════════════════════════════════════════════════════════════════

# ── A1. Способ доступа к панели управления ──────────────────────────────
echo -e "${BOLD}Выберите способ доступа к панели управления:${RESET}"
echo ""
echo -e "  ${CYAN}1)${RESET} Через Nginx на порту ${BOLD}8080${RESET} ${GREEN}(рекомендуется — порт 3000 не светится)${RESET}"
echo -e "  ${CYAN}2)${RESET} Напрямую на порту ${BOLD}3000${RESET} (проще, но порт виден)"
echo -e "  ${CYAN}3)${RESET} Через Nginx с доменом + HTTPS (максимальная защита)"
echo ""
read -rp "Ваш выбор [1/2/3]: " ACCESS_MODE
ACCESS_MODE="${ACCESS_MODE:-1}"

PANEL_DOMAIN=""
PANEL_EMAIL_SSL=""
if [[ "$ACCESS_MODE" == "3" ]]; then
  echo ""
  read -rp "  Домен для панели (например panel.yourdomain.com): " PANEL_DOMAIN
  read -rp "  Email для Let's Encrypt (SSL панели): " PANEL_EMAIL_SSL
fi

echo ""

# ── A2. Параметры NaiveProxy ─────────────────────────────────────────────
echo -e "${BOLD}Настройка NaiveProxy:${RESET}"
echo -e "${YELLOW}  ⚠  Убедитесь что A-запись домена уже указывает на ${SERVER_IP}${RESET}"
echo ""
read -rp "  Домен для NaiveProxy (например vpn.yourdomain.com): " NAIVE_DOMAIN
read -rp "  Email для Let's Encrypt (TLS): " NAIVE_EMAIL

# Генерируем credentials
NAIVE_LOGIN=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 16)
NAIVE_PASS=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)

echo ""
echo -e "${GREEN}  ✅ Сгенерированы credentials для NaiveProxy:${RESET}"
log_info "Логин:  ${NAIVE_LOGIN}"
log_info "Пароль: ${NAIVE_PASS}"
echo ""
echo -e "${YELLOW}  ⚠  Запомните эти данные! Они также будут показаны в конце.${RESET}"
echo ""
read -rp "Всё верно? Начать установку? [Enter / Ctrl+C для отмены]: " _CONFIRM

echo ""

# ════════════════════════════════════════════════════════════════════════
# РАЗДЕЛ Б — УСТАНОВКА
# ════════════════════════════════════════════════════════════════════════

# ── Б1. needrestart фикс + обновление системы ──────────────────────────
log_step "[1/14] Обновление системы..."

systemctl stop unattended-upgrades 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true
pkill -9 unattended-upgrades 2>/dev/null || true
sleep 1

rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
      /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true
dpkg --configure -a >/dev/null 2>&1 || true

# Фикс needrestart — главная причина зависания на Ubuntu 22.04+/24.04
if [ -f /etc/needrestart/needrestart.conf ]; then
  sed -i "s/#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" \
    /etc/needrestart/needrestart.conf 2>/dev/null || true
  sed -i "s/\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" \
    /etc/needrestart/needrestart.conf 2>/dev/null || true
  log_info "needrestart настроен (авто-режим)"
fi

# Только update + нужные пакеты — без upgrade всей системы
DEBIAN_FRONTEND=noninteractive apt-get update -qq \
  -o DPkg::Lock::Timeout=60 2>/dev/null || true

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  -o DPkg::Lock::Timeout=60 \
  curl wget git openssl ufw build-essential 2>/dev/null || true

log_ok "Система обновлена"

# ── Б2. Включение BBR ──────────────────────────────────────────────────
log_step "[2/14] Включение BBR (оптимизация скорости)..."

grep -qxF "net.core.default_qdisc=fq" /etc/sysctl.conf \
  || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf

grep -qxF "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf \
  || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

sysctl -p >/dev/null 2>&1 || true
log_ok "BBR включён"

# ── Б3. Установка Go ───────────────────────────────────────────────────
log_step "[3/14] Установка Go..."

rm -rf /usr/local/go

GO_VERSION=""
for attempt in 1 2 3; do
  GO_VERSION=$(curl -fsSL --connect-timeout 10 'https://go.dev/VERSION?m=text' 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
  [[ -n "$GO_VERSION" && "$GO_VERSION" == go* ]] && break
  sleep 2
done
[[ -z "$GO_VERSION" || "$GO_VERSION" != go* ]] && GO_VERSION="go1.22.5"

log_info "Загружаем ${GO_VERSION}..."
wget -q --show-progress --timeout=180 \
  "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" \
  -O /tmp/go.tar.gz 2>&1 || {
    log_err "Не удалось загрузить Go!"
    exit 1
  }

if [[ ! -s /tmp/go.tar.gz ]]; then
  log_err "Файл Go пустой, проверьте интернет"
  exit 1
fi

tar -C /usr/local -xzf /tmp/go.tar.gz
rm -f /tmp/go.tar.gz

export GOROOT=/usr/local/go
export GOPATH=/root/go
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH

grep -q "/usr/local/go/bin" /root/.profile 2>/dev/null || {
  echo 'export GOROOT=/usr/local/go' >> /root/.profile
  echo 'export GOPATH=/root/go' >> /root/.profile
  echo 'export PATH=$GOROOT/bin:$GOPATH/bin:$PATH' >> /root/.profile
}

GO_VER=$(/usr/local/go/bin/go version 2>/dev/null || echo "неизвестно")
log_ok "Go установлен: ${GO_VER}"

# ── Б4. Сборка Caddy с naive-плагином ─────────────────────────────────
log_step "[4/14] Сборка Caddy + naive forward proxy (3-7 минут, не прерывайте)..."

export GOROOT=/usr/local/go
export GOPATH=/root/go
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH
export TMPDIR=/root/tmp
export GOPROXY=https://proxy.golang.org,direct
mkdir -p /root/tmp /root/go

log_info "Установка xcaddy..."
/usr/local/go/bin/go install \
  github.com/caddyserver/xcaddy/cmd/xcaddy@latest 2>&1 | tail -2

if [[ ! -f /root/go/bin/xcaddy ]]; then
  log_err "xcaddy не установился! Проверьте интернет."
  exit 1
fi
log_info "xcaddy установлен, собираем Caddy..."

rm -f /root/caddy
cd /root

/root/go/bin/xcaddy build \
  --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive \
  2>&1 | while IFS= read -r line; do
    [[ -n "$line" ]] && echo "    $line"
  done

if [[ ! -f /root/caddy ]]; then
  log_err "Caddy не собран! Проверьте вывод выше."
  exit 1
fi

mv /root/caddy /usr/bin/caddy
chmod +x /usr/bin/caddy

CADDY_VER=$(/usr/bin/caddy version 2>/dev/null || echo "неизвестно")
log_ok "Caddy собран: ${CADDY_VER}"

# ── Б5. Камуфляжная HTML-страница ──────────────────────────────────────
log_step "[5/14] Создание камуфляжной страницы..."

mkdir -p /var/www/html /etc/caddy

cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Loading</title>
<style>body{background:#080808;height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}.bar{width:200px;height:3px;background:#151515;overflow:hidden;border-radius:2px;margin-bottom:25px}.fill{height:100%;width:40%;background:#fff;animation:slide 1.4s infinite ease-in-out}@keyframes slide{0%{transform:translateX(-100%)}50%{transform:translateX(50%)}100%{transform:translateX(200%)}}.t{color:#555;font-size:13px;letter-spacing:3px;font-weight:600}</style>
</head><body><div class="bar"><div class="fill"></div></div><div class="t">LOADING CONTENT</div></body></html>
HTMLEOF

log_ok "Камуфляжная страница создана в /var/www/html"

# ── Б6. Создание Caddyfile ─────────────────────────────────────────────
log_step "[6/14] Создание Caddyfile..."

{
  printf '{\n  order forward_proxy before file_server\n}\n\n'
  printf ':443, %s {\n' "${NAIVE_DOMAIN}"
  printf '  tls %s\n\n' "${NAIVE_EMAIL}"
  printf '  forward_proxy {\n'
  printf '    basic_auth %s %s\n' "${NAIVE_LOGIN}" "${NAIVE_PASS}"
  printf '    hide_ip\n'
  printf '    hide_via\n'
  printf '    probe_resistance\n'
  printf '  }\n\n'
  printf '  file_server {\n'
  printf '    root /var/www/html\n'
  printf '  }\n'
  printf '}\n'
} > /etc/caddy/Caddyfile

log_info "Валидация конфига..."
if /usr/bin/caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
  log_ok "Caddyfile создан и валиден"
else
  log_warn "Предупреждение валидации (продолжаем, SSL получим при первом старте)"
fi

# ── Б7. Systemd сервис Caddy ──────────────────────────────────────────
log_step "[7/14] Создание systemd сервиса Caddy..."

systemctl stop caddy 2>/dev/null || true
pkill -x caddy 2>/dev/null || true
sleep 1

cat > /etc/systemd/system/caddy.service << 'SVCEOF'
[Unit]
Description=Caddy with NaiveProxy (by RIXXX)
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable caddy >/dev/null 2>&1 || true
log_ok "Systemd сервис Caddy создан"

# ── Б8. Запуск Caddy ──────────────────────────────────────────────────
log_step "[8/14] Запуск Caddy (получение TLS сертификата)..."

systemctl start caddy 2>&1 || {
  log_warn "systemctl start вернул ошибку, пробуем fallback..."
  pkill -f "caddy run" 2>/dev/null || true
  sleep 1
  nohup /usr/bin/caddy run --config /etc/caddy/Caddyfile \
    > /var/log/caddy.log 2>&1 &
}

# Ждём до 20 секунд
CADDY_OK=0
for i in $(seq 1 20); do
  if systemctl is-active --quiet caddy 2>/dev/null || pgrep -x caddy >/dev/null 2>/dev/null; then
    log_ok "Caddy запущен (${i}с)"
    CADDY_OK=1
    break
  fi
  sleep 1
done

if [[ $CADDY_OK -eq 0 ]]; then
  log_warn "Caddy запускается медленно. Проверьте: systemctl status caddy"
  log_warn "Возможно SSL сертификат ещё получается (до 2 минут)"
fi

# ── Б9. Установка Node.js ─────────────────────────────────────────────
log_step "[9/14] Установка Node.js 20..."

if ! command -v node &>/dev/null || [[ "$(node -v 2>/dev/null | cut -d. -f1 | tr -d 'v')" -lt 18 ]]; then
  log_info "Скачиваем NodeSource репозиторий..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>&1 | grep -E "^##|^Running|error" || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" 2>/dev/null || true
fi

NODE_VER=$(node -v 2>/dev/null || echo "не найден")
log_ok "Node.js: ${NODE_VER}"

# ── Б10. Установка PM2 ────────────────────────────────────────────────
log_step "[10/14] Установка PM2..."

npm install -g pm2 --silent 2>&1 | grep -v "^npm warn" | tail -2 || true
PM2_VER=$(pm2 -v 2>/dev/null || echo "ok")
log_ok "PM2: ${PM2_VER}"

# ── Б11. Установка Nginx (если нужно) ────────────────────────────────
if [[ "$ACCESS_MODE" == "1" || "$ACCESS_MODE" == "3" ]]; then
  log_step "[11/14] Установка Nginx..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" 2>/dev/null || true
  log_ok "Nginx установлен"
fi

# ── Б12. Клонирование панели и зависимости ────────────────────────────
log_step "[12/14] Загрузка панели управления..."

if [[ -d "${PANEL_DIR}/.git" ]]; then
  log_warn "Панель уже установлена — обновляем..."
  cd "${PANEL_DIR}" && git pull --ff-only 2>&1 | tail -2 || true
else
  rm -rf "${PANEL_DIR}"
  git clone "${REPO_URL}" "${PANEL_DIR}" 2>&1 || {
    log_err "Не удалось клонировать репозиторий. Проверьте интернет."
    exit 1
  }
fi

cd "${PANEL_DIR}/panel"
npm install --omit=dev 2>&1 | grep -v "^npm warn" | tail -3 || true
mkdir -p "${PANEL_DIR}/panel/data"

log_ok "Панель загружена в ${PANEL_DIR}"

# ── Запись config.json ПОСЛЕ клонирования ─────────────────────────────
if [[ ! -f "${PANEL_DIR}/panel/data/config.json" ]]; then
  log_step "Сохранение конфигурации NaiveProxy в панель..."
  cat > "${PANEL_DIR}/panel/data/config.json" << CONFIGEOF
{
  "installed": true,
  "domain": "${NAIVE_DOMAIN}",
  "email": "${NAIVE_EMAIL}",
  "serverIp": "${SERVER_IP}",
  "adminPassword": "",
  "proxyUsers": [
    {
      "username": "${NAIVE_LOGIN}",
      "password": "${NAIVE_PASS}",
      "createdAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    }
  ]
}
CONFIGEOF
  log_ok "config.json записан → панель покажет установленный NaiveProxy"
else
  log_warn "config.json уже существует — не перезаписываем (сохраняем пользователей)"
fi

# ── Б13. Настройка UFW ────────────────────────────────────────────────
log_step "[13/14] Настройка файрволла UFW..."

ufw allow 22/tcp  >/dev/null 2>&1 || true
ufw allow 80/tcp  >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true

if [[ "$ACCESS_MODE" == "1" ]]; then
  ufw allow 8080/tcp >/dev/null 2>&1 || true
  ufw deny  ${INTERNAL_PORT}/tcp >/dev/null 2>&1 || true
  log_info "Порт 8080 открыт, порт 3000 закрыт снаружи"
elif [[ "$ACCESS_MODE" == "2" ]]; then
  ufw allow ${INTERNAL_PORT}/tcp >/dev/null 2>&1 || true
  log_info "Порт 3000 открыт (прямой доступ)"
elif [[ "$ACCESS_MODE" == "3" ]]; then
  ufw deny  ${INTERNAL_PORT}/tcp >/dev/null 2>&1 || true
  log_info "Порт 3000 закрыт снаружи (Nginx с доменом)"
fi

echo "y" | ufw enable >/dev/null 2>&1 || ufw --force enable >/dev/null 2>&1 || true
log_ok "Файрволл настроен"

# ── Б14. Запуск панели через PM2 ──────────────────────────────────────
log_step "[14/14] Запуск панели управления через PM2..."

cd "${PANEL_DIR}/panel"
pm2 delete "${SERVICE_NAME}" 2>/dev/null || true
sleep 1

pm2 start server/index.js \
  --name "${SERVICE_NAME}" \
  --time \
  --restart-delay=3000 \
  2>&1 | tail -3

pm2 save --force >/dev/null 2>&1 || true

PM2_STARTUP=$(pm2 startup systemd -u root --hp /root 2>/dev/null | grep "^sudo" || true)
[[ -n "$PM2_STARTUP" ]] && eval "$PM2_STARTUP" >/dev/null 2>&1 || true

sleep 2

if pm2 describe "${SERVICE_NAME}" 2>/dev/null | grep -q "online"; then
  log_ok "Панель запущена через PM2"
else
  log_warn "Проверьте: pm2 status && pm2 logs ${SERVICE_NAME}"
fi

# ── Настройка Nginx (если выбраны режимы 1 или 3) ────────────────────
if [[ "$ACCESS_MODE" == "1" ]]; then
  log_info "Настройка Nginx (8080 → 3000)..."

  cat > /etc/nginx/sites-available/naiveproxy-panel << NGINXEOF
server {
    listen 8080;
    server_name _;

    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    location / {
        proxy_pass http://127.0.0.1:${INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
    }
}
NGINXEOF

  ln -sf /etc/nginx/sites-available/naiveproxy-panel \
    /etc/nginx/sites-enabled/naiveproxy-panel 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  nginx -t >/dev/null 2>&1 && systemctl restart nginx && systemctl enable nginx >/dev/null 2>&1 || \
    log_warn "Nginx не запустился, проверьте: nginx -t"
  log_ok "Nginx настроен (8080 → 3000)"

elif [[ "$ACCESS_MODE" == "3" && -n "$PANEL_DOMAIN" ]]; then
  log_info "Настройка Nginx с доменом + SSL..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-certbot-nginx 2>/dev/null || true

  cat > /etc/nginx/sites-available/naiveproxy-panel << NGINXEOF
server {
    listen 80;
    server_name ${PANEL_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400;
    }
}
NGINXEOF

  ln -sf /etc/nginx/sites-available/naiveproxy-panel \
    /etc/nginx/sites-enabled/naiveproxy-panel 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  nginx -t >/dev/null 2>&1 && systemctl restart nginx && systemctl enable nginx >/dev/null 2>&1 || true

  certbot --nginx -d "${PANEL_DOMAIN}" \
    --email "${PANEL_EMAIL_SSL:-admin@${PANEL_DOMAIN}}" \
    --agree-tos --non-interactive 2>&1 | tail -4 \
    || log_warn "SSL для панели: проверьте DNS запись домена"

  log_ok "Nginx + SSL настроен для ${PANEL_DOMAIN}"
fi

# ════════════════════════════════════════════════════════════════════════
# ФИНАЛЬНЫЙ ВЫВОД
# ════════════════════════════════════════════════════════════════════════

NAIVE_LINK="naive+https://${NAIVE_LOGIN}:${NAIVE_PASS}@${NAIVE_DOMAIN}:443"

echo ""
echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   ✅  Panel NaiveProxy by RIXXX — Установка завершена!       ║${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   🌐  ПАНЕЛЬ УПРАВЛЕНИЯ                                      ║${RESET}"

if [[ "$ACCESS_MODE" == "1" ]]; then
  echo -e "${PURPLE}${BOLD}║   ➜   http://${SERVER_IP}:8080${RESET}"
elif [[ "$ACCESS_MODE" == "3" && -n "$PANEL_DOMAIN" ]]; then
  echo -e "${PURPLE}${BOLD}║   ➜   https://${PANEL_DOMAIN}${RESET}"
else
  echo -e "${PURPLE}${BOLD}║   ➜   http://${SERVER_IP}:${INTERNAL_PORT}${RESET}"
fi

echo -e "${PURPLE}${BOLD}║   👤  Логин:  admin     🔑  Пароль: admin                  ║${RESET}"
echo -e "${PURPLE}${BOLD}║   ⚠️   Сразу смените пароль в разделе «Настройки»!           ║${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   🔒  NAIVEPROXY                                             ║${RESET}"
echo -e "${PURPLE}${BOLD}║   Домен:  ${NAIVE_DOMAIN}${RESET}"
echo -e "${PURPLE}${BOLD}║   Логин:  ${NAIVE_LOGIN}${RESET}"
echo -e "${PURPLE}${BOLD}║   Пароль: ${NAIVE_PASS}${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   🔗  Ссылка подключения:${RESET}"
echo -e "${CYAN}   ${NAIVE_LINK}${RESET}"
echo -e "${PURPLE}${BOLD}║   📋  Karing → Импорт → Вставить из буфера обмена           ║${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   📌  Полезные команды:                                      ║${RESET}"
echo -e "${PURPLE}${BOLD}║   pm2 status                    — статус панели              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   pm2 logs ${SERVICE_NAME}      — логи панели         ║${RESET}"
echo -e "${PURPLE}${BOLD}║   systemctl status caddy        — статус NaiveProxy          ║${RESET}"
echo -e "${PURPLE}${BOLD}║   journalctl -u caddy -f        — логи Caddy                 ║${RESET}"
echo -e "${PURPLE}${BOLD}║   systemctl restart caddy       — перезапуск Caddy           ║${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${GREEN}${BOLD}   Удачи! Telegram: https://t.me/russian_paradice_vpn${RESET}"
echo ""
