using System.Text.Json;
using MyJellyfinPlugin.Configuration;

namespace MyJellyfinPlugin.Services;

public sealed class TorrentSearchClient : ITorrentSearchClient
{
    private const string LockedSource = "piratebay";

    private static readonly Dictionary<string, string> SourceAliases = new(StringComparer.OrdinalIgnoreCase)
    {
        ["thepiratebay"] = "piratebay",
        ["tpb"] = "piratebay"
    };

    private readonly HttpClient _httpClient;

    public TorrentSearchClient()
    {
        _httpClient = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(45)
        };
    }

    public async Task<TorrentSearchResponse> SearchAsync(string query, string? source, int page, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            throw new ArgumentException("Search query is required.", nameof(query));
        }

        var config = GetConfiguration();
        var trimmedQuery = query.Trim();
        var resolvedSource = ResolveSource(source, config.SearchApiDefaultSource);
        var resolvedPage = page < 1 ? 1 : page;

        var requestUris = BuildSearchUris(config.SearchApiBaseUrl, resolvedSource, trimmedQuery, resolvedPage);
        string? lastFailure = null;

        foreach (var requestUri in requestUris)
        {
            HttpResponseMessage response;
            try
            {
                response = await _httpClient.GetAsync(requestUri, cancellationToken).ConfigureAwait(false);
            }
            catch (HttpRequestException)
            {
                throw new InvalidOperationException(
                    $"Cannot reach search API at '{config.SearchApiBaseUrl}'. Ensure the torrent-search container is running and reachable from Jellyfin.");
            }
            catch (TaskCanceledException)
            {
                throw new InvalidOperationException("Search API request timed out.");
            }

            using (response)
            {
                var payload = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);

                if (!response.IsSuccessStatusCode)
                {
                    lastFailure =
                        $"Search API request failed: {(int)response.StatusCode} {response.StatusCode}. Response: {payload}";
                    continue;
                }

                try
                {
                    var results = ParseResults(payload, resolvedSource);
                    return new TorrentSearchResponse
                    {
                        Query = trimmedQuery,
                        Source = resolvedSource,
                        Page = resolvedPage,
                        HasPreviousPage = resolvedPage > 1,
                        HasNextPage = results.Count > 0,
                        ReturnedCount = results.Count,
                        Results = results
                    };
                }
                catch (JsonException)
                {
                    lastFailure =
                        $"Search API returned a non-JSON or invalid JSON response for '{requestUri}'. Verify Search API URL in plugin settings.";
                }
            }
        }

        throw new InvalidOperationException(lastFailure ?? "Search API request failed for all supported endpoint patterns.");
    }

    private static IReadOnlyList<TorrentSearchResult> ParseResults(string json, string fallbackSource)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return [];
        }

        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;

        JsonElement arrayElement;
        if (root.ValueKind == JsonValueKind.Array)
        {
            arrayElement = root;
        }
        else if (root.ValueKind == JsonValueKind.Object && TryGetArray(root, out arrayElement))
        {
            // Some deployments wrap the array under results/data/items.
        }
        else
        {
            return [];
        }

        var results = new List<TorrentSearchResult>();

        foreach (var item in arrayElement.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object)
            {
                continue;
            }

            var name = ReadString(item, "Name", "name", "Title", "title") ?? string.Empty;
            var magnet = ReadString(item, "Magnet", "magnet");
            var torrentLink = ReadString(item, "Torrent", "torrent");
            var source = ReadString(item, "Source", "source") ?? fallbackSource;

            // qBittorrent accepts either magnet links or direct .torrent URLs in the urls field.
            var addLink = !string.IsNullOrWhiteSpace(magnet) ? magnet : (torrentLink ?? string.Empty);

            results.Add(new TorrentSearchResult
            {
                Name = name,
                Magnet = addLink,
                Source = source,
                Category = ReadString(item, "Category", "category"),
                Size = ReadString(item, "Size", "size"),
                Seeders = ReadString(item, "Seeders", "seeders"),
                Leechers = ReadString(item, "Leechers", "leechers"),
                Url = ReadString(item, "Url", "url")
            });
        }

        return results;
    }

    private static bool TryGetArray(JsonElement objectElement, out JsonElement arrayElement)
    {
        if (objectElement.TryGetProperty("results", out arrayElement) && arrayElement.ValueKind == JsonValueKind.Array)
        {
            return true;
        }

        if (objectElement.TryGetProperty("Results", out arrayElement) && arrayElement.ValueKind == JsonValueKind.Array)
        {
            return true;
        }

        if (objectElement.TryGetProperty("data", out arrayElement) && arrayElement.ValueKind == JsonValueKind.Array)
        {
            return true;
        }

        if (objectElement.TryGetProperty("items", out arrayElement) && arrayElement.ValueKind == JsonValueKind.Array)
        {
            return true;
        }

        arrayElement = default;
        return false;
    }

    private static string? ReadString(JsonElement objectElement, params string[] propertyNames)
    {
        foreach (var name in propertyNames)
        {
            if (!objectElement.TryGetProperty(name, out var value))
            {
                continue;
            }

            if (value.ValueKind == JsonValueKind.String)
            {
                return value.GetString();
            }

            if (value.ValueKind == JsonValueKind.Number || value.ValueKind == JsonValueKind.True || value.ValueKind == JsonValueKind.False)
            {
                return value.ToString();
            }
        }

        return null;
    }

    private static string ResolveSource(string? sourceOverride, string? configuredDefaultSource)
    {
        // Keep normalization for compatibility with existing aliases, but lock the source.
        var requestedSource = NormalizeSourceToken(sourceOverride);
        if (!string.IsNullOrWhiteSpace(requestedSource) && SourceAliases.TryGetValue(requestedSource, out _))
        {
            // Alias recognized; source remains locked below.
        }

        var configuredSource = NormalizeSourceToken(configuredDefaultSource);
        if (!string.IsNullOrWhiteSpace(configuredSource) && SourceAliases.TryGetValue(configuredSource, out _))
        {
            // Alias recognized; source remains locked below.
        }

        return LockedSource;
    }

    private static string? NormalizeSourceToken(string? sourceValue)
    {
        if (string.IsNullOrWhiteSpace(sourceValue))
        {
            return null;
        }

        var cleaned = new string(sourceValue.Trim().ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
        return string.IsNullOrWhiteSpace(cleaned) ? null : cleaned;
    }

    private static IReadOnlyList<Uri> BuildSearchUris(string baseUrl, string source, string query, int page)
    {
        var parsedBaseUri = BuildBaseUri(baseUrl);
        var escapedSource = Uri.EscapeDataString(source);
        var escapedQuery = Uri.EscapeDataString(query);
        var pageToken = page.ToString();

        var basePath = parsedBaseUri.AbsolutePath.Trim('/').ToLowerInvariant();
        var relativePaths = new List<string>();

        if (basePath.EndsWith("search", StringComparison.Ordinal) || basePath.EndsWith("find", StringComparison.Ordinal))
        {
            relativePaths.Add($"{escapedSource}/{escapedQuery}/{pageToken}");
        }
        else
        {
            relativePaths.Add($"find/{escapedSource}/{escapedQuery}/{pageToken}");
            relativePaths.Add($"search/{escapedSource}/{escapedQuery}/{pageToken}");
        }

        return relativePaths
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Select(path => new Uri(parsedBaseUri, path))
            .ToList();
    }

    private static Uri BuildBaseUri(string baseUrl)
    {
        if (string.IsNullOrWhiteSpace(baseUrl))
        {
            throw new InvalidOperationException("Search API base URL is empty in plugin configuration.");
        }

        var normalizedBaseUrl = baseUrl.Trim();
        if (!normalizedBaseUrl.EndsWith("/", StringComparison.Ordinal))
        {
            normalizedBaseUrl += '/';
        }

        if (!Uri.TryCreate(normalizedBaseUrl, UriKind.Absolute, out var parsedBaseUri))
        {
            throw new InvalidOperationException("Search API base URL is invalid in plugin configuration.");
        }

        return parsedBaseUri;
    }

    private static PluginConfiguration GetConfiguration()
    {
        return Plugin.Instance?.Configuration
            ?? throw new InvalidOperationException("Plugin configuration is unavailable.");
    }
}
