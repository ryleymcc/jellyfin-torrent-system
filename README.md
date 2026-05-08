Custom Jellyfin Cloud Server
============================

This repo deploys a complete Jellyfin media server to any Ubuntu or Raspberry Pi OS Docker host.

The deploy script builds the custom Jellyfin image for the target server architecture, uploads the app, starts Jellyfin, qBittorrent, torrent-search, nginx, and certbot, then issues a Let's Encrypt certificate for your Jellyfin domain.

Quick Deploy
------------

Requirements:

- Local machine: PowerShell, SSH, Docker Desktop with buildx, and the .NET SDK.
- Target server: Ubuntu or Raspberry Pi OS with Docker and Docker Compose.
- DNS: a Cloudflare `A` record for the Jellyfin domain.

1. Create the deploy config:

```powershell
cd C:\Users\faste\projects\vps\jellyfin\jellyfin-source\scripts
Copy-Item .\deploy.env.example .\deploy.env
notepad .\deploy.env
```

2. Fill in the required values:

```env
DEPLOY_SSH_HOST=your-server-or-ip
DEPLOY_SSH_USER=your-ssh-user
DEPLOY_SSH_PORT=22

JELLYFIN_DOMAIN=jellyfin.example.com
LETSENCRYPT_EMAIL=admin@example.com

REMOTE_APP_ROOT=~/jellyfin-app
REMOTE_STORAGE_ROOT=/mnt/sda/jellyfin-data
REMOTE_STORAGE_LINK=~/jellyfin-data
```

For a simple test on the server OS drive, use:

```env
REMOTE_APP_ROOT=~/jellyfin-app
REMOTE_STORAGE_ROOT=~/jellyfin-data
REMOTE_STORAGE_LINK=
```

3. In Cloudflare, create an `A` record for `JELLYFIN_DOMAIN` that points to the target server public IP.

Example:

```text
jellyfin.example.com -> 203.0.113.10
```

4. Run the deploy:

```powershell
.\deploy-jellyfin.ps1
```

Leave `DEPLOY_SUDO_PASSWORD` blank if you want the script to prompt for it. Leave `QBITTORRENT_PASSWORD` blank if you want a password generated automatically.

What Gets Deployed
------------------

- App files live under `REMOTE_APP_ROOT`, normally `~/jellyfin-app`.
- Persistent data lives under `REMOTE_STORAGE_ROOT`, normally a bulk storage mount.
- Jellyfin is published at `https://<JELLYFIN_DOMAIN>`.
- nginx exposes only ports `80` and `443`.
- qBittorrent Web UI is bound to `127.0.0.1:8080` on the server, not the public internet.
- Certificates are issued by certbot and renewed by a remote cron job.

Storage Layout
--------------

Inside Jellyfin, use the container paths:

```text
/media/downloads
/media/movies
/media/tv
```

On the server, those map to:

```text
REMOTE_STORAGE_ROOT/media/downloads
REMOTE_STORAGE_ROOT/media/movies
REMOTE_STORAGE_ROOT/media/tv
```

Recommended library types:

```text
/media/movies -> Movies
/media/tv     -> Shows
```

Useful Commands
---------------

Check the stack on the server:

```powershell
ssh your-user@your-server "cd ~/jellyfin-app && docker compose ps"
```

Redeploy after code changes:

```powershell
cd C:\Users\faste\projects\vps\jellyfin\jellyfin-source\scripts
.\deploy-jellyfin.ps1
```

Notes
-----

- Target architecture is detected automatically over SSH.
- Supported targets are `linux/amd64` and `linux/arm64`.
- The target server must already have Docker and Docker Compose available.
- The SSH account must be able to run `sudo`.
- Ports `80` and `443` must reach the target server for certificate issuance.
