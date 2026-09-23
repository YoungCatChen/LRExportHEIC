local LrBinding = import 'LrBinding'
local LrView = import 'LrView'

local Model = require 'Model'

local UI = {}
local dialogObserver = {}

---@param num number
---@param fromModel boolean?
---@return string
local function formatPercentage(num, fromModel)
  return tostring(math.floor(num)) .. ' %'
end

---@param propertyTable table<string, any>
local function constrainHDRColorSpace(propertyTable)
  local colorSpace = Model.colorSpaces[propertyTable.HEICColorSpace]
  if not colorSpace or propertyTable.HEICUseHDR and not colorSpace.hdr then
    propertyTable.HEICColorSpace = 'SRGB'
  end
end

---@param propertyTable table<string, any>
function UI.startDialog(propertyTable)
  propertyTable:addObserver(
    'HEICUseHDR',
    dialogObserver,
    constrainHDRColorSpace
  )
  propertyTable:addObserver(
    'HEICColorSpace',
    dialogObserver,
    constrainHDRColorSpace
  )
  constrainHDRColorSpace(propertyTable)
end

---@param propertyTable table<string, any>
---@param why string
function UI.endDialog(propertyTable, why)
  propertyTable:removeObserver('HEICUseHDR', dialogObserver)
  propertyTable:removeObserver('HEICColorSpace', dialogObserver)
end

---Builds the HEIC settings section in Lightroom's export dialog.
---@param viewFactory any
---@param propertyTable table<string, any>
---@return table
function UI.sectionForFilterInDialog(viewFactory, propertyTable)
  local f = viewFactory
  local bind = LrView.bind
  local negbind = LrBinding.negativeOfKey

  return {
    title = 'HEIC Settings',

    f:row {
      margin_top = 8,
      margin_bottom = 8,
      spacing = 18,

      f:column {
        spacing = 12,

        f:row {
          f:static_text {
            title = 'Quality:',
            enabled = negbind 'HEICUseSizeLimit',
            width_in_chars = 8,
            alignment = 'right',
          },
          f:spacer { width = 2 },
          f:slider {
            value = bind 'HEICQuality',
            enabled = negbind 'HEICUseSizeLimit',
            min = 0,
            max = 100,
            integral = true,
          },
          f:static_text {
            title = bind({
              key = 'HEICQuality',
              transform = formatPercentage,
            }),
            enabled = negbind 'HEICUseSizeLimit',
          },
        },

        f:row {
          f:static_text {
            width_in_chars = 8,
            alignment = 'right',
            title = 'Color Space:',
          },
          f:spacer { width = 2 },
          f:popup_menu {
            width_in_chars = 8,
            items = bind({
              key = 'HEICUseHDR',
              transform = Model.colorSpaceItems,
            }),
            value = bind 'HEICColorSpace',
          },
        },

        f:row {
          f:static_text {
            width_in_chars = 8,
            alignment = 'right',
            title = 'Bit Depth:',
          },
          f:spacer { width = 2 },
          f:radio_button {
            value = bind 'HEICBitDepth',
            title = '8',
            checked_value = 8,
            tooltip = 'Controls the HEIF primary image bit depth. '
              .. 'The HDR gain map is encoded separately.',
          },
          f:radio_button {
            value = bind 'HEICBitDepth',
            title = '10',
            checked_value = 10,
            tooltip = 'Controls the HEIF primary image bit depth. '
              .. 'The HDR gain map is encoded separately.',
          },
        },

        f:row {
          f:static_text {
            width_in_chars = 8,
            alignment = 'right',
            title = 'HDR:',
          },
          f:spacer { width = 2 },
          f:checkbox {
            value = bind 'HEICUseHDR',
            title = 'Export HDR HEIC',
          },
        },

        f:row {
          f:static_text { width_in_chars = 8, title = '' },
          f:spacer { width = 2 },
          f:checkbox {
            value = bind 'HEICKeepIntermediateTIFFs',
            title = 'Keep intermediate TIFFs',
            tooltip = 'Preserves the Lightroom-rendered TIFF inputs next to '
              .. 'the output for inspection.',
          },
        },
      },

      f:column {
        spacing = 12,

        f:row {
          f:checkbox {
            value = bind 'HEICUseSizeLimit',
            title = 'Limit File Size To:',
          },
          f:edit_field {
            value = bind 'HEICSizeLimit',
            enabled = bind 'HEICUseSizeLimit',
            increment = 100,
            large_increment = 1000,
            min = 1,
            max = 1000000,
            width_in_digits = 7,
          },
          f:static_text { title = 'K' },
        },

        f:view {
          visible = bind 'HEICUseSizeLimit',
          place = 'horizontal',
          f:static_text { width_in_chars = 9, title = 'Minimal Quality:' },
          f:slider {
            value = bind 'HEICMinQuality',
            min = 0,
            max = 100,
            integral = true,
          },
          f:static_text {
            title = bind({
              key = 'HEICMinQuality',
              transform = formatPercentage,
            }),
          },
        },

        f:view {
          visible = bind 'HEICUseSizeLimit',
          place = 'horizontal',
          f:static_text { width_in_chars = 9, title = 'Maximal Quality:' },
          f:slider {
            value = bind 'HEICMaxQuality',
            min = 0,
            max = 100,
            integral = true,
          },
          f:static_text {
            title = bind({
              key = 'HEICMaxQuality',
              transform = formatPercentage,
            }),
          },
        },
      },
    },
  }
end

return UI
