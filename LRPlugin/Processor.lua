local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrLogger = import 'LrLogger'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local Model = require 'Model'

local Processor = {}
local logger = LrLogger('ExportHEIC')
logger:enable('print')

---@param exportSettings table<string, any>
---@return table<string, any> flattenedSettings
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

---@param key any
---@return boolean
local function shouldShareRenderSetting(key)
  if type(key) ~= 'string' then
    return false
  end
  if
    key == 'LR_minimizeEmbeddedMetadata'
    or key == 'LR_export_removeMetadata'
  then
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

---Captures settings that both Lightroom renderings must share.
---@param exportSettings table<string, any>
---@return table<string, any> sharedRenderSettings
local function captureSharedRenderSettings(exportSettings)
  local result = {}
  for key, value in pairs(flattenExportSettings(exportSettings)) do
    if shouldShareRenderSetting(key) then
      result[key] = value
    end
  end
  return result
end

---@class RenderProfile
---@field label string
---@field format string
---@field extensions table<string, boolean>
---@field bitDepth integer
---@field colorSpace string
---@field compressionMethod string
---@field enableHDRDisplay boolean
---@field maximumCompatibility boolean

---@class RenderProfiles
---@field primary RenderProfile
---@field hdrAlternate RenderProfile?

---@param colorSpace ColorSpaceSpec
---@return RenderProfiles profiles
local function makeRenderProfiles(colorSpace)
  local hdrAlternate = nil
  if colorSpace.hdr then
    hdrAlternate = {
      label = 'HDR alternate',
      format = 'TIFF',
      extensions = { tif = true, tiff = true },
      bitDepth = 32,
      colorSpace = colorSpace.hdr,
      compressionMethod = 'compressionMethod_ZIP',
      enableHDRDisplay = true,
      maximumCompatibility = false,
    }
  end
  return {
    primary = {
      label = 'primary SDR',
      format = 'TIFF',
      extensions = { tif = true, tiff = true },
      bitDepth = 16,
      colorSpace = colorSpace.sdr,
      compressionMethod = 'compressionMethod_ZIP',
      enableHDRDisplay = false,
      maximumCompatibility = false,
    },
    hdrAlternate = hdrAlternate,
  }
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

---Builds the file-export settings for the alternate rendering session.
---@param sharedRenderSettings table<string, any>
---@param destinationDirectory string
---@param profile RenderProfile
---@return table<string, any> exportSettings
local function makeAlternateSessionSettings(
  sharedRenderSettings,
  destinationDirectory,
  profile
)
  local result = {}
  for key, value in pairs(sharedRenderSettings) do
    result[key] = value
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
  result.LR_tokens = '{{image_name}}-alternate-hdr'

  applyRenderProfile(result, profile)
  return result
end

---@return string path
local function createWorkingDirectory()
  -- Isolating each rendition keeps both inputs together, prevents filename
  -- collisions, and gives the plug-in one directory to clean up.
  local tempRoot = LrPathUtils.getStandardFilePath('temp')
  local leaf =
    string.format('lr-export-heic-%d-%06d', os.time(), math.random(0, 999999))
  local path = LrPathUtils.child(tempRoot, leaf)
  LrFileUtils.createDirectory(path)
  if LrFileUtils.exists(path) ~= 'directory' then
    error('Could not create temp directory: ' .. path)
  end
  return path
end

---@param path string?
local function deleteDir(path)
  if not path then
    return
  end
  pcall(function()
    LrFileUtils.delete(path)
  end)
end

---@class LightroomRendition
---@field photo any
---@field destinationPath string
---@field waitForRender fun(self: any): boolean, string
---@field renditionIsDone fun(self: any, success: boolean, message: string)

---@param rendition LightroomRendition
---@param profile RenderProfile
---@return string path
local function waitForRender(rendition, profile)
  local success, pathOrMessage = rendition:waitForRender()
  if not success then
    error(profile.label .. ' rendition failed: ' .. tostring(pathOrMessage))
  end
  local extension = string.lower(LrPathUtils.extension(pathOrMessage) or '')
  if not profile.extensions[extension] then
    error(
      'Lightroom returned an unexpected '
        .. profile.label
        .. ' rendition: '
        .. tostring(pathOrMessage)
    )
  end
  return pathOrMessage
end

---Renders the HDR alternate in a separate Lightroom export session.
---@param photo any
---@param sharedRenderSettings table<string, any>
---@param destinationDirectory string
---@param profile RenderProfile
---@return string path
local function renderAlternate(
  photo,
  sharedRenderSettings,
  destinationDirectory,
  profile
)
  local exportSession = LrExportSession {
    photosToExport = { photo },
    exportSettings = makeAlternateSessionSettings(
      sharedRenderSettings,
      destinationDirectory,
      profile
    ),
  }
  exportSession:doExportOnCurrentTask()

  for _, rendition in exportSession:renditions() do
    return waitForRender(rendition, profile)
  end
  error('Lightroom did not produce an ' .. profile.label .. ' rendition')
