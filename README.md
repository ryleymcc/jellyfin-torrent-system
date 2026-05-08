jellyfin-torrent-system
=======================

This repo deploys a complete Jellyfin media server to any Ubuntu or Raspberry Pi OS Docker host.

The deploy script builds the custom Jellyfin image for the target server architecture, uploads the app, starts Jellyfin, qBittorrent, torrent-search, nginx, and certbot, then issues a Let's Encrypt certificate for your Jellyfin domain.

The custom Jellyfin server and web app sources live in fork-backed submodules under `jellyfin-source/jellyfin` and `jellyfin-source/jellyfin-web`.

Quick Deploy
------------

Requirements:

- Deploy machine: Ubuntu, Raspberry Pi OS, or Windows.
- Linux deploy machine: Bash, SSH, SCP, tar, curl, Docker with buildx, and the .NET SDK.
- Windows deploy machine: PowerShell, SSH, SCP, tar, Docker Desktop with buildx, and the .NET SDK.
- Target server: Ubuntu or Raspberry Pi OS with Docker and Docker Compose.
- DNS: a Cloudflare `A` record for the Jellyfin domain.

1. Clone the repo with submodules:

Fresh clone:

```bash
git clone --recurse-submodules <repo-url>
cd jellyfin-torrent-system
```

Existing clone:

```bash
git submodule update --init --recursive
```

2. Create the deploy config:

Ubuntu or Raspberry Pi:

```bash
cd jellyfin-source/scripts
cp deploy.env.example deploy.env
nano deploy.env
```

Windows:

```powershell
cd .\jellyfin-source\scripts
Copy-Item .\deploy.env.example .\deploy.env
notepad .\deploy.env
```

3. Fill in the required values:

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

4. In Cloudflare, create an `A` record for `JELLYFIN_DOMAIN` that points to the target server public IP.

Example:

```text
jellyfin.example.com -> 203.0.113.10
```

5. Run the deploy.

From Ubuntu or Raspberry Pi:

```bash
cd jellyfin-source/scripts
chmod +x ./deploy-jellyfin.sh
./deploy-jellyfin.sh
```

From Windows:

```powershell
cd .\jellyfin-source\scripts
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

Certificate Renewal
-------------------

Certificates do not need to be renewed manually after deployment.

The deploy installs `/etc/cron.d/jellyfin-certbot-renew` on the target server. That cron job runs `~/jellyfin-app/scripts/renew-certificates.sh` every day at `03:17`, lets certbot renew only when the certificate is close to expiry, and reloads nginx afterward.

Renewal logs are written on the target server at:

```text
~/jellyfin-app/logs/certbot-renew.log
```

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

Ubuntu or Raspberry Pi:

```bash
cd jellyfin-source/scripts
./deploy-jellyfin.sh
```

Windows:

```powershell
cd .\jellyfin-source\scripts
.\deploy-jellyfin.ps1
```

Notes
-----

- Target architecture is detected automatically over SSH.
- Supported targets are `linux/amd64` and `linux/arm64`.
- The target server must already have Docker and Docker Compose available.
- The SSH account must be able to run `sudo`.
- Ports `80` and `443` must reach the target server for certificate issuance.
