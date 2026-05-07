using MediaBrowser.Common.Configuration;
using MediaBrowser.Common.Plugins;
using MediaBrowser.Model.Plugins;
using MediaBrowser.Model.Serialization;
using MyJellyfinPlugin.Configuration;
using System.Globalization;

namespace MyJellyfinPlugin;

public sealed class Plugin : BasePlugin<PluginConfiguration>, IHasWebPages
{
    public static Plugin? Instance { get; private set; }

    public Plugin(IApplicationPaths applicationPaths, IXmlSerializer xmlSerializer)
        : base(applicationPaths, xmlSerializer)
    {
        Instance = this;
    }

    public override string Name => "My Jellyfin Plugin";

    public override Guid Id => Guid.Parse("693d5992-886d-4e21-941d-a7ed51c5fa32");

    public IEnumerable<PluginPageInfo> GetPages()
    {
        var resourcePath = string.Format(
            CultureInfo.InvariantCulture,
            "{0}.Configuration.configPage.html",
            GetType().Namespace);

        return
        [
            new PluginPageInfo
            {
                Name = "DownloadContent",
                DisplayName = "Download Content",
                EnableInMainMenu = true,
                MenuSection = "home",
                MenuIcon = "download",
                EmbeddedResourcePath = resourcePath
            }
        ];
    }
}