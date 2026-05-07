services:
  nginx:
    image: nginx:stable-alpine
    container_name: jellyfin-nginx
    restart: unless-stopped
    depends_on:
      - jellyfin
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "./nginx/active.conf:/etc/nginx/conf.d/default.conf:ro"
      - "__REMOTE_STORAGE_ROOT__/nginx/webroot:/var/www/certbot"
      - "__REMOTE_STORAGE_ROOT__/nginx/letsencrypt:/etc/letsencrypt"
    environment:
      TZ: "__TZ__"
    networks:
      - media-net

  certbot:
    image: certbot/certbot:latest
    container_name: jellyfin-certbot
    profiles:
      - ops
    volumes:
      - "__REMOTE_STORAGE_ROOT__/nginx/webroot:/var/www/certbot"
      - "__REMOTE_STORAGE_ROOT__/nginx/letsencrypt:/etc/letsencrypt"

  torrent-search:
    build:
      context: ./Torrent-Search-API
    container_name: torrent-search
    restart: unless-stopped
    volumes:
      - "__REMOTE_STORAGE_ROOT__/search:/search"
    networks:
      - media-net

  jellyfin:
    image: __CUSTOM_IMAGE__
    container_name: jellyfin
    restart: unless-stopped
    user: "__PUID__:__PGID__"
    environment:
      TZ: "__TZ__"
      JELLYFIN_PublishedServerUrl: "__JELLYFIN_PUBLISHED_URL__"
    volumes:
      - "__REMOTE_STORAGE_ROOT__/jellyfin/config:/config"
      - "__REMOTE_STORAGE_ROOT__/jellyfin/cache:/cache"
      - "__REMOTE_STORAGE_ROOT__/media:/media"
__JELLYFIN_EXTRA_PORTS_BLOCK__
    depends_on:
      - torrent-search
      - qbittorrent
    networks:
      - media-net

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    environment:
      PUID: "__PUID__"
      PGID: "__PGID__"
      TZ: "__TZ__"
      WEBUI_PORT: "__QBITTORRENT_WEBUI_PORT__"
      TORRENTING_PORT: "__QBITTORRENT_TORRENT_PORT__"
    volumes:
      - "__REMOTE_STORAGE_ROOT__/qbittorrent/config:/config"
      - "__REMOTE_STORAGE_ROOT__/media/downloads:/downloads"
    ports:
      - "127.0.0.1:__QBITTORRENT_WEBUI_PORT__:__QBITTORRENT_WEBUI_PORT__"
      - "__QBITTORRENT_TORRENT_PORT__:__QBITTORRENT_TORRENT_PORT__"
      - "__QBITTORRENT_TORRENT_PORT__:__QBITTORRENT_TORRENT_PORT__/udp"
    networks:
      - media-net

networks:
  media-net:
    driver: bridge