end

---@param value any
---@return string quotedValue
local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

---@param status number
---@return number exitCode
local function decodeExitStatus(status)
  if status >= 256 then
    return math.floor(status / 256)
  end
  return status
end

---@param path string
---@return string output
local function readEncoderOutput(path)
  if not LrFileUtils.exists(path) then
    return ''
  end
  local readSucceeded, contentsOrError = pcall(LrFileUtils.readFile, path)
  if not readSucceeded then
    return 'Could not read encoder output: ' .. tostring(contentsOrError)
  end

  local contents = contentsOrError:gsub('%s+$', '')
  local maximumLength = 16384
  if #contents > maximumLength then
    return contents:sub(1, maximumLength)
      .. '\n... encoder output truncated ...'
  end
  return contents
end

---@param sourcePath string
---@param destinationPath string
local function moveOrCopyReplacing(sourcePath, destinationPath)
  if LrFileUtils.exists(destinationPath) then
    local deleted, deleteError = LrFileUtils.delete(destinationPath)
    if not deleted then
      error('Could not replace preserved input: ' .. tostring(deleteError))
    end
  end

  local moved, moveError = LrFileUtils.move(sourcePath, destinationPath)
  if moved then
    return
  end

  local copied, copyError = LrFileUtils.copy(sourcePath, destinationPath)
  if copied then
    return
  end
  error(
    'Could not preserve encoder input; move failed: '
      .. tostring(moveError)
      .. '; copy failed: '
      .. tostring(copyError)
  )
end

---Moves encoder inputs beside the output, copying only across filesystems.
---@param primaryPath string
---@param hdrAlternatePath string?
---@param outputPath string
---@return string[] preservedPaths
local function preserveEncoderInputs(primaryPath, hdrAlternatePath, outputPath)
  local paths = {}
  local preservedPrimaryPath = outputPath .. '.intermediate.tif'
  moveOrCopyReplacing(primaryPath, preservedPrimaryPath)
  table.insert(paths, preservedPrimaryPath)

  if hdrAlternatePath then
    local preservedHdrAltPath = outputPath .. '.intermediate-alternate-hdr.tif'
    moveOrCopyReplacing(hdrAlternatePath, preservedHdrAltPath)
    table.insert(paths, preservedHdrAltPath)
  end
  return paths
end

---Invokes the Swift encoder with the rendered primary and optional alternate.
---@param command string
---@param primaryPath string
---@param hdrAlternatePath string?
---@param outputPath string
---@param workingDirectory string
---@return string message
local function runEncoder(
  command,
  primaryPath,
  hdrAlternatePath,
  outputPath,
  workingDirectory
)
  local encoderCommand = command .. ' --input-file ' .. shellQuote(primaryPath)
  if hdrAlternatePath then
    encoderCommand = encoderCommand
      .. ' --hdr-input-file '
      .. shellQuote(hdrAlternatePath)
  end
  encoderCommand = encoderCommand .. ' ' .. shellQuote(outputPath)
  local logPath = LrPathUtils.child(workingDirectory, 'encoder-output.log')
  local executedCommand = encoderCommand
    .. ' > '
    .. shellQuote(logPath)
    .. ' 2>&1'
  local status = LrTasks.execute(executedCommand)
  local encoderOutput = readEncoderOutput(logPath)
  if status ~= 0 then
    local exitCode = decodeExitStatus(status)
    local message = 'HEIC encoder failed with exit code '
      .. exitCode
      .. ' (raw status '
      .. status
      .. ')'
      .. '\nCommand: '
      .. encoderCommand
    if encoderOutput ~= '' then
      message = message .. '\nOutput:\n' .. encoderOutput
    end
    error(message)
  end
  if encoderOutput ~= '' then
    logger:info('HEIC encoder output:\n' .. encoderOutput)
  end
  return 'Exported HEIC to ' .. outputPath
end

---@class ExportOptions
---@field useHDR boolean
---@field keepIntermediates boolean

---@class RenditionJob
---@field command string
---@field options ExportOptions
---@field profiles RenderProfiles
---@field sharedRenderSettings table<string, any>?
---@field workingDirectory string
---@field sourceRendition LightroomRendition
---@field outputRendition LightroomRendition
---@field primaryPath? string
---@field hdrAlternatePath? string

---Renders the requested inputs, optionally preserves them, and encodes output.
---@param job RenditionJob
---@return string message
local function processRenditionActual(job)
  job.primaryPath = waitForRender(job.sourceRendition, job.profiles.primary)

  if job.options.useHDR then
    if
      not job.sharedRenderSettings
      or not job.workingDirectory
      or not job.profiles.hdrAlternate
    then
      error('Missing settings for the HDR alternate rendition')
    end
    job.hdrAlternatePath = renderAlternate(
      job.sourceRendition.photo,
      job.sharedRenderSettings,
      job.workingDirectory,
      job.profiles.hdrAlternate
    )
  end

  return runEncoder(
    job.command,
    job.primaryPath,
    job.hdrAlternatePath,
    job.outputRendition.destinationPath,
    job.workingDirectory
  )
