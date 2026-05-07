using System.Net.Mime;
using System.Net.Http;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;
using MyJellyfinPlugin.Services;

namespace MyJellyfinPlugin.API;

[ApiController]
[Produces(MediaTypeNames.Application.Json)]
public sealed class TorrentController : ControllerBase
{
    private readonly ILogger<TorrentController> _logger;
    private readonly ITmdbSearchClient _tmdbSearchClient;
    private readonly ITorrentClient _torrentClient;
    private readonly ITorrentSearchClient _torrentSearchClient;

    public TorrentController(
        ILogger<TorrentController> logger,
        ITmdbSearchClient tmdbSearchClient,
        ITorrentClient torrentClient,
        ITorrentSearchClient torrentSearchClient)
    {
        _logger = logger;
        _tmdbSearchClient = tmdbSearchClient;
        _torrentClient = torrentClient;
        _torrentSearchClient = torrentSearchClient;
    }

    [HttpGet("MyJellyfinPlugin/Torrents")]
    public async Task<ActionResult<IReadOnlyList<TorrentSummary>>> GetTorrents(CancellationToken cancellationToken)
    {
        return await ExecuteQueryAsync(() => _torrentClient.GetTorrentsAsync(cancellationToken)).ConfigureAwait(false);
    }

    [HttpGet("MyJellyfinPlugin/Torrents/{hash}/Files")]
    public async Task<ActionResult<IReadOnlyList<TorrentFileSummary>>> GetTorrentFiles([FromRoute] string hash, CancellationToken cancellationToken)
    {
        return await ExecuteQueryAsync(() => _torrentClient.GetTorrentFilesAsync(hash, cancellationToken)).ConfigureAwait(false);
    }

    [HttpPost("MyJellyfinPlugin/Torrents/Add")]
    public async Task<IActionResult> AddMagnet([FromBody] AddMagnetRequest request, CancellationToken cancellationToken)
    {
        return await ExecuteCommandAsync(async () =>
        {
            if (request is null || string.IsNullOrWhiteSpace(request.MagnetLink))
            {
                throw new ArgumentException("MagnetLink is required.");
            }

            await _torrentClient.AddMagnetAsync(
                request.MagnetLink,
                request.SavePath,
                request.Category,
                request.Paused,
                cancellationToken).ConfigureAwait(false);
        }).ConfigureAwait(false);
    }

    [HttpPost("MyJellyfinPlugin/Torrents/{hash}/Pause")]
    public async Task<IActionResult> PauseTorrent([FromRoute] string hash, CancellationToken cancellationToken)
    {
        return await ExecuteCommandAsync(() => _torrentClient.PauseTorrentAsync(hash, cancellationToken)).ConfigureAwait(false);
    }

    [HttpPost("MyJellyfinPlugin/Torrents/{hash}/Resume")]
    public async Task<IActionResult> ResumeTorrent([FromRoute] string hash, CancellationToken cancellationToken)
    {
        return await ExecuteCommandAsync(() => _torrentClient.ResumeTorrentAsync(hash, cancellationToken)).ConfigureAwait(false);
    }

    [HttpPost("MyJellyfinPlugin/Torrents/{hash}/Delete")]
    public async Task<IActionResult> DeleteTorrent([FromRoute] string hash, [FromBody] DeleteTorrentRequest? request, CancellationToken cancellationToken)
    {
        var deleteFiles = request?.DeleteFiles ?? false;
        return await ExecuteCommandAsync(() => _torrentClient.DeleteTorrentAsync(hash, deleteFiles, cancellationToken)).ConfigureAwait(false);
    }

    [HttpPost("MyJellyfinPlugin/Torrents/{hash}/Files/{fileIndex}/Priority")]
    public async Task<IActionResult> SetFilePriority(
        [FromRoute] string hash,
        [FromRoute] int fileIndex,
        [FromBody] SetFilePriorityRequest request,
        CancellationToken cancellationToken)
    {
        return await ExecuteCommandAsync(async () =>
        {
            if (request is null)
            {
                throw new ArgumentException("Request body is required.");
            }

            if (request.Priority < 0 || request.Priority > 7)
            {
                throw new ArgumentOutOfRangeException(nameof(request.Priority), "Priority must be between 0 and 7.");
            }

            await _torrentClient.SetFilePriorityAsync(hash, fileIndex, request.Priority, cancellationToken).ConfigureAwait(false);
        }).ConfigureAwait(false);
    }

    [HttpGet("MyJellyfinPlugin/Search")]
    public async Task<ActionResult<TorrentSearchResponse>> Search(
        [FromQuery] string q,
        [FromQuery] string? source,
        [FromQuery] int page,
        CancellationToken cancellationToken)
    {
        return await ExecuteQueryAsync(() => _torrentSearchClient.SearchAsync(q, source, page, cancellationToken))
            .ConfigureAwait(false);
    }

