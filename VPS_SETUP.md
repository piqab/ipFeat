# Your own public IPv4 endpoint on a VPS

IP Informer accepts plain text such as `203.0.113.10` or JSON such as `{"ip":"203.0.113.10"}`.

## DNS

Create an `A` record for a name such as `ip.example.com` pointing to the VPS IPv4 address. Omit an `AAAA` record if you want this hostname to resolve only to IPv4.

## Nginx on Ubuntu or Debian

```sh
sudo apt update
sudo apt install nginx certbot python3-certbot-nginx
```

Create `/etc/nginx/sites-available/ip-endpoint`:

```nginx
server {
    listen 80;
    server_name ip.example.com;

    access_log off;
    default_type text/plain;

    location / {
        return 200 "$remote_addr\n";
    }
}
```

Enable the site and HTTPS:

```sh
sudo ln -s /etc/nginx/sites-available/ip-endpoint /etc/nginx/sites-enabled/ip-endpoint
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d ip.example.com
curl https://ip.example.com
```

After verifying the response, add `https://ip.example.com` as a custom source in IP Informer settings. This endpoint is designed to reveal a visitor's public IP; `access_log off` prevents storing it in a separate Nginx access log.
