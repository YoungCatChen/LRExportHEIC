local LrPathUtils = import 'LrPathUtils'

local Model = require 'Model'

---@class RenderProfile
---@field label string
---@field fileSuffix string?
---@field format string
---@field extensions table<string, boolean>
---@field bitDepth integer
---@field colorSpace string
---@field compressionMethod string
---@field enableHDRDisplay boolean
---@field maximumCompatibility boolean

---@class ExportPlan
---@field primaryProfile RenderProfile
---@field alternateProfile RenderProfile?
---@field renderAlternate boolean
---@field keepIntermediates boolean
---@field private commandPrefix string
---@field private primaryArgument string
---@field private alternateArgument string?
local ExportPlan = {}
ExportPlan.__index = ExportPlan

---@param value any
---@return string quotedValue
local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

---@param colorSpace string
---@param label string
---@param fileSuffix string?
---@return RenderProfile
local function makeSDRTIFFProfile(colorSpace, label, fileSuffix)
  return {
    label = label,
    fileSuffix = fileSuffix,
    format = 'TIFF',
    extensions = { tif = true, tiff = true },
    bitDepth = 16,
    colorSpace = colorSpace,
    compressionMethod = 'compressionMethod_ZIP',
    enableHDRDisplay = false,
    maximumCompatibility = false,
  }
end

---@param colorSpace string
---@param label string
---@param fileSuffix string?
---@return RenderProfile
local function makeHDRTIFFProfile(colorSpace, label, fileSuffix)
  return {
    label = label,
    fileSuffix = fileSuffix,
    format = 'TIFF',
    extensions = { tif = true, tiff = true },
    bitDepth = 16,
    colorSpace = colorSpace,
    compressionMethod = 'compressionMethod_ZIP',
    enableHDRDisplay = true,
    maximumCompatibility = false,
  }
end

---@param colorSpace ColorSpaceSpec
---@param useHDR boolean
---@param hdrMode string
---@return RenderProfile primaryProfile
---@return RenderProfile? alternateProfile
local function makeRenderProfiles(colorSpace, useHDR, hdrMode)
  if not useHDR then
    return makeSDRTIFFProfile(
      colorSpace.sdr,
      LOC '$$$/LRExportHEIC/Rendition/PrimarySDR=primary SDR',
      nil
    ),
      nil
  elseif hdrMode == Model.hdrModes.hdrOnly then
    return makeHDRTIFFProfile(
      colorSpace.hdr,
      LOC '$$$/LRExportHEIC/Rendition/PrimaryHDR=primary HDR',
      nil
    ),
      nil
  end
  return makeSDRTIFFProfile(
    colorSpace.sdr,
    LOC '$$$/LRExportHEIC/Rendition/PrimarySDR=primary SDR',
    nil
  ),
    makeHDRTIFFProfile(
      colorSpace.hdr,
      LOC '$$$/LRExportHEIC/Rendition/HDRAlternate=HDR alternate',
      'alternate-hdr'
    )
end

---@param exportSettings table<string, any>
---@param profile RenderProfile
local function applyRenderProfile(exportSettings, profile)
  exportSettings.LR_format = profile.format
  exportSettings.LR_enableHDRDisplay = profile.enableHDRDisplay
  exportSettings.LR_export_enableHDRDisplay = profile.enableHDRDisplay
  exportSettings.LR_export_bitDepth = profile.bitDepth
  exportSettings.LR_export_colorSpace = profile.colorSpace
  exportSettings.LR_maximumCompatibility = profile.maximumCompatibility
  exportSettings.LR_tiff_compressionMethod = profile.compressionMethod
end

