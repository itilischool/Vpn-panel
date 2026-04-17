# Panel NaiveProxy by RIXXX

> Веб-панель управления для быстрой установки и управления NaiveProxy на VPS

---

## 🚀 Быстрая установка панели

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/cwash797-cmd/Panel-NaiveProxy-by-RIXXX/main/install.sh)
```

После установки панель будет доступна по адресу:
```
http://YOUR_SERVER_IP:3000
```

**Логин по умолчанию:** `admin` / `admin` — **смените сразу!**

---

## 📋 Требования к серверу

- Ubuntu 22.04 / 24.04 или Debian 11 / 12
- Поддомен с A-записью на IP сервера (например `naive.yourdomain.com`)
- Открытые порты: 22, 80, 443, 3000
- Минимум 1 GB RAM (для сборки Caddy — временно нужно 512 MB)

---

## 🎛️ Возможности панели

| Функция | Описание |
|---------|----------|
| 🟢 **Установка в 2 клика** | Вводите домен + email + логин/пароль — панель сама поднимает весь стек |
| 👥 **Управление пользователями** | Добавление и удаление прокси-пользователей с авто-обновлением конфига |
| 📊 **Дашборд** | Статус сервиса, IP сервера, домен, кол-во пользователей |
| 🔗 **Ссылки подключения** | Готовые `naive+https://...` ссылки для всех клиентов |
| 🔄 **Управление сервисом** | Старт / стоп / рестарт Caddy прямо из браузера |
| 🔒 **Смена пароля панели** | Безопасное управление доступом |

---

## 🔄 Процесс установки NaiveProxy (автоматически)

1. Обновление системы и зависимостей
2. Включение BBR (алгоритм TCP от Google)
3. Настройка файрволла UFW
4. Установка Go (для сборки Caddy)
5. Сборка Caddy с naive-плагином forwardproxy
6. Создание камуфляжной страницы + Caddyfile
7. Настройка systemd сервиса
8. Запуск + автостарт

---

## 📱 Клиенты для подключения

| Платформа | Приложение |
|-----------|-----------|
| iOS | [Karing](https://apps.apple.com/app/karing/id6472431552) |
| Android | [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid/releases) |
| Windows | [Hiddify](https://github.com/hiddify/hiddify-app/releases) |
| Windows | [NekoRay](https://github.com/MatsuriDayo/nekoray/releases) |

**Формат ссылки:** `naive+https://LOGIN:PASSWORD@your.domain.com:443`

---

## ⚙️ Управление панелью

```bash
pm2 status                      # Статус
pm2 logs naiveproxy-panel       # Логи
pm2 restart naiveproxy-panel    # Перезапуск
pm2 stop naiveproxy-panel       # Остановка
```

---

*by RIXXX — NaiveProxy панель с удобным интерфейсом*
# Panel NaiveProxy by RIXXX
