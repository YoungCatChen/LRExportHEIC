local LrBinding = import 'LrBinding'
local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrLogger = import 'LrLogger'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local logger = LrLogger('ExportHEIC')
logger:enable('print')

function formatPercentage(num, fromModel)
  return tostring(math.floor(num)) .. ' %'
end

local function flattenExportSettings(exportSettings)
  local result = {}
  local nested = exportSettings['< contents >']
  if type(nested) == 'table' then
    for key, value in pairs(nested) do
      result[key] = value
    end
  end
  for key, value in pairs(exportSettings) do
    if key ~= '< contents >' then
      result[key] = value
    end
  end
  return result
end

local function shouldCopyAuxiliarySetting(key)
  if type(key) ~= 'string' then
    return false
  end
  if key == 'LR_minimizeEmbeddedMetadata'
      or key == 'LR_export_removeMetadata' then
    return true
  end

  local prefixes = {
    '^LR_size_',
    '^LR_resize',
    '^LR_export_resize',
    '^LR_export_dimensions',
    '^LR_export_constraints',
    '^LR_export_watermark',
    '^LR_export_metadata',
    '^LR_export_keyword',
    '^LR_outputSharpening',
  }
  for _, prefix in ipairs(prefixes) do
    if string.match(key, prefix) then
      return true
    end
  end
  return false
end

local function buildHDRExportSettings(baseExportSettings, destinationDirectory)
  local result = {}
  for key, value in pairs(flattenExportSettings(baseExportSettings)) do
    if shouldCopyAuxiliarySetting(key) then
      result[key] = value
    end
  end

  result.LR_export_destinationType = 'tempFolder'
  result.LR_export_destinationPathPrefix = destinationDirectory
  result.LR_export_useSubfolder = false
  result.LR_export_subfolderName = ''
  result.LR_collisionHandling = 'overwrite'
  result.LR_exportServiceProvider = 'com.adobe.ag.export.file'
  result.LR_reimportExportedPhoto = false
  result.LR_renamingTokensOn = true
  result.LR_extensionCase = 'lowercase'
  result.LR_tokens = '{{image_name}}'

  result.LR_format = 'TIFF'
  result.LR_tiff_compressionMethod = 'compressionMethod_ZIP'
  result.LR_export_colorSpace = 'sRGB_hdr'
  result.LR_export_bitDepth = 32
  result.LR_enableHDRDisplay = true
  result.LR_export_enableHDRDisplay = true
  result.LR_maximumCompatibility = false
  return result
end

local function makeTemporaryDirectory()
  local tempRoot = LrPathUtils.getStandardFilePath('temp')
  local leaf = string.format(
      'lr-export-heic-%d-%06d',
      os.time(),
      math.random(0, 999999))
  local path = LrPathUtils.child(tempRoot, leaf)
  LrFileUtils.createDirectory(path)
  return path
end

local function removeTemporaryDirectory(path)
  if not path then
    return
  end
  if LrFileUtils.exists(path) then
    for filePath in LrFileUtils.files(path) do
      pcall(function()
        LrFileUtils.delete(filePath)
      end)
    end
    pcall(function()
      LrFileUtils.delete(path)
    end)
  end
end

local function fileSize(path)
  local file = io.open(path, 'rb')
  if not file then
    return nil
  end
  local size = file:seek('end')
  file:close()
  return size
end

local function waitForStableFile(path)
  local previousSize = nil
  local stableChecks = 0
  for _ = 1, 40 do
    local size = fileSize(path)
    if size and size > 0 and size == previousSize then
      stableChecks = stableChecks + 1
      if stableChecks >= 2 then
        return true
      end
    else
      previousSize = size
      stableChecks = 0
    end
    LrTasks.sleep(0.1)
  end
  return false
end

local function renderHDRTIFF(
    photo,
    baseExportSettings,
    destinationDirectory)
  local exportSession = LrExportSession {
    photosToExport = { photo },
    exportSettings = buildHDRExportSettings(
        baseExportSettings,
        destinationDirectory),
  }
  exportSession:doExportOnCurrentTask()

  for _, rendition in exportSession:renditions() do
    local success, pathOrMessage = rendition:waitForRender()
    if success then
      local extension = string.lower(
          LrPathUtils.extension(pathOrMessage) or '')
      if extension ~= 'tif' and extension ~= 'tiff' then
        return nil, 'Lightroom returned a non-TIFF HDR rendition: '
            .. tostring(pathOrMessage)
      end
      if not waitForStableFile(pathOrMessage) then
        return nil, 'Lightroom did not finish writing the HDR TIFF: '
            .. tostring(pathOrMessage)
      end
      return pathOrMessage
    end
    return nil, pathOrMessage
  end
  return nil, 'Lightroom did not produce an HDR rendition'
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function encodeRendition(
    command,
    propertyTable,
    baseExportSettings,
    sourceRendition,
    sdrPath,
    outputPath)
  local hdrPath = nil
  local temporaryDirectory = nil
  local renderError = nil
  if propertyTable.HEICUseHDR then
    temporaryDirectory = makeTemporaryDirectory()
    local renderCallSucceeded = nil
    renderCallSucceeded, hdrPath, renderError = LrTasks.pcall(
        renderHDRTIFF,
        sourceRendition.photo,
        baseExportSettings,
        temporaryDirectory)
    if not renderCallSucceeded then
      renderError = hdrPath
      hdrPath = nil
    end
  end

  if propertyTable.HEICUseHDR and not hdrPath then
    removeTemporaryDirectory(temporaryDirectory)
    return false, 'HDR rendition failed: ' .. tostring(renderError)
  end

  local actualCommand = command .. ' --input-file ' .. shellQuote(sdrPath)
  if hdrPath then
    actualCommand = actualCommand
        .. ' --hdr-input-file '
        .. shellQuote(hdrPath)
  end
  actualCommand = actualCommand .. ' ' .. shellQuote(outputPath)
  local status = LrTasks.execute(actualCommand)
  removeTemporaryDirectory(temporaryDirectory)
  if status ~= 0 then
    return false, 'HEIC encoder failed with status ' .. status
  end
  return true, 'Exported HEIC to ' .. outputPath
end