---Freezes one export's UI choices into a reusable behavioral plan.
---
---The plan owns Lightroom rendition profiles and the path-independent encoder
---command. Per-photo paths are added later without reinterpreting the UI state.
---@param properties table<string, any>
---@param converterPath string
---@return ExportPlan plan
function ExportPlan.new(properties, converterPath)
  local colorSpace = Model.colorSpaceFor(properties.HEICColorSpace)
  if properties.HEICUseHDR and not colorSpace.hdr then
    properties.HEICColorSpace = 'SRGB'
    colorSpace = Model.colorSpaces.SRGB
  end
  local hdrMode = properties.HEICHDRMode
  if
    hdrMode ~= Model.hdrModes.sdrAndGain
    and hdrMode ~= Model.hdrModes.hdrOnly
  then
    hdrMode = Model.hdrModes.sdrAndGain
    properties.HEICHDRMode = hdrMode
  end
  local primaryProfile, alternateProfile =
    makeRenderProfiles(colorSpace, properties.HEICUseHDR, hdrMode)

  local primaryArgument = '--sdr-from'
  local alternateArgument = nil

  if properties.HEICUseHDR and hdrMode == Model.hdrModes.sdrAndGain then
    alternateArgument = '--hdr-from'
  elseif properties.HEICUseHDR and hdrMode == Model.hdrModes.hdrOnly then
    primaryArgument = '--hdr-from'
  end

  local commandPrefix = shellQuote(converterPath)
    .. ' --verbose --output-bit-depth '
    .. tostring(properties.HEICBitDepth or 10)

  if properties.HEICUseSizeLimit then
    commandPrefix = commandPrefix
      .. ' --size-limit '
      .. (properties.HEICSizeLimit * 1000)
      .. ' --min-quality '
      .. (properties.HEICMinQuality / 100)
      .. ' --max-quality '
      .. (properties.HEICMaxQuality / 100)
  else
    commandPrefix = commandPrefix
      .. ' --quality '
      .. (properties.HEICQuality / 100)
  end

  -- Lightroom TIFF profiles may use a linear transfer function that should
  -- not be copied to the final HEIF. Keep the intended gamut and transfer
  -- function explicit for both SDR and native-HDR output.
  local outputColorSpace = colorSpace.output
  if properties.HEICUseHDR and hdrMode == Model.hdrModes.hdrOnly then
    outputColorSpace = assert(colorSpace.hdrOutput)
  end
  commandPrefix = commandPrefix
    .. ' --output-color-space '
    .. shellQuote(outputColorSpace)

  return setmetatable({
    primaryProfile = primaryProfile,
    alternateProfile = alternateProfile,
    renderAlternate = alternateProfile ~= nil,
    keepIntermediates = properties.HEICKeepIntermediates,
    commandPrefix = commandPrefix,
    primaryArgument = primaryArgument,
    alternateArgument = alternateArgument,
  }, ExportPlan)
end

---@param exportSettings table<string, any>
function ExportPlan:applyPrimaryRenderSettings(exportSettings)
  applyRenderProfile(exportSettings, self.primaryProfile)
end

---Builds file-export settings for the independent alternate rendition.
---@param sharedRenderSettings table<string, any>
---@param destinationPath string
---@return table<string, any> exportSettings
function ExportPlan:makeAlternateSessionSettings(
  sharedRenderSettings,
  destinationPath
)
  local profile = assert(self.alternateProfile)
  local result = {}
  for key, value in pairs(sharedRenderSettings) do
    result[key] = value
  end
  result.LR_export_destinationType = 'tempFolder'
  result.LR_export_destinationPathPrefix = LrPathUtils.parent(destinationPath)
  result.LR_export_useSubfolder = false
  result.LR_export_subfolderName = ''
  result.LR_collisionHandling = 'overwrite'
  result.LR_exportServiceProvider = 'com.adobe.ag.export.file'
  result.LR_reimportExportedPhoto = false
  result.LR_renamingTokensOn = true
  result.LR_extensionCase = 'lowercase'
  local leafName = LrPathUtils.leafName(destinationPath)
  result.LR_tokens = leafName:gsub('%.tiff$', ''):gsub('%.tif$', '')
  applyRenderProfile(result, profile)
  return result
end

---Combines the fixed export options with one rendition's concrete paths.
---@param primaryPath string
---@param alternatePath string?
---@param outputPath string
---@return string command
function ExportPlan:encoderCommand(primaryPath, alternatePath, outputPath)
  local command = self.commandPrefix
    .. ' '
    .. self.primaryArgument
    .. ' '
    .. shellQuote(primaryPath)

  if self.alternateArgument then
    assert(
      alternatePath,
      LOC '$$$/LRExportHEIC/Error/MissingAlternatePath=Missing alternate rendition path'
    )
    command = command
      .. ' '
      .. self.alternateArgument
      .. ' '
      .. shellQuote(alternatePath)
  end

  return command .. ' ' .. shellQuote(outputPath)
end

return ExportPlan
