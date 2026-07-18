# Nginx reverse proxy

Immich listens on port `2283`. Keep that port private and terminate HTTPS at a reverse proxy.

This example assumes:

- the public name is `immich.example.com`;
- Nginx runs in the same guest as Immich; and
- a certificate and private key exist at `/etc/nginx/ssl/immich.pem` and `/etc/nginx/ssl/immich-key.pem`.

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

## Get a certificate

Pick whichever matches how you'll reach `immich.example.com`.

**LAN-only / self-hosted, no public DNS** — use [mkcert](https://github.com/FiloSottile/mkcert)
so clients trust the cert without a browser warning:

```bash
apt-get install -y libnss3-tools
curl -JLO https://dl.filippo.io/mkcert/latest?for=linux/amd64
install -m 0755 mkcert-v*-linux-amd64 /usr/local/bin/mkcert
mkcert -install                       # generates and trusts a local CA
mkcert -cert-file /etc/nginx/ssl/immich.pem -key-file /etc/nginx/ssl/immich-key.pem immich.example.com
```

The local CA (`mkcert -CAROOT`) needs installing on every client device too, or they'll still
show untrusted.

**Quick and dirty, browser warning expected** — a self-signed cert, no CA involved:

```bash
openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/immich-key.pem \
  -out /etc/nginx/ssl/immich.pem \
  -subj "/CN=immich.example.com"
```

**Public domain with real DNS** — use [certbot](https://certbot.eff.org/) instead of a
manually-generated cert, and point it at the same two paths, or update `ssl_certificate`/
`ssl_certificate_key` below to certbot's `/etc/letsencrypt/live/immich.example.com/` output.
Certbot also handles renewal; the two manual options above do not.

```bash
apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d immich.example.com
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
    client_body_buffer_size 1024k;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
    send_timeout 600s;

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

The default 60s proxy timeout is too short for large or slow uploads and will drop the
connection mid-transfer — the mobile app reports this as `unexpected end of stream`. The
`proxy_read_timeout`/`proxy_send_timeout`/`send_timeout` above raise that to 10 minutes.

Enable and validate it:

```bash
ln -s /etc/nginx/sites-available/immich /etc/nginx/sites-enabled/immich
nginx -t
systemctl enable --now nginx
systemctl reload nginx
```

Open `https://immich.example.com` and verify login, upload, and a large video transfer. If another site already owns ports 80 or 443, integrate the `location` block into that proxy instead of starting a second listener.

The certificate lifecycle is intentionally outside this installer. mkcert and self-signed certs above don't renew themselves — re-run the same command before they expire, or switch to certbot if that becomes a chore.

## Troubleshooting: upload fails with "unexpected end of stream"

If the mobile app's server endpoint is set to `http://` instead of `https://`, every request
hits the port-80 listener first and gets 308-redirected to https. Small metadata calls survive
that (tiny or empty body, trivially re-sent), but a large streaming upload doesn't — the app
consumes the upload stream on the first attempt and has nothing left to send when it retries
against the redirect target, killing the connection mid-transfer.

Fix the endpoint in the app to `https://` if you can. If you can't (some app builds don't expose
that setting, or it's pinned elsewhere), drop the redirect instead and serve the app directly on
port 80 too, by copying the `client_max_body_size`/`proxy_*`/`location` block from the `443`
server into the `80` server in place of the `return 308 ...` line. This removes the forced-HTTPS
default, so only do it on a trusted LAN where that trade-off is acceptable.
