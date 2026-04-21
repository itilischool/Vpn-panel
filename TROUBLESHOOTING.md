# Troubleshooting Guide - Panel NaiveProxy by RIXXX

## Common Issues and Solutions

### 1. Panel doesn't open (nginx not working)

**Symptoms:**
- Can't access panel at http://SERVER_IP:8080 or http://SERVER_IP:3000
- Browser shows "Connection refused" or timeout

**Solutions:**

#### Check if panel is running:
```bash
pm2 status naiveproxy-panel
```

If not running, check logs:
```bash
pm2 logs naiveproxy-panel --lines 50
```

Restart the panel:
```bash
pm2 restart naiveproxy-panel
```

#### Check if nginx is running:
```bash
systemctl status nginx
```

If not running:
```bash
nginx -t  # Test config
systemctl start nginx
```

#### Check firewall:
```bash
ufw status
```

Required ports:
- **Mode 1 (Nginx proxy)**: 22, 80, 443, 8080
- **Mode 2 (Direct)**: 22, 80, 443, 3000
- **Mode 3 (Domain + HTTPS)**: 22, 80, 443

Open port if needed:
```bash
ufw allow 8080/tcp  # For mode 1
ufw allow 3000/tcp  # For mode 2
```

### 2. Nginx configuration issues

**Check nginx config:**
```bash
nginx -t
```

**View nginx error log:**
```bash
tail -f /var/log/nginx/error.log
```

**Restart nginx:**
```bash
systemctl restart nginx
```

**Recreate nginx config for panel:**
```bash
cat > /etc/nginx/sites-available/naiveproxy-panel << 'NGINX_EOF'
server {
    listen 8080;
    server_name _;

    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
    }
}
NGINX_EOF

ln -sf /etc/nginx/sites-available/naiveproxy-panel /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx
```

### 3. Caddy/NaiveProxy not working

**Check Caddy status:**
```bash
systemctl status caddy
journalctl -u caddy -f
```

**Check Caddyfile:**
```bash
cat /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile
```

**Restart Caddy:**
```bash
systemctl restart caddy
```

### 4. SSL/TLS certificate issues

**Check certificate:**
```bash
curl -vI https://your-domain.com
```

**Force certificate renewal:**
```bash
systemctl stop caddy
rm -rf ~/.local/share/caddy/certificates
systemctl start caddy
```

### 5. Database/config file issues

**Reset admin password:**
```bash
cd /opt/naiveproxy-panel/panel
node -e "const bcrypt=require('bcryptjs'); console.log(bcrypt.hashSync('admin', 10))"
# Copy the hash and edit data/users.json
```

**Check config files:**
```bash
cat /opt/naiveproxy-panel/panel/data/config.json
cat /opt/naiveproxy-panel/panel/data/users.json
```

### 6. PM2 issues

**PM2 commands:**
```bash
pm2 list                    # Show all processes
pm2 describe naiveproxy-panel  # Detailed info
pm2 logs naiveproxy-panel   # View logs
pm2 restart naiveproxy-panel   # Restart
pm2 delete naiveproxy-panel    # Delete process
pm2 save                    # Save process list
```

**Startup on boot:**
```bash
pm2 startup systemd -u root --hp /root
# Run the command that pm2 outputs
pm2 save
```

### 7. Complete reinstall

If nothing works, complete reinstall:

```bash
# Stop services
pm2 stop naiveproxy-panel
pm2 delete naiveproxy-panel
systemctl stop caddy

# Remove installation
rm -rf /opt/naiveproxy-panel
rm -f /etc/systemd/system/caddy.service
rm -f /etc/nginx/sites-enabled/naiveproxy-panel
rm -f /etc/nginx/sites-available/naiveproxy-panel

# Reinstall
bash <(curl -fsSL https://raw.githubusercontent.com/itilischool/Vpn-panel/main/install.sh)
```

## Useful Commands Reference

### Panel Management
```bash
pm2 status                      # Check panel status
pm2 logs naiveproxy-panel       # View panel logs
pm2 restart naiveproxy-panel    # Restart panel
```

### Nginx Management
```bash
systemctl status nginx          # Check nginx status
systemctl restart nginx         # Restart nginx
nginx -t                        # Test nginx config
tail -f /var/log/nginx/error.log  # View error log
```

### Caddy Management
```bash
systemctl status caddy          # Check Caddy status
systemctl restart caddy         # Restart Caddy
journalctl -u caddy -f          # View Caddy logs
caddy validate --config /etc/caddy/Caddyfile  # Validate config
```

### Firewall
```bash
ufw status                      # Check firewall status
ufw allow 8080/tcp              # Open port 8080
ufw allow 3000/tcp              # Open port 3000
ufw reload                      # Reload firewall rules
```

## Contact & Support

If you still have issues:
1. Check logs carefully for error messages
2. Verify DNS records point to correct IP
3. Ensure all required ports are open
4. Try reinstalling from scratch

Telegram support: https://t.me/russian_paradice_vpn
