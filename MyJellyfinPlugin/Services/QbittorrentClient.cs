using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;
using MyJellyfinPlugin.Configuration;

namespace MyJellyfinPlugin.Services;

public sealed class QbittorrentClient : ITorrentClient
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly HttpClient _httpClient;
    private readonly ILogger<QbittorrentClient> _logger;

    public QbittorrentClient(ILogger<QbittorrentClient> logger)
    {
        _logger = logger;
        _httpClient = new HttpClient(new HttpClientHandler
        {
            UseCookies = true,
            CookieContainer = new CookieContainer()
        })
        {
            Timeout = TimeSpan.FromSeconds(30)
        };
    }

    public async Task<IReadOnlyList<TorrentSummary>> GetTorrentsAsync(CancellationToken cancellationToken)
    {
        var config = GetConfiguration();
        await LoginAsync(config, cancellationToken).ConfigureAwait(false);

        var requestUri = BuildUri(config.QbittorrentBaseUrl, "api/v2/torrents/info?sort=added_on&reverse=true");
        using var response = await _httpClient.GetAsync(requestUri, cancellationToken).ConfigureAwait(false);
        await EnsureSuccessAsync(response, cancellationToken).ConfigureAwait(false);

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        var torrents = await JsonSerializer.DeserializeAsync<List<QbTorrentInfoResponse>>(stream, JsonOptions, cancellationToken).ConfigureAwait(false)
            ?? [];

        return torrents
            .Select(t => new TorrentSummary
            {
                Hash = t.Hash,
                Name = t.Name,
                State = t.State,
                Progress = t.Progress,
                DownloadSpeed = t.DownloadSpeed,
                UploadSpeed = t.UploadSpeed,
                TotalSize = t.TotalSize > 0 ? t.TotalSize : t.Size,
                DownloadedBytes = Math.Max(t.Downloaded, t.Completed),
                EtaSeconds = t.EtaSeconds,
                Ratio = t.Ratio
            })
            .ToArray();
    }

    public async Task<IReadOnlyList<TorrentFileSummary>> GetTorrentFilesAsync(string hash, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(hash))
        {
            throw new ArgumentException("Torrent hash is required.", nameof(hash));
        }

        var config = GetConfiguration();
        await LoginAsync(config, cancellationToken).ConfigureAwait(false);

        var requestUri = BuildUri(config.QbittorrentBaseUrl, $"api/v2/torrents/files?hash={Uri.EscapeDataString(hash)}");
        using var response = await _httpClient.GetAsync(requestUri, cancellationToken).ConfigureAwait(false);
        await EnsureSuccessAsync(response, cancellationToken).ConfigureAwait(false);

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        var files = await JsonSerializer.DeserializeAsync<List<QbTorrentFileResponse>>(stream, JsonOptions, cancellationToken).ConfigureAwait(false)
            ?? [];

        return files
            .Select(f => new TorrentFileSummary
            {
                Index = f.Index,
                Name = f.Name,
                Size = f.Size,
                Progress = f.Progress,
                Priority = f.Priority,
                IsSeed = f.IsSeed
            })
            .ToArray();
    }

    public async Task AddMagnetAsync(string magnetLink, string? savePath, string? category, bool? paused, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(magnetLink))
        {
            throw new ArgumentException("Magnet link is required.", nameof(magnetLink));
        }

        var config = GetConfiguration();
        await LoginAsync(config, cancellationToken).ConfigureAwait(false);

        var resolvedSavePath = string.IsNullOrWhiteSpace(savePath) ? config.DefaultSavePath : savePath;
        var resolvedCategory = string.IsNullOrWhiteSpace(category) ? config.DefaultCategory : category;
        var pausedValue = paused ?? config.AddMagnetPausedByDefault;

        var formValues = new List<KeyValuePair<string, string>>
        {
            new("urls", magnetLink.Trim()),
            new("paused", pausedValue ? "true" : "false")
        };

        if (!string.IsNullOrWhiteSpace(resolvedSavePath))
        {
            formValues.Add(new KeyValuePair<string, string>("savepath", resolvedSavePath.Trim()));
        }

        if (!string.IsNullOrWhiteSpace(resolvedCategory))
        {
            formValues.Add(new KeyValuePair<string, string>("category", resolvedCategory.Trim()));
        }

        if (config.StopSeedingOnCompletion)
        {
            formValues.Add(new KeyValuePair<string, string>("ratioLimit", "0"));
            formValues.Add(new KeyValuePair<string, string>("seedingTimeLimit", "0"));
        }

        using var content = new FormUrlEncodedContent(formValues);
        using var response = await _httpClient.PostAsync(BuildUri(config.QbittorrentBaseUrl, "api/v2/torrents/add"), content, cancellationToken).ConfigureAwait(false);
        await EnsureSuccessAsync(response, cancellationToken).ConfigureAwait(false);
    }

    public Task PauseTorrentAsync(string hash, CancellationToken cancellationToken)
        => SendHashesActionWithFallbackAsync(
            hash,
            primaryPath: "api/v2/torrents/stop",
            fallbackPath: "api/v2/torrents/pause",
            cancellationToken: cancellationToken);

    public Task ResumeTorrentAsync(string hash, CancellationToken cancellationToken)
        => SendHashesActionWithFallbackAsync(
            hash,
            primaryPath: "api/v2/torrents/start",
            fallbackPath: "api/v2/torrents/resume",
            cancellationToken: cancellationToken);

    public async Task DeleteTorrentAsync(string hash, bool deleteFiles, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(hash))
        {
            throw new ArgumentException("Torrent hash is required.", nameof(hash));
        }

        var config = GetConfiguration();
        await LoginAsync(config, cancellationToken).ConfigureAwait(false);

        var formValues = new List<KeyValuePair<string, string>>
        {
            new("hashes", hash),
            new("deleteFiles", deleteFiles ? "true" : "false")
        };

        using var content = new FormUrlEncodedContent(formValues);
        using var response = await _httpClient.PostAsync(BuildUri(config.QbittorrentBaseUrl, "api/v2/torrents/delete"), content, cancellationToken).ConfigureAwait(false);
        await EnsureSuccessAsync(response, cancellationToken).ConfigureAwait(false);
    }

    public async Task SetFilePriorityAsync(string hash, int fileIndex, int priority, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(hash))
        {
            throw new ArgumentException("Torrent hash is required.", nameof(hash));
        }

        if (fileIndex < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(fileIndex), "File index must be non-negative.");
        }

        var config = GetConfiguration();
        await LoginAsync(config, cancellationToken).ConfigureAwait(false);

        var formValues = new List<KeyValuePair<string, string>>
        {
            new("hash", hash),
            new("id", fileIndex.ToString(System.Globalization.CultureInfo.InvariantCulture)),
            new("priority", priority.ToString(System.Globalization.CultureInfo.InvariantCulture))
        };

        using var content = new FormUrlEncodedContent(formValues);
        using var response = await _httpClient.PostAsync(BuildUri(config.QbittorrentBaseUrl, "api/v2/torrents/filePrio"), content, cancellationToken).ConfigureAwait(false);
        await EnsureSuccessAsync(response, cancellationToken).ConfigureAwait(false);
    }

    private async Task SendHashesActionWithFallbackAsync(
        string hash,
        string primaryPath,
        string? fallbackPath,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(hash))
        {
            throw new ArgumentException("Torrent hash is required.", nameof(hash));
        }

        var config = GetConfiguration();
        await LoginAsync(config, cancellationToken).ConfigureAwait(false);

        using var content = new FormUrlEncodedContent([
            new KeyValuePair<string, string>("hashes", hash)
        ]);
        using var response = await _httpClient.PostAsync(BuildUri(config.QbittorrentBaseUrl, primaryPath), content, cancellationToken).ConfigureAwait(false);

        if (response.StatusCode == HttpStatusCode.NotFound && !string.IsNullOrWhiteSpace(fallbackPath))
        {
            using var fallbackContent = new FormUrlEncodedContent([
                new KeyValuePair<string, string>("hashes", hash)
            ]);
            using var fallbackResponse = await _httpClient.PostAsync(BuildUri(config.QbittorrentBaseUrl, fallbackPath), fallbackContent, cancellationToken).ConfigureAwait(false);
            await EnsureSuccessAsync(fallbackResponse, cancellationToken).ConfigureAwait(false);
            return;
        }

        await EnsureSuccessAsync(response, cancellationToken).ConfigureAwait(false);
    }

    private static Uri BuildUri(string baseUrl, string relativePath)
    {
        if (string.IsNullOrWhiteSpace(baseUrl))
        {
            throw new InvalidOperationException("qBittorrent base URL is empty in plugin configuration.");
        }

        var normalizedBaseUrl = baseUrl.Trim();
        if (!normalizedBaseUrl.EndsWith("/", StringComparison.Ordinal))
        {
            normalizedBaseUrl += '/';
        }

        if (!Uri.TryCreate(normalizedBaseUrl, UriKind.Absolute, out var parsedBaseUri))
        {
            throw new InvalidOperationException("qBittorrent base URL is invalid in plugin configuration.");
        }

        return new Uri(parsedBaseUri, relativePath);
    }

    private async Task LoginAsync(PluginConfiguration configuration, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(configuration.QbittorrentUsername) || string.IsNullOrWhiteSpace(configuration.QbittorrentPassword))
        {
            throw new InvalidOperationException("qBittorrent username and password must be configured.");
        }

        using var content = new FormUrlEncodedContent([
            new KeyValuePair<string, string>("username", configuration.QbittorrentUsername),
            new KeyValuePair<string, string>("password", configuration.QbittorrentPassword)
        ]);

        using var response = await _httpClient.PostAsync(BuildUri(configuration.QbittorrentBaseUrl, "api/v2/auth/login"), content, cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);

        if (!response.IsSuccessStatusCode || !body.Trim().Equals("Ok.", StringComparison.OrdinalIgnoreCase))
        {
            _logger.LogWarning("qBittorrent login failed. Status: {StatusCode}, Body: {Body}", response.StatusCode, body);
            throw new InvalidOperationException("qBittorrent authentication failed. Verify URL and credentials.");
        }
    }

    private static async Task EnsureSuccessAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        throw new InvalidOperationException($"qBittorrent request failed: {(int)response.StatusCode} {response.StatusCode}. Response: {body}");
    }

    private static PluginConfiguration GetConfiguration()
    {
        return Plugin.Instance?.Configuration
            ?? throw new InvalidOperationException("Plugin configuration is unavailable.");
    }

    private sealed class QbTorrentInfoResponse
    {
        [JsonPropertyName("hash")]
        public string Hash { get; set; } = string.Empty;

        [JsonPropertyName("name")]
        public string Name { get; set; } = string.Empty;

        [JsonPropertyName("state")]
        public string State { get; set; } = string.Empty;

        [JsonPropertyName("progress")]
        public double Progress { get; set; }

        [JsonPropertyName("dlspeed")]
        public long DownloadSpeed { get; set; }

        [JsonPropertyName("upspeed")]
        public long UploadSpeed { get; set; }

        [JsonPropertyName("size")]
        public long Size { get; set; }

        [JsonPropertyName("total_size")]
        public long TotalSize { get; set; }

        [JsonPropertyName("downloaded")]
        public long Downloaded { get; set; }

        [JsonPropertyName("completed")]
        public long Completed { get; set; }

        [JsonPropertyName("eta")]
        public long EtaSeconds { get; set; }

        [JsonPropertyName("ratio")]
        public double Ratio { get; set; }
    }

    private sealed class QbTorrentFileResponse
    {
        [JsonPropertyName("index")]
        public int Index { get; set; }

        [JsonPropertyName("name")]
        public string Name { get; set; } = string.Empty;

        [JsonPropertyName("size")]
        public long Size { get; set; }

        [JsonPropertyName("progress")]
        public double Progress { get; set; }

        [JsonPropertyName("priority")]
        public int Priority { get; set; }

        [JsonPropertyName("is_seed")]
        public bool IsSeed { get; set; }
    }
}
