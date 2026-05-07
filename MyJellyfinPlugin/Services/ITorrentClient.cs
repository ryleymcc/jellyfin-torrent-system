namespace MyJellyfinPlugin.Services;

public interface ITorrentClient
{
    Task<IReadOnlyList<TorrentSummary>> GetTorrentsAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<TorrentFileSummary>> GetTorrentFilesAsync(string hash, CancellationToken cancellationToken);

    Task AddMagnetAsync(string magnetLink, string? savePath, string? category, bool? paused, CancellationToken cancellationToken);

    Task PauseTorrentAsync(string hash, CancellationToken cancellationToken);

    Task ResumeTorrentAsync(string hash, CancellationToken cancellationToken);

    Task DeleteTorrentAsync(string hash, bool deleteFiles, CancellationToken cancellationToken);

    Task SetFilePriorityAsync(string hash, int fileIndex, int priority, CancellationToken cancellationToken);
}
