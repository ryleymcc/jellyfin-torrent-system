namespace MyJellyfinPlugin.Services;

public interface ITorrentSearchClient
{
    Task<TorrentSearchResponse> SearchAsync(string query, string? source, int page, CancellationToken cancellationToken);
}
