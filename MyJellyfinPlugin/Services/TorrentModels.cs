namespace MyJellyfinPlugin.Services;

public sealed class TorrentSummary
{
    public string Hash { get; set; } = string.Empty;

    public string Name { get; set; } = string.Empty;

    public string State { get; set; } = string.Empty;

    public double Progress { get; set; }

    public long DownloadSpeed { get; set; }

    public long UploadSpeed { get; set; }

    public long TotalSize { get; set; }

    public long DownloadedBytes { get; set; }

    public long EtaSeconds { get; set; }

    public double Ratio { get; set; }
}

public sealed class TorrentFileSummary
{
    public int Index { get; set; }

    public string Name { get; set; } = string.Empty;

    public long Size { get; set; }

    public double Progress { get; set; }

    public int Priority { get; set; }

    public bool IsSeed { get; set; }
}

public sealed class TorrentSearchResult
{
    public string Name { get; set; } = string.Empty;

    public string Magnet { get; set; } = string.Empty;

    public string Source { get; set; } = string.Empty;

    public string? Category { get; set; }

    public string? Size { get; set; }

    public string? Seeders { get; set; }

    public string? Leechers { get; set; }

    public string? Url { get; set; }
}

public sealed class TorrentSearchResponse
{
    public string Query { get; set; } = string.Empty;

    public string Source { get; set; } = string.Empty;

    public int Page { get; set; }

    public bool HasPreviousPage { get; set; }

    public bool HasNextPage { get; set; }

    public int ReturnedCount { get; set; }

    public IReadOnlyList<TorrentSearchResult> Results { get; set; } = [];
}

public sealed class TmdbSearchResult
{
    public int TmdbId { get; set; }

    public string Title { get; set; } = string.Empty;

    public string DisplayTitle { get; set; } = string.Empty;

    public string SearchTitle { get; set; } = string.Empty;

    public string MediaType { get; set; } = string.Empty;

    public int? ReleaseYear { get; set; }

    public string? PosterUrl { get; set; }

    public string? Overview { get; set; }
}

public sealed class TmdbSearchResponse
{
    public string Query { get; set; } = string.Empty;

    public bool Configured { get; set; }

    public int ReturnedCount { get; set; }

    public IReadOnlyList<TmdbSearchResult> Results { get; set; } = [];
}

public sealed class TmdbSeasonSummary
{
    public int SeasonNumber { get; set; }

    public string Name { get; set; } = string.Empty;

    public int EpisodeCount { get; set; }

    public string? PosterUrl { get; set; }
}

public sealed class TmdbSeriesDetailsResponse
{
    public int TmdbId { get; set; }

    public string Title { get; set; } = string.Empty;

    public IReadOnlyList<TmdbSeasonSummary> Seasons { get; set; } = [];
}

public sealed class TmdbEpisodeSummary
{
    public int EpisodeNumber { get; set; }

    public string Name { get; set; } = string.Empty;

    public string DisplayTitle { get; set; } = string.Empty;
}

public sealed class TmdbSeasonDetailsResponse
{
    public int TmdbId { get; set; }

    public int SeasonNumber { get; set; }

    public IReadOnlyList<TmdbEpisodeSummary> Episodes { get; set; } = [];
}
