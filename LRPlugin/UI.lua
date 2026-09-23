local LrBinding = import 'LrBinding'
local LrView = import 'LrView'

local Model = require 'Model'

local UI = {}
local dialogObserver = {}

---@param observer table
---@param propertyTable table<string, any>
local function constrainHDRColorSpace(observer, propertyTable)
  local colorSpace = Model.colorSpaces[propertyTable.HEICColorSpace]
  if not colorSpace or propertyTable.HEICUseHDR and not colorSpace.hdr then
    propertyTable.HEICColorSpace = 'SRGB'
  end
end

---@param observer table
---@param propertyTable table<string, any>
local function constrainMinimumQuality(observer, propertyTable)
  local minimum = tonumber(propertyTable.HEICMinQuality)
  local maximum = tonumber(propertyTable.HEICMaxQuality)
  if minimum and maximum and minimum > maximum then
    propertyTable.HEICMaxQuality = minimum
  end
end

---@param observer table
---@param propertyTable table<string, any>
local function constrainMaximumQuality(observer, propertyTable)
  local minimum = tonumber(propertyTable.HEICMinQuality)
  local maximum = tonumber(propertyTable.HEICMaxQuality)
  if minimum and maximum and maximum < minimum then
    propertyTable.HEICMinQuality = maximum
  end
end

---@param hdrMode string
---@return string
local function gainMapResolutionTitle(hdrMode)
  if hdrMode == Model.hdrModes.hdrAndInverseGain then
    return 'Recovery Map Resolution:'
  end
  return 'Gain Map Resolution:'
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
  propertyTable:addObserver(
    'HEICMinQuality',
    dialogObserver,
    constrainMinimumQuality
  )
  propertyTable:addObserver(
    'HEICMaxQuality',
    dialogObserver,
    constrainMaximumQuality
  )
  constrainHDRColorSpace(dialogObserver, propertyTable)
  constrainMinimumQuality(dialogObserver, propertyTable)
end

---@param propertyTable table<string, any>
---@param why string
function UI.endDialog(propertyTable, why)
  propertyTable:removeObserver('HEICUseHDR', dialogObserver)
  propertyTable:removeObserver('HEICColorSpace', dialogObserver)
  propertyTable:removeObserver('HEICMinQuality', dialogObserver)
  propertyTable:removeObserver('HEICMaxQuality', dialogObserver)
end