return {
  exportPresetFields = {
    { key = 'HEICQuality', default = 75 },
    { key = 'HEICUseSizeLimit', default = false },
    { key = 'HEICSizeLimit', default = 3000 },
    { key = 'HEICMinQuality', default = 10 },
    { key = 'HEICMaxQuality', default = 90 },
    { key = 'HEICColorSpace', default = 'SRGB' },
    { key = 'HEICBitDepth', default = 10 },
    { key = 'HEICUseHDR', default = false },
  },
  hideSections = { 'video', 'fileSettings' },
  -- sectionsForTopOfDialog = function( viewFactory, propertyTable )
  sectionForFilterInDialog = function( viewFactory, propertyTable )
    local f = viewFactory
    local bind = LrView.bind
    local negbind = LrBinding.negativeOfKey

    return {
      title = 'HEIC Settings',

      f:row {  -- root row
        margin_top = 8,
        margin_bottom = 8,
        spacing = 18,

        f:column {  -- left-column
          spacing = 12,

          f:row {  -- control 1: quality
            f:static_text {
              title = 'Quality:', enabled = negbind 'HEICUseSizeLimit',
              width_in_chars = 8, alignment = 'right',
            },
            f:spacer { width = 2 },
            f:slider {
              value = bind 'HEICQuality',
              enabled = negbind 'HEICUseSizeLimit',
              min = 0, max = 100, integral = true,
            },
            f:static_text {
              title = bind({ key = 'HEICQuality', transform = formatPercentage }),
              enabled = negbind 'HEICUseSizeLimit',
            },
          },  -- control 1: quality

          f:row {  -- control 2: color space
            f:static_text { width_in_chars = 8, alignment = 'right', title = 'Color Space:' },
            f:spacer { width = 2 },
            f:popup_menu {
              width_in_chars = 8,
              enabled = negbind 'HEICUseHDR',
              items = {
                { title = 'sRGB', value = 'SRGB' },
                { title = 'Display P3', value = 'DisplayP3' },
                { title = 'AdobeRGB', value = 'AdobeRGB1998' },
              },
              value = bind 'HEICColorSpace'
            },
          },  -- control 2: color space

          f:row {  -- control 3: bit depth
            f:static_text { width_in_chars = 8, alignment = 'right', title = 'Bit Depth:' },
            f:spacer { width = 2 },
            f:radio_button {
              value = bind 'HEICBitDepth',
              title = '8',
              checked_value = 8,
              enabled = negbind 'HEICUseHDR',
            },
            f:radio_button {
              value = bind 'HEICBitDepth',
              title = '10',
              checked_value = 10,
              enabled = negbind 'HEICUseHDR',
            },
          },  -- control 3: bit depth

          f:row {  -- control 4: hdr
            f:static_text { width_in_chars = 8, alignment = 'right', title = 'HDR:' },
            f:spacer { width = 2 },
            f:checkbox {
              value = bind 'HEICUseHDR',
              title = 'Export HDR HEIC',
            },
          },  -- control 4: hdr

        },  -- left-column

        f:column {  -- right column
          spacing = 12,

          f:row {  -- control 1: file size
            f:checkbox { value = bind 'HEICUseSizeLimit', title = 'Limit File Size To:' },
            f:edit_field {
              value = bind 'HEICSizeLimit',
              enabled = bind 'HEICUseSizeLimit',
              increment = 100, large_increment = 1000,
              min = 1, max = 1000000,
              width_in_digits = 7,
            },
            f:static_text { title = 'K' },
          },  -- control 1: file size

          f:view {  -- control 2: min quality
            visible = bind 'HEICUseSizeLimit',
            place = 'horizontal',
            f:static_text { width_in_chars = 9, title = 'Minimal Quality:' },
            f:slider {
              value = bind 'HEICMinQuality',
              min = 0, max = 100, integral = true,
            },
            f:static_text {
              title = bind({ key = 'HEICMinQuality', transform = formatPercentage })
            },
          },

          f:view {  -- control 3: max quality
            visible = bind 'HEICUseSizeLimit',
            place = 'horizontal',
            f:static_text { width_in_chars = 9, title = 'Maximal Quality:' },
            f:slider {
              value = bind 'HEICMaxQuality',
              min = 0, max = 100, integral = true,
            },
            f:static_text {
              title = bind({ key = 'HEICMaxQuality', transform = formatPercentage })
            },
          },
        },  -- right column

      }  -- root row
    }
  end,
  postProcessRenderedPhotos = function(functionContext, filterContext)
    local p = filterContext.propertyTable
    local baseExportSettings = p

    local renditionOptions = {
      filterSettings = function( renditionToSatisfy, exportSettings )
        if p.HEICUseHDR then
          baseExportSettings = flattenExportSettings(exportSettings)
          exportSettings.LR_format = 'TIFF'
          exportSettings.LR_enableHDRDisplay = false
          exportSettings.LR_export_enableHDRDisplay = false
          exportSettings.LR_export_bitDepth = 16
          exportSettings.LR_export_colorSpace = 'sRGB'
          exportSettings.LR_maximumCompatibility = true
          exportSettings.LR_tiff_compressionMethod =
              'compressionMethod_None'
        elseif p.HEICBitDepth > 8 then
          exportSettings.LR_format = 'TIFF'
          exportSettings.LR_export_bitDepth = 16

          if p.HEICColorSpace == "SRGB" then
            exportSettings.LR_export_colorSpace = "sRGB"
          elseif p.HEICColorSpace == "AdobeRGB1998" then
            exportSettings.LR_export_colorSpace = "AdobeRGB"
          elseif p.HEICColorSpace == "DisplayP3" then
            exportSettings.LR_export_colorSpace = "DisplayP3"
          end
        else
          exportSettings.LR_format = 'TIFF'
          exportSettings.LR_export_bitDepth = 8

          if p.HEICColorSpace == "SRGB" then
            exportSettings.LR_export_colorSpace = "sRGB"
          elseif p.HEICColorSpace == "AdobeRGB1998" then
            exportSettings.LR_export_colorSpace = "AdobeRGB"
          elseif p.HEICColorSpace == "DisplayP3" then
            exportSettings.LR_export_colorSpace = "DisplayP3"
          end
        end
        return os.tmpname()
      end,
    }

    local converterPath = LrPathUtils.child(
        _PLUGIN.path,
        'ConverterWrapper.app/Contents/MacOS/ConvertToHeic')
    local cmd = shellQuote(converterPath)
    if p.HEICUseSizeLimit then
      cmd = (cmd .. ' --size-limit ' .. (p.HEICSizeLimit * 1000)
             .. ' --min-quality ' .. (p.HEICMinQuality / 100)
             .. ' --max-quality ' .. (p.HEICMaxQuality / 100))
    else
      cmd = cmd .. ' --quality ' .. (p.HEICQuality / 100)
    end
    if p.HEICUseHDR then
      cmd = cmd .. ' --hdr-output'
    end

    logger:info('Starting rendering of originals')
    for sourceRendition, renditionToSatisfy in  filterContext:renditions(renditionOptions) do
      logger:info('Processing rendition')
      local success, pathOrMessage = sourceRendition:waitForRender()
      if success then
        local encoded, message = encodeRendition(
            cmd,
            p,
            baseExportSettings,
            sourceRendition,
            pathOrMessage,
            renditionToSatisfy.destinationPath)
        if not encoded then
          logger:error(message)
          renditionToSatisfy:renditionIsDone(false, message)
          break
        end
        logger:info(message)
        renditionToSatisfy:renditionIsDone(true, message)
      else
        logger:info('Source rendition did not finish rendering: ' .. pathOrMessage)
        renditionToSatisfy:renditionIsDone(false, pathOrMessage)
        break
      end
    end
  end,
  -- processRenderedPhotos = function(functionContext, exportContext)
  -- end
}
