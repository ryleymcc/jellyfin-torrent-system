using MediaBrowser.Model.Plugins;

namespace MyJellyfinPlugin.Configuration;

public sealed class PluginConfiguration : BasePluginConfiguration
{
	public PluginConfiguration()
	{
		QbittorrentBaseUrl = "http://qbittorrent:8080/";
		QbittorrentUsername = "admin";
		QbittorrentPassword = "adminadmin";
		DefaultSavePath = "/downloads";
		DefaultCategory = "jellyfin";
		AddMagnetPausedByDefault = false;
		StopSeedingOnCompletion = true;
		AutoRefreshSeconds = 5;
		SearchApiBaseUrl = "http://torrent-search:3001/";
		SearchApiDefaultSource = "piratebay";
		TmdbApiKey = string.Empty;
	}

	public string QbittorrentBaseUrl { get; set; }

	public string QbittorrentUsername { get; set; }

	public string QbittorrentPassword { get; set; }

	public string DefaultSavePath { get; set; }

	public string DefaultCategory { get; set; }

	public bool AddMagnetPausedByDefault { get; set; }

	public bool StopSeedingOnCompletion { get; set; }

	public int AutoRefreshSeconds { get; set; }

	public string SearchApiBaseUrl { get; set; }

	public string SearchApiDefaultSource { get; set; }

	public string TmdbApiKey { get; set; }
}