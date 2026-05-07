using MediaBrowser.Controller;
using MediaBrowser.Controller.Plugins;
using Microsoft.Extensions.DependencyInjection;
using MyJellyfinPlugin.Services;

namespace MyJellyfinPlugin;

public sealed class PluginServiceRegistrator : IPluginServiceRegistrator
{
    public void RegisterServices(IServiceCollection serviceCollection, IServerApplicationHost applicationHost)
    {
        serviceCollection.AddSingleton<ITorrentClient, QbittorrentClient>();
        serviceCollection.AddSingleton<ITorrentSearchClient, TorrentSearchClient>();
        serviceCollection.AddSingleton<ITmdbSearchClient, TmdbSearchClient>();
    }
}
