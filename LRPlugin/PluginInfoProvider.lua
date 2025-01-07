return {
  sectionsForTopOfDialog = function( viewFactory, propertyTable )
    return {
      {
        title = 'Export HEIC plugin',
        viewFactory:column {
          viewFactory:static_text {
            title = 'This plugin allows exporting files as HEIC on macOS.'
          },
          viewFactory:spacer { height = 12 },
          viewFactory:static_text {
            title = 'Created by Manu Wallner (GitHub: @milch) and YoungCat (GitHub: @YoungCatChen).'
          },
        }
      }
    }
  end
}
