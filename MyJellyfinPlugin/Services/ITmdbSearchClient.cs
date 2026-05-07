namespace MyJellyfinPlugin.Services;

public interface ITmdbSearchClient
{
    Task<TmdbSearchResponse> SearchAsync(string query, CancellationToken cancellationToken);

    Task<TmdbSeriesDetailsResponse> GetSeriesDetailsAsync(int tmdbId, CancellationToken cancellationToken);

    Task<TmdbSeasonDetailsResponse> GetSeasonDetailsAsync(int tmdbId, int seasonNumber, CancellationToken cancellationToken);
}