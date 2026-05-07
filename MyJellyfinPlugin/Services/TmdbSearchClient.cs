using System.Globalization;
using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;
using MyJellyfinPlugin.Configuration;

namespace MyJellyfinPlugin.Services;

public sealed class TmdbSearchClient : ITmdbSearchClient
{
    private const string SearchEndpoint = "https://api.themoviedb.org/3/search/multi";
    private const string TvEndpoint = "https://api.themoviedb.org/3/tv";
    private const string PosterBaseUrl = "https://image.tmdb.org/t/p/w154";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly HttpClient _httpClient;
    private readonly ILogger<TmdbSearchClient> _logger;

    public TmdbSearchClient(ILogger<TmdbSearchClient> logger)
    {
        _logger = logger;
        _httpClient = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(15)
        };
    }

    public async Task<TmdbSearchResponse> SearchAsync(string query, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            throw new ArgumentException("Search query is required.", nameof(query));
        }

        var trimmedQuery = query.Trim();
        var config = GetConfiguration();

        if (string.IsNullOrWhiteSpace(config.TmdbApiKey))
        {
            return new TmdbSearchResponse
            {
                Query = trimmedQuery,
                Configured = false,
                ReturnedCount = 0,
                Results = []
            };
        }

        var payload = await SendTmdbGetAsync(BuildSearchUri(config.TmdbApiKey, trimmedQuery), cancellationToken).ConfigureAwait(false);

        try
        {
            var searchResponse = JsonSerializer.Deserialize<TmdbMultiSearchResponse>(payload, JsonOptions) ?? new TmdbMultiSearchResponse();
            var results = searchResponse.Results
                .Where(IsSupportedResult)
                .Select(MapResult)
                .Where(result => !string.IsNullOrWhiteSpace(result.Title))
                .Take(10)
                .ToArray();

            return new TmdbSearchResponse
            {
                Query = trimmedQuery,
                Configured = true,
                ReturnedCount = results.Length,
                Results = results
            };
        }
        catch (JsonException ex)
        {
            _logger.LogWarning(ex, "TMDB returned invalid JSON.");
            throw new InvalidOperationException("TMDB returned an invalid JSON response.");
        }
    }

    public async Task<TmdbSeriesDetailsResponse> GetSeriesDetailsAsync(int tmdbId, CancellationToken cancellationToken)
    {
        if (tmdbId <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(tmdbId), "TMDB series id must be positive.");
        }

        var payload = await SendTmdbGetAsync(BuildSeriesDetailsUri(GetApiKey(), tmdbId), cancellationToken).ConfigureAwait(false);

        try
        {
            var response = JsonSerializer.Deserialize<TmdbTvDetailsResponse>(payload, JsonOptions) ?? new TmdbTvDetailsResponse();
            var seasons = response.Seasons
                .Where(season => season.EpisodeCount > 0)
                .OrderBy(season => season.SeasonNumber)
                .Select(season => new TmdbSeasonSummary
                {
                    SeasonNumber = season.SeasonNumber,
                    Name = season.Name ?? string.Empty,
                    EpisodeCount = season.EpisodeCount,
                    PosterUrl = string.IsNullOrWhiteSpace(season.PosterPath) ? null : $"{PosterBaseUrl}{season.PosterPath}"
                })
                .ToArray();

            return new TmdbSeriesDetailsResponse
            {
                TmdbId = response.Id,
                Title = response.Name ?? string.Empty,
                Seasons = seasons
            };
        }
        catch (JsonException ex)
        {
            _logger.LogWarning(ex, "TMDB returned invalid series details JSON for {TmdbId}.", tmdbId);
            throw new InvalidOperationException("TMDB returned an invalid series details response.");
        }
    }

    public async Task<TmdbSeasonDetailsResponse> GetSeasonDetailsAsync(int tmdbId, int seasonNumber, CancellationToken cancellationToken)
    {
        if (tmdbId <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(tmdbId), "TMDB series id must be positive.");
        }

        if (seasonNumber < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(seasonNumber), "TMDB season number must be zero or positive.");
        }

        var payload = await SendTmdbGetAsync(BuildSeasonDetailsUri(GetApiKey(), tmdbId, seasonNumber), cancellationToken).ConfigureAwait(false);

        try
        {
            var response = JsonSerializer.Deserialize<TmdbTvSeasonDetailsResponse>(payload, JsonOptions) ?? new TmdbTvSeasonDetailsResponse();
            var episodes = response.Episodes
                .Where(episode => episode.EpisodeNumber > 0)
                .OrderBy(episode => episode.EpisodeNumber)
                .Select(episode => new TmdbEpisodeSummary
                {
                    EpisodeNumber = episode.EpisodeNumber,
                    Name = episode.Name ?? string.Empty,
                    DisplayTitle = $"Episode {episode.EpisodeNumber.ToString(CultureInfo.InvariantCulture)}: {episode.Name ?? string.Empty}".TrimEnd(':', ' ')
                })
                .ToArray();

            return new TmdbSeasonDetailsResponse
            {
                TmdbId = tmdbId,
                SeasonNumber = response.SeasonNumber,
                Episodes = episodes
            };
        }
        catch (JsonException ex)
        {
            _logger.LogWarning(ex, "TMDB returned invalid season details JSON for {TmdbId} season {SeasonNumber}.", tmdbId, seasonNumber);
            throw new InvalidOperationException("TMDB returned an invalid season details response.");
        }
    }

    private static bool IsSupportedResult(TmdbMultiSearchItem item)
    {
        if (item is null)
        {
            return false;
        }

        return item.MediaType is "movie" or "tv";
    }

    private static TmdbSearchResult MapResult(TmdbMultiSearchItem item)
    {
        var title = item.Title ?? item.Name ?? string.Empty;
        var releaseYear = GetReleaseYear(item.ReleaseDate) ?? GetReleaseYear(item.FirstAirDate);
        var displayTitle = releaseYear.HasValue ? $"{title} ({releaseYear.Value.ToString(CultureInfo.InvariantCulture)})" : title;
        var searchTitle = releaseYear.HasValue ? $"{title} {releaseYear.Value.ToString(CultureInfo.InvariantCulture)}" : title;

        return new TmdbSearchResult
        {
            TmdbId = item.Id,
            Title = title,
            DisplayTitle = displayTitle,
            SearchTitle = searchTitle,
            MediaType = item.MediaType == "tv" ? "series" : "movie",
            ReleaseYear = releaseYear,
            PosterUrl = string.IsNullOrWhiteSpace(item.PosterPath) ? null : $"{PosterBaseUrl}{item.PosterPath}",
            Overview = string.IsNullOrWhiteSpace(item.Overview) ? null : item.Overview.Trim()
        };
    }

    private static int? GetReleaseYear(string? dateText)
    {
        if (string.IsNullOrWhiteSpace(dateText))
        {
            return null;
        }

        if (DateOnly.TryParse(dateText, CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsedDate))
        {
            return parsedDate.Year;
        }

        if (dateText.Length >= 4 && int.TryParse(dateText[..4], NumberStyles.Integer, CultureInfo.InvariantCulture, out var year))
        {
            return year;
        }

        return null;
    }

    private static Uri BuildSearchUri(string apiKey, string query)
    {
        var escapedApiKey = Uri.EscapeDataString(apiKey.Trim());
        var escapedQuery = Uri.EscapeDataString(query);
        return new Uri($"{SearchEndpoint}?api_key={escapedApiKey}&query={escapedQuery}&page=1&include_adult=false");
    }

    private static Uri BuildSeriesDetailsUri(string apiKey, int tmdbId)
    {
        var escapedApiKey = Uri.EscapeDataString(apiKey.Trim());
        return new Uri($"{TvEndpoint}/{tmdbId.ToString(CultureInfo.InvariantCulture)}?api_key={escapedApiKey}");
    }

    private static Uri BuildSeasonDetailsUri(string apiKey, int tmdbId, int seasonNumber)
    {
        var escapedApiKey = Uri.EscapeDataString(apiKey.Trim());
        return new Uri($"{TvEndpoint}/{tmdbId.ToString(CultureInfo.InvariantCulture)}/season/{seasonNumber.ToString(CultureInfo.InvariantCulture)}?api_key={escapedApiKey}");
    }

    private async Task<string> SendTmdbGetAsync(Uri requestUri, CancellationToken cancellationToken)
    {
        HttpResponseMessage response;
        try
        {
            response = await _httpClient.GetAsync(requestUri, cancellationToken).ConfigureAwait(false);
        }
        catch (HttpRequestException ex)
        {
            _logger.LogWarning(ex, "Cannot reach TMDB search API.");
            throw new InvalidOperationException("Cannot reach TMDB search API.");
        }
        catch (TaskCanceledException)
        {
            throw new InvalidOperationException("TMDB search request timed out.");
        }

        using (response)
        {
            var payload = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);

            if (response.StatusCode == HttpStatusCode.Unauthorized)
            {
                throw new InvalidOperationException("TMDB API key is invalid or unauthorized.");
            }

            if (!response.IsSuccessStatusCode)
            {
                throw new InvalidOperationException($"TMDB search request failed: {(int)response.StatusCode} {response.StatusCode}. Response: {payload}");
            }

            return payload;
        }
    }

    private static string GetApiKey()
    {
        var apiKey = GetConfiguration().TmdbApiKey;
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            throw new InvalidOperationException("TMDB API key is not configured.");
        }

        return apiKey;
    }

    private static PluginConfiguration GetConfiguration()
    {
        return Plugin.Instance?.Configuration
            ?? throw new InvalidOperationException("Plugin configuration is unavailable.");
    }

    private sealed class TmdbMultiSearchResponse
    {
        [JsonPropertyName("results")]
        public List<TmdbMultiSearchItem> Results { get; set; } = [];
    }

    private sealed class TmdbMultiSearchItem
    {
        [JsonPropertyName("id")]
        public int Id { get; set; }

        [JsonPropertyName("media_type")]
        public string? MediaType { get; set; }

        [JsonPropertyName("title")]
        public string? Title { get; set; }

        [JsonPropertyName("name")]
        public string? Name { get; set; }

        [JsonPropertyName("overview")]
        public string? Overview { get; set; }

        [JsonPropertyName("poster_path")]
        public string? PosterPath { get; set; }

        [JsonPropertyName("release_date")]
        public string? ReleaseDate { get; set; }

        [JsonPropertyName("first_air_date")]
        public string? FirstAirDate { get; set; }
    }

    private sealed class TmdbTvDetailsResponse
    {
        [JsonPropertyName("id")]
        public int Id { get; set; }

        [JsonPropertyName("name")]
        public string? Name { get; set; }

        [JsonPropertyName("seasons")]
        public List<TmdbTvSeason> Seasons { get; set; } = [];
    }

    private sealed class TmdbTvSeason
    {
        [JsonPropertyName("season_number")]
        public int SeasonNumber { get; set; }

        [JsonPropertyName("name")]
        public string? Name { get; set; }

        [JsonPropertyName("episode_count")]
        public int EpisodeCount { get; set; }

        [JsonPropertyName("poster_path")]
        public string? PosterPath { get; set; }
    }

    private sealed class TmdbTvSeasonDetailsResponse
    {
        [JsonPropertyName("season_number")]
        public int SeasonNumber { get; set; }

        [JsonPropertyName("episodes")]
        public List<TmdbTvEpisode> Episodes { get; set; } = [];
    }

    private sealed class TmdbTvEpisode
    {
        [JsonPropertyName("episode_number")]
        public int EpisodeNumber { get; set; }

        [JsonPropertyName("name")]
        public string? Name { get; set; }
    }
}