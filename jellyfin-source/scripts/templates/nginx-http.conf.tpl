map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name __JELLYFIN_DOMAIN__;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type text/plain;
        try_files $uri =404;
    }

    location = /__jellyfin_deploy_probe {
        default_type text/plain;
        return 200 "ready\n";
    }

    resolver 127.0.0.11 valid=30s ipv6=off;
    resolver_timeout 5s;
    set $jellyfin_upstream jellyfin:8096;

    location / {
        proxy_pass http://$jellyfin_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_read_timeout 90;
        proxy_connect_timeout 10s;
        proxy_send_timeout 90;
        proxy_buffering off;
    }

    client_max_body_size 100M;
}