---Builds the HEIC settings section in Lightroom's export dialog.
---@param viewFactory any
---@param propertyTable table<string, any>
---@return table
function UI.sectionForFilterInDialog(viewFactory, propertyTable)
  local f = viewFactory
  local bind = LrView.bind
  local negbind = LrBinding.negativeOfKey
  local encodingLabelWidth = 80
  local qualitySliderWidth = 120
  local hdrLabelWidth = 140
  local function bindGainMapResEnabled()
    return bind({
      keys = { 'HEICUseHDR', 'HEICHDRMode' },
      operation = function(binder, v)
        return v.HEICUseHDR and v.HEICHDRMode ~= Model.hdrModes.hdrOnly
      end,
    })
  end
  local function bindGainMapSourceEnabled()
    return bind({
      keys = { 'HEICUseHDR', 'HEICHDRMode' },
      operation = function(binder, v)
        return v.HEICUseHDR and v.HEICHDRMode == Model.hdrModes.sdrAndGain
      end,
    })
  end

  return {
    title = 'HEIC Settings',

    f:row {
      fill_horizontal = 0,
      spacing = 12,

      f:group_box {
        title = 'Encoding',
        fill_vertical = 1,
        spacing = 8,

        f:row {
          spacing = 4,
          f:static_text {
            title = 'Quality:',
            enabled = negbind 'HEICUseSizeLimit',
            width = encodingLabelWidth,
            alignment = 'right',
          },
          f:slider {
            value = bind 'HEICQuality',
            enabled = negbind 'HEICUseSizeLimit',
            min = 0,
            max = 100,
            integral = true,
            width = qualitySliderWidth,
            place_vertical = 0.5,
          },
          f:edit_field {
            value = bind 'HEICQuality',
            enabled = negbind 'HEICUseSizeLimit',
            min = 0,
            max = 100,
            precision = 0,
            immediate = true,
            width_in_digits = 3,
          },
          f:static_text {
            title = '%',
            enabled = negbind 'HEICUseSizeLimit',
          },
        },

        f:row {
          spacing = 4,
          f:static_text { width = encodingLabelWidth },
          f:static_text { width = 0 },
          f:checkbox {
            title = 'Limit file size to:',
            value = bind 'HEICUseSizeLimit',
          },
          f:edit_field {
            value = bind 'HEICSizeLimit',
            enabled = bind 'HEICUseSizeLimit',
            increment = 100,
            large_increment = 1000,
            min = 1,
            max = 1000000,
            precision = 0,
            immediate = true,
            width_in_digits = 7,
          },
          f:static_text {
            title = 'KB',
            enabled = bind 'HEICUseSizeLimit',
          },
        },

        f:row {
          spacing = 4,
          f:static_text {
            title = 'Minimum:',
            enabled = bind 'HEICUseSizeLimit',
            width = encodingLabelWidth,
            alignment = 'right',
          },
          f:slider {
            value = bind 'HEICMinQuality',
            enabled = bind 'HEICUseSizeLimit',
            min = 0,
            max = 100,
            integral = true,
            width = qualitySliderWidth,
            place_vertical = 0.5,
          },
          f:edit_field {
            value = bind 'HEICMinQuality',
            enabled = bind 'HEICUseSizeLimit',
            min = 0,
            max = 100,
            precision = 0,
            immediate = true,
            width_in_digits = 3,
          },
          f:static_text {
            title = '%',
            enabled = bind 'HEICUseSizeLimit',
          },
        },

        f:row {
          spacing = 4,
          f:static_text {
            title = 'Maximum:',
            enabled = bind 'HEICUseSizeLimit',
            width = encodingLabelWidth,
            alignment = 'right',
          },
          f:slider {
            value = bind 'HEICMaxQuality',
            enabled = bind 'HEICUseSizeLimit',
            min = 0,
            max = 100,
            integral = true,
            width = qualitySliderWidth,
            place_vertical = 0.5,
          },
          f:edit_field {
            value = bind 'HEICMaxQuality',
            enabled = bind 'HEICUseSizeLimit',
            min = 0,
            max = 100,
            precision = 0,
            immediate = true,
            width_in_digits = 3,
          },
          f:static_text {
            title = '%',
            enabled = bind 'HEICUseSizeLimit',
          },
        },

        f:row {
          spacing = 4,
          f:static_text {
            title = 'Bit Depth:',
            width = encodingLabelWidth,
            alignment = 'right',
          },
          f:popup_menu {
            items = Model.bitDepthItems,
            value = bind 'HEICBitDepth',
            width_in_chars = 15,
          },
          f:static_text {
            title = 'ⓘ',
            tooltip = 'Controls the HEIF primary image bit depth. '
              .. 'The HDR gain map is encoded separately.',
          },
        },

        f:row {
          spacing = 4,
          f:static_text {
            title = 'Color Space:',
            width = encodingLabelWidth,
            alignment = 'right',
          },
          f:popup_menu {
            width_in_chars = 15,
            items = bind({
              key = 'HEICUseHDR',
              transform = Model.colorSpaceItems,
            }),
            value = bind 'HEICColorSpace',
          },
        },
      },

      f:column {
        fill_horizontal = 1,
        spacing = 12,

        f:group_box {
          title = 'HDR',
          fill_horizontal = 1,
          spacing = 8,

          f:row {
            margin_left = hdrLabelWidth - 8,
            f:checkbox {
              title = 'HDR Output',
              value = bind 'HEICUseHDR',
            },
          },

          f:row {
            spacing = 4,
            f:static_text {
              title = 'Mode:',
              width = hdrLabelWidth,
              alignment = 'right',
              enabled = bind 'HEICUseHDR',
            },
            f:popup_menu {
              value = bind 'HEICHDRMode',
              enabled = bind 'HEICUseHDR',
              items = Model.hdrModeItems,
              width_in_chars = 26,
            },
          },

          f:row {
            spacing = 4,
            f:static_text {
              title = bind({
                key = 'HEICHDRMode',
                transform = gainMapResolutionTitle,
              }),
              width = hdrLabelWidth,
              alignment = 'right',
              enabled = bindGainMapResEnabled(),
            },
            f:static_text { width = 0 },
            f:radio_button {
              title = '1:1',
              value = bind 'HEICGainMapSubsampleFactor',
              enabled = bindGainMapResEnabled(),
              checked_value = 1,
            },
            f:radio_button {
              title = '1/2',
              value = bind 'HEICGainMapSubsampleFactor',
              enabled = bindGainMapResEnabled(),
              checked_value = 2,
            },
            f:radio_button {
              title = '1/3',
              value = bind 'HEICGainMapSubsampleFactor',
              enabled = bindGainMapResEnabled(),
              checked_value = 3,
            },
            f:radio_button {
              title = '1/4',
              value = bind 'HEICGainMapSubsampleFactor',
              enabled = bindGainMapResEnabled(),
              checked_value = 4,
            },
          },

          f:row {
            spacing = 4,
            f:static_text {
              title = 'Gain Map Source:',
              width = hdrLabelWidth,
              alignment = 'right',
              enabled = bindGainMapSourceEnabled(),
            },
            f:popup_menu {
              value = bind 'HEICGainMapSource',
              enabled = bindGainMapSourceEnabled(),
              items = Model.gainMapSourceItems,
              width_in_chars = 26,
            },
          },
        },

        f:group_box {
          title = 'Diagnostics',
          fill_horizontal = 1,
          spacing = 8,
          margin_left = 12,

          f:checkbox {
            value = bind 'HEICKeepIntermediates',
            title = 'Keep intermediate files',
            tooltip = 'Preserves Lightroom-rendered encoder inputs next '
              .. 'to the output for inspection.',
          },
        },
      },
    },
  }
end

return UI
