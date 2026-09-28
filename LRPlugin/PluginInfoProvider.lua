return {
  sectionsForTopOfDialog = function(viewFactory, propertyTable)
    return {
      {
        title = LOC '$$$/LRExportHEIC/PluginInfo/Title=Export HEIC plugin',
        viewFactory:column {
          viewFactory:static_text {
            title = LOC(
              '$$$/LRExportHEIC/PluginInfo/Description=This plugin allows '
                .. 'exporting files as HEIC on macOS.'
            ),
          },
          viewFactory:spacer { height = 12 },
          viewFactory:static_text {
            title = LOC(
              '$$$/LRExportHEIC/PluginInfo/Credits=Created by '
                .. 'Manu Wallner (GitHub: @milch) and '
                .. 'YoungCat (GitHub: @YoungCatChen). '
                .. 'Contributions by @uannzi.'
            ),
          },
        },
      },
    }
  end,
}
