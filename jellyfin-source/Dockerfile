FROM node:20-bookworm-slim AS web-builder
WORKDIR /src
COPY jellyfin-web/package*.json ./
RUN npm ci
COPY jellyfin-web/ ./
RUN npm run build:production

FROM mcr.microsoft.com/dotnet/sdk:9.0-bookworm-slim AS server-builder
WORKDIR /src
COPY jellyfin/ ./
RUN dotnet publish Jellyfin.Server/Jellyfin.Server.csproj -c Release -o /app/publish --self-contained false /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:9.0-bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates fonts-noto-core \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /jellyfin

COPY --from=server-builder /app/publish/ ./
COPY --from=web-builder /src/dist/ ./jellyfin-web/

ENV DOTNET_EnableDiagnostics=0 \
    JELLYFIN_DATA_DIR=/config/data \
    JELLYFIN_CONFIG_DIR=/config \
    JELLYFIN_CACHE_DIR=/cache \
    JELLYFIN_LOG_DIR=/config/log \
    JELLYFIN_WEB_DIR=/jellyfin/jellyfin-web

EXPOSE 8096 8920 7359/udp 1900/udp

ENTRYPOINT ["dotnet", "jellyfin.dll"]
