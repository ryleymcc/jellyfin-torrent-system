## My Jellyfin Plugin Download Manager

This plugin adds a Jellyfin dashboard page to control a separate qBittorrent container.

Main capabilities:

- Search new content from a dedicated Search view.
- Add download links from Search results or manually via Add Magnet.
- Automatically stop seeding for plugin-added downloads as soon as they complete.
- View and monitor active downloads in Current Downloads.
- Pause, resume, or delete downloads.
- Manage per-file priority in Download Files.
- Edit qBittorrent and search API settings in Settings.

## UI Layout

The plugin page is organized into five top tabs:

1. Search (default view)
2. Current Downloads
3. Download Files
4. Add Magnet
5. Settings

Pagination in Search uses Previous and Next buttons plus a page indicator.

## Search Source Behavior

Search source is locked to piratebay in both frontend and backend.

- The source is not editable in the UI.
- Requests include source=piratebay.
- Backend enforcement returns piratebay as the canonical source.

## Recommended Architecture

Running qBittorrent in a separate container with a shared media volume is the intended setup.

- Jellyfin plugin: control plane (UI + API calls)
- qBittorrent container: download traffic and storage
- Shared volume: qBittorrent writes files where Jellyfin can read them

Example compose layout (simplified):

```yaml
services:
	jellyfin:
		image: lscr.io/linuxserver/jellyfin:latest
		container_name: jellyfin
		volumes:
			- /home/ryley/exatorrent/exa_data/jellyfin/config:/config
			- /home/ryley/exatorrent/exa_data/media:/media
		networks:
			- media-net

	qbittorrent:
		image: lscr.io/linuxserver/qbittorrent:latest
		container_name: qbittorrent
		environment:
			- WEBUI_PORT=8080
		volumes:
			- /home/ryley/exatorrent/exa_data/qbittorrent/config:/config
			- /home/ryley/exatorrent/exa_data/media:/media
		ports:
			- "8080:8080"
		networks:
			- media-net

networks:
	media-net:
		driver: bridge
```

Configure the plugin with:

- qBittorrent URL: http://qbittorrent:8080/
- Username/password: your qBittorrent Web UI credentials
- Default save path: shared path such as /media/downloads
- Stop seeding on completion: enabled if you want plugin-added downloads to pause as soon as they finish
- Search API URL: http://torrent-search:3001/

## Build

```bash
dotnet restore
dotnet build -c Release
```

## Install into a Running Jellyfin Container

Use a versioned plugin folder containing dots so Jellyfin discovers it.

```bash
mkdir -p /home/ryley/exatorrent/exa_data/jellyfin/config/data/plugins/MyJellyfinPlugin_1.0.0.0
cp ./bin/Release/net9.0/MyJellyfinPlugin.dll /home/ryley/exatorrent/exa_data/jellyfin/config/data/plugins/MyJellyfinPlugin_1.0.0.0/
docker restart jellyfin
```

## Verify

1. Open Jellyfin Dashboard.
2. Open the Download Content page.
3. Confirm Search is the default tab.
4. Run a search and confirm Previous/Next pagination works.
5. Add a result from Search.
6. Add a manual magnet from Add Magnet.
7. Open Current Downloads and verify auto-refresh updates while that tab is active.
8. Open Download Files from a selected download and change file priority.
9. Save settings from the Settings tab and confirm the stop-seeding option matches your preference.