    [HttpGet("MyJellyfinPlugin/Tmdb/Search")]
    public async Task<ActionResult<TmdbSearchResponse>> SearchTmdb(
        [FromQuery] string q,
        CancellationToken cancellationToken)
    {
        return await ExecuteQueryAsync(() => _tmdbSearchClient.SearchAsync(q, cancellationToken))
            .ConfigureAwait(false);
    }

    [HttpGet("MyJellyfinPlugin/Tmdb/Series/{tmdbId:int}")]
    public async Task<ActionResult<TmdbSeriesDetailsResponse>> GetTmdbSeriesDetails(
        [FromRoute] int tmdbId,
        CancellationToken cancellationToken)
    {
        return await ExecuteQueryAsync(() => _tmdbSearchClient.GetSeriesDetailsAsync(tmdbId, cancellationToken))
            .ConfigureAwait(false);
    }

    [HttpGet("MyJellyfinPlugin/Tmdb/Series/{tmdbId:int}/Seasons/{seasonNumber:int}")]
    public async Task<ActionResult<TmdbSeasonDetailsResponse>> GetTmdbSeasonDetails(
        [FromRoute] int tmdbId,
        [FromRoute] int seasonNumber,
        CancellationToken cancellationToken)
    {
        return await ExecuteQueryAsync(() => _tmdbSearchClient.GetSeasonDetailsAsync(tmdbId, seasonNumber, cancellationToken))
            .ConfigureAwait(false);
    }

    private async Task<ActionResult<T>> ExecuteQueryAsync<T>(Func<Task<T>> action)
    {
        try
        {
            var payload = await action().ConfigureAwait(false);
            return Ok(payload);
        }
        catch (Exception ex)
        {
            return BuildErrorResult<T>(ex);
        }
    }

    private async Task<IActionResult> ExecuteCommandAsync(Func<Task> action)
    {
        try
        {
            await action().ConfigureAwait(false);
            return Ok(new { Success = true });
        }
        catch (Exception ex)
        {
            return BuildErrorResult(ex);
        }
    }

    private ObjectResult BuildErrorResult(Exception exception)
    {
        var (statusCode, message) = MapException(exception);
        return StatusCode(statusCode, new ErrorResponse { Error = message });
    }

    private ActionResult<T> BuildErrorResult<T>(Exception exception)
    {
        var (statusCode, message) = MapException(exception);
        return StatusCode(statusCode, new ErrorResponse { Error = message });
    }

    private (int StatusCode, string Message) MapException(Exception exception)
    {
        if (exception is ArgumentException || exception is ArgumentOutOfRangeException)
        {
            return (StatusCodes.Status400BadRequest, exception.Message);
        }

        if (exception is HttpRequestException)
        {
            _logger.LogWarning(exception, "Unable to reach qBittorrent endpoint.");
            var configuredUrl = Plugin.Instance?.Configuration.QbittorrentBaseUrl ?? "(not configured)";
            return (
                StatusCodes.Status502BadGateway,
                $"Cannot reach qBittorrent at '{configuredUrl}'. If Jellyfin runs in Docker, use the qBittorrent container hostname (for example: http://qbittorrent:8080/), not localhost.");
        }

        if (exception is TaskCanceledException)
        {
            _logger.LogWarning(exception, "qBittorrent request timed out.");
            return (StatusCodes.Status504GatewayTimeout, "qBittorrent request timed out. Check container health and network connectivity.");
        }

        if (exception is InvalidOperationException)
        {
            var upstreamStatusCode = TryExtractQbittorrentStatusCode(exception.Message);
            if (upstreamStatusCode is >= 400 and < 500)
            {
                _logger.LogWarning(exception, "qBittorrent returned client error status {StatusCode}.", upstreamStatusCode);
                return (upstreamStatusCode.Value, exception.Message);
            }

            _logger.LogWarning(exception, "Torrent operation failed.");
            return (StatusCodes.Status502BadGateway, exception.Message);
        }

        _logger.LogError(exception, "Unexpected error while processing torrent request.");
        return (StatusCodes.Status500InternalServerError, "Unexpected server error.");
    }

    private static int? TryExtractQbittorrentStatusCode(string message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            return null;
        }

        const string Marker = "qBittorrent request failed:";
        var markerIndex = message.IndexOf(Marker, StringComparison.OrdinalIgnoreCase);
        if (markerIndex < 0)
        {
            return null;
        }

        var tail = message[(markerIndex + Marker.Length)..].TrimStart();
        var firstToken = tail.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        if (int.TryParse(firstToken, out var statusCode))
        {
            return statusCode;
        }

        return null;
    }

    public sealed class AddMagnetRequest
    {
        public string MagnetLink { get; set; } = string.Empty;

        public string? SavePath { get; set; }

        public string? Category { get; set; }

        public bool? Paused { get; set; }
    }

    public sealed class DeleteTorrentRequest
    {
        public bool DeleteFiles { get; set; }
    }

    public sealed class SetFilePriorityRequest
    {
        public int Priority { get; set; }
    }

    public sealed class ErrorResponse
    {
        public string Error { get; set; } = string.Empty;
    }
}
