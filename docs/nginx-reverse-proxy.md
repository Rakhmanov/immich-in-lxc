# Nginx reverse proxy

Immich listens on port `2283`. Keep that port private and terminate HTTPS at a reverse proxy.

This example assumes:

- the public name is `immich.example.com`;
- Nginx runs in the same guest as Immich; and
- a certificate and private key already exist at `/etc/nginx/ssl/immich.pem` and `/etc/nginx/ssl/immich-key.pem`.

Replace the example name and certificate paths with real values.

## Install Nginx

Run as root:

```bash
apt-get update
apt-get install -y nginx
install -d -o root -g root -m 0700 /etc/nginx/ssl
```

Copy the certificate and key into `/etc/nginx/ssl`, owned by root. Restrict the private key:

```bash
chown root:root /etc/nginx/ssl/immich.pem /etc/nginx/ssl/immich-key.pem
chmod 0644 /etc/nginx/ssl/immich.pem
chmod 0600 /etc/nginx/ssl/immich-key.pem
```

## Configure the site

Create `/etc/nginx/sites-available/immich`:

```nginx
server {
    listen 80;
    server_name immich.example.com;

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name immich.example.com;

    ssl_certificate     /etc/nginx/ssl/immich.pem;
    ssl_certificate_key /etc/nginx/ssl/immich-key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:2283;
        proxy_http_version 1.1;
        proxy_request_buffering off;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

Enable and validate it:

```bash
ln -s /etc/nginx/sites-available/immich /etc/nginx/sites-enabled/immich
nginx -t
systemctl enable --now nginx
systemctl reload nginx
```

Open `https://immich.example.com` and verify login, upload, and a large video transfer. If another site already owns ports 80 or 443, integrate the `location` block into that proxy instead of starting a second listener.

The certificate lifecycle is intentionally outside this installer. Renew or replace certificates using the mechanism appropriate for your DNS and network.