end

---Runs one rendition job with exception-safe cleanup and completion reporting.
---@param job RenditionJob
---@return boolean processed
local function processRendition(job)
  local callSucceeded, resultOrError = LrTasks.pcall(function()
    return processRenditionActual(job)
  end)
  local processed = callSucceeded
  local message = resultOrError
  if not processed then
    message = 'Rendition processing failed: ' .. tostring(resultOrError)
  end

  if job.options.keepIntermediates and job.primaryPath then
    local preserveCallSucceeded, pathsOrError = LrTasks.pcall(
      preserveEncoderInputs,
      job.primaryPath,
      job.hdrAlternatePath,
      job.outputRendition.destinationPath
    )
    if preserveCallSucceeded then
      local preservedPathList = table.concat(pathsOrError, ', ')
      logger:info('Preserved intermediate TIFFs: ' .. preservedPathList)
      message = message .. '; intermediate TIFFs: ' .. preservedPathList
    else
      processed = false
      message = message
        .. '; could not preserve intermediate TIFFs: '
        .. tostring(pathsOrError)
    end
  end

  deleteDir(job.workingDirectory)

  if processed then
    logger:info(message)
  else
    logger:error(message)
  end

  job.outputRendition:renditionIsDone(processed, message)
  return processed
end

---Processes all Lightroom renditions and satisfies each output rendition.
---@param functionContext any
---@param filterContext any
function Processor.postProcessRenderedPhotos(functionContext, filterContext)
  local p = filterContext.propertyTable
  local colorSpace = Model.colorSpaceFor(p.HEICColorSpace)
  if p.HEICUseHDR and not colorSpace.hdr then
    p.HEICColorSpace = 'SRGB'
    colorSpace = Model.colorSpaces.SRGB
  end
  local profiles = makeRenderProfiles(colorSpace)

  ---@type ExportOptions
  local exportOptions = {
    useHDR = p.HEICUseHDR,
    keepIntermediates = p.HEICKeepIntermediates,
  }

  local converterPath = LrPathUtils.child(
    _PLUGIN.path,
    'ConverterWrapper.app/Contents/MacOS/ConvertToHeic'
  )
  local cmd = shellQuote(converterPath)
  if p.HEICUseSizeLimit then
    cmd = (
      cmd
      .. ' --size-limit '
      .. (p.HEICSizeLimit * 1000)
      .. ' --min-quality '
      .. (p.HEICMinQuality / 100)
      .. ' --max-quality '
      .. (p.HEICMaxQuality / 100)
    )
  else
    cmd = cmd .. ' --quality ' .. (p.HEICQuality / 100)
  end
  if p.HEICUseHDR then
    cmd = cmd .. ' --hdr-output --gain-map-channels rgb'
  end
  local outputBitDepth = p.HEICBitDepth or 10
  cmd = cmd
    .. ' --output-bit-depth '
    .. tostring(outputBitDepth)
    .. ' --output-color-space '
    .. shellQuote(colorSpace.output)

  local sharedRenderSettingsByRendition = {}
  local workingDirectoriesByRendition = {}
  functionContext:addCleanupHandler(function()
    for _, dir in pairs(workingDirectoriesByRendition) do
      deleteDir(dir)
    end
  end)

  local renditionOptions = {
    filterSettings = function(renditionToSatisfy, exportSettings)
      -- This makes the plug-in own both intermediate files and their cleanup.
      local dir = createWorkingDirectory()
      workingDirectoriesByRendition[renditionToSatisfy] = dir
      sharedRenderSettingsByRendition[renditionToSatisfy] =
        captureSharedRenderSettings(exportSettings)
      applyRenderProfile(exportSettings, profiles.primary)
      return LrPathUtils.child(dir, 'primary.tif')
    end,
  }

  logger:info('Starting rendering of originals')
  for sourceRendition, renditionToSatisfy in
    filterContext:renditions(renditionOptions)
  do
    logger:info('Processing rendition')
    ---@type RenditionJob
    local job = {
      command = cmd,
      options = exportOptions,
      profiles = profiles,
      sharedRenderSettings = sharedRenderSettingsByRendition[renditionToSatisfy],
      workingDirectory = workingDirectoriesByRendition[renditionToSatisfy],
      sourceRendition = sourceRendition,
      outputRendition = renditionToSatisfy,
    }
    local processed = processRendition(job)
    sharedRenderSettingsByRendition[renditionToSatisfy] = nil
    workingDirectoriesByRendition[renditionToSatisfy] = nil
    if not processed then
      break
    end
  end
end

return Processor
