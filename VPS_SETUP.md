# Собственный источник внешнего IPv4 на VPS

IP Informer принимает два формата ответа:

- обычный текст: `203.0.113.10`
- JSON: `{"ip":"203.0.113.10"}`

## DNS

Создайте запись `A` для имени, например `ip.example.com`, направленную на IPv4 VPS. Не создавайте для этого имени запись `AAAA`, если хотите всегда получать именно IPv4.

## Nginx на Ubuntu или Debian

```sh
sudo apt update
sudo apt install nginx certbot python3-certbot-nginx
```

Создайте `/etc/nginx/sites-available/ip-endpoint`:

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

Включите конфигурацию и HTTPS:

```sh
sudo ln -s /etc/nginx/sites-available/ip-endpoint /etc/nginx/sites-enabled/ip-endpoint
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d ip.example.com
curl https://ip.example.com
```

После проверки добавьте `https://ip.example.com` в настройках IP Informer. Эндпоинт по назначению сообщает посетителю его публичный IP; `access_log off` отключает хранение этих адресов в отдельном журнале Nginx.
