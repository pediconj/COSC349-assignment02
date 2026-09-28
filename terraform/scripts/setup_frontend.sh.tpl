#!/bin/bash
exec > /var/log/user_data.log 2>&1
set -x

systemctl stop unattended-upgrades.service || true
systemctl disable unattended-upgrades.service || true
systemctl mask unattended-upgrades.service || true

pkill -9 -f apt-get || true
pkill -9 -f dpkg || true

rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock* /var/cache/apt/archives/lock* || true
dpkg --configure -a || true

export DEBIAN_FRONTEND=noninteractive
for i in {1..10}; do
  apt-get update -y && apt-get install -y nginx && break
  sleep 5
done

cat << 'NGINX' > /etc/nginx/sites-available/default
server {
    listen 80 default_server;
    server_name _;

    root /var/www/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    location /api/ {
        proxy_pass http://${backend_ip}:5000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGINX

cat << 'HTML_PAGE' > /var/www/html/index.html
${html_code}
HTML_PAGE

systemctl restart nginx
