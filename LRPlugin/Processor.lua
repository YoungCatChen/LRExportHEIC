local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrLogger = import 'LrLogger'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local ExportPlan = require 'ExportPlan'
local WorkingSpace = require 'WorkingSpace'

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
  -- Copy only pixel-affecting settings. Destination, format, service, and
  -- plug-in-private settings belong to the independent alternate session.
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

---@class SourceRendition
---@field photo any
---@field waitForRender fun(self: any): boolean, string

---@class OutputRendition
---@field destinationPath string
---@field renditionIsDone fun(self: any, success: boolean, message: string)

---@param rendition SourceRendition
---@param profile RenderProfile
---@return string path
local function waitForRender(rendition, profile)
  local success, pathOrMessage = rendition:waitForRender()
  if not success then
    error(
      LOC(
        '$$$/LRExportHEIC/Error/RenditionFailed=^1 rendition failed: ^2',
        profile.label,
        tostring(pathOrMessage)
      )
    )
  end
  local extension = string.lower(LrPathUtils.extension(pathOrMessage) or '')
  if not profile.extensions[extension] then
    error(
      LOC(
        '$$$/LRExportHEIC/Error/UnexpectedRendition=Lightroom returned an '
          .. 'unexpected ^1 rendition: ^2',
        profile.label,
        tostring(pathOrMessage)
      )
    )
  end
  return pathOrMessage
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
    return LOC(
      '$$$/LRExportHEIC/Error/ReadEncoderOutput=Could not read encoder output: ^1',
      tostring(contentsOrError)
    )
  end

  local contents = contentsOrError:gsub('%s+$', '')
  local maximumLength = 16384
  if #contents > maximumLength then
    return contents:sub(1, maximumLength)
      .. LOC '$$$/LRExportHEIC/Error/EncoderOutputTruncated=^n... encoder output truncated ...'
  end
  return contents
end

---@class RenditionJob
---@field plan ExportPlan
---@field workingSpace WorkingSpace
---@field sharedRenderSettings table<string, any>?
---@field sourceRendition SourceRendition
---@field outputRendition OutputRendition
---@field primaryPath? string
---@field alternatePath? string
local RenditionJob = {}
RenditionJob.__index = RenditionJob

---@param plan ExportPlan
---@param workingSpace WorkingSpace
---@param sharedRenderSettings table<string, any>?
---@param sourceRendition SourceRendition
---@param outputRendition OutputRendition
---@return RenditionJob job
function RenditionJob.new(
  plan,
  workingSpace,
  sharedRenderSettings,
  sourceRendition,
  outputRendition
)
  return setmetatable({
    plan = plan,
    workingSpace = workingSpace,
    sharedRenderSettings = sharedRenderSettings,
    sourceRendition = sourceRendition,
    outputRendition = outputRendition,
  }, RenditionJob)
end

---Renders the alternate in a separate Lightroom export session.
---Writes the rendered path to self.alternatePath.
function RenditionJob:renderAlternate()
  local profile = assert(self.plan.alternateProfile)
  local sharedRenderSettings = assert(self.sharedRenderSettings)
  local destinationPath = assert(self.workingSpace.alternatePath)

  local exportSession = LrExportSession {
    photosToExport = { self.sourceRendition.photo },
    exportSettings = self.plan:makeAlternateSessionSettings(
      sharedRenderSettings,
      destinationPath
    ),
  }

  exportSession:doExportOnCurrentTask()

  for _, rendition in exportSession:renditions() do
    local renderedPath = waitForRender(rendition, profile)
    if renderedPath ~= destinationPath then
      error(
        LOC(
          '$$$/LRExportHEIC/Error/UnexpectedAlternatePath=Lightroom rendered '
            .. 'the alternate to an unexpected path: ^1; expected: ^2',
          renderedPath,
          destinationPath
        )
      )
    end

    self.alternatePath = renderedPath
    return
  end

  error(
    LOC(
      '$$$/LRExportHEIC/Error/MissingRendition=Lightroom did not produce an ^1 rendition',
      profile.label
    )
  )
end

---Invokes the Swift encoder and reports its captured diagnostics.
---@param encoderCommand string
function RenditionJob:runEncoder(encoderCommand)
  local logPath = self.workingSpace.logPath
  local executedCommand = encoderCommand
    .. ' > '
    .. shellQuote(logPath)
    .. ' 2>&1'
  local status = LrTasks.execute(executedCommand)
  local encoderOutput = readEncoderOutput(logPath)

  if status ~= 0 then
    local exitCode = decodeExitStatus(status)
    local message = LOC(
      '$$$/LRExportHEIC/Error/EncoderFailed=HEIC encoder failed with exit '
        .. 'code ^1 (raw status ^2)^nCommand: ^3',
      exitCode,
      status,
      encoderCommand
    )
    if encoderOutput ~= '' then
      message = message
        .. LOC '$$$/LRExportHEIC/Error/EncoderOutput=^nOutput:^n'
        .. encoderOutput
    end
    error(message)
  end

  if encoderOutput ~= '' then
    logger:info('HEIC encoder output:\n' .. encoderOutput)
  end
end

---Renders the requested inputs, optionally preserves them, and encodes output.
---Populates self.primaryPath and optionally self.alternatePath on success.
---@return string message
function RenditionJob:processActual()
  self.primaryPath =
    waitForRender(self.sourceRendition, self.plan.primaryProfile)

  if self.plan.renderAlternate then
    self:renderAlternate()
  end

  local encoderCommand = self.plan:encoderCommand(
    self.primaryPath,
    self.alternatePath,
    self.outputRendition.destinationPath
  )

  self:runEncoder(encoderCommand)

  return LOC(
    '$$$/LRExportHEIC/Status/Exported=Exported HEIC to ^1',
    self.outputRendition.destinationPath
  )
end

---Runs one rendition job with exception-safe cleanup and completion reporting.
---@return boolean processed
function RenditionJob:process()
  local callSucceeded, resultOrError = LrTasks.pcall(function()
    return self:processActual()
  end)

  local processed = callSucceeded
  local message = resultOrError
  if not processed then
    message = LOC(
      '$$$/LRExportHEIC/Error/ProcessingFailed=Rendition processing failed: ^1',
      tostring(resultOrError)
    )
  end

  if self.plan.keepIntermediates and self.primaryPath then
    local paths = { self.primaryPath }
    if self.alternatePath then
      table.insert(paths, self.alternatePath)
    end
    local pathList = table.concat(paths, ', ')
    logger:info('Intermediate TIFFs: ' .. pathList)
    message = message
      .. LOC(
        '$$$/LRExportHEIC/Status/IntermediateTIFFs=; intermediate TIFFs: ^1',
        pathList
      )
  end

  self.workingSpace:cleanup()

  if processed then
    logger:info(message)
  else
    logger:error(message)
  end

  self.outputRendition:renditionIsDone(processed, message)
  return processed
end

---Processes all Lightroom renditions using one immutable export plan.
---
---1. Allocates one isolated WorkingSpace during filterSettings.
---2. Waits for the primary and renders an alternate when required.
---3. Invokes the encoder, cleans temporary files, and reports completion.
---@param functionContext any
---@param filterContext any
function Processor.postProcessRenderedPhotos(functionContext, filterContext)
  local p = filterContext.propertyTable
  local converterPath = LrPathUtils.child(
    _PLUGIN.path,
    'ConverterWrapper.app/Contents/MacOS/ConvertToHeic'
  )
  local plan = ExportPlan.new(p, converterPath)

  local sharedRenderSettingsByRendition = {}
  local workingSpacesByRendition = {}
  functionContext:addCleanupHandler(function()
    for _, workingSpace in pairs(workingSpacesByRendition) do
      workingSpace:cleanup()
    end
  end)

  local renditionOptions = {
    filterSettings = function(renditionToSatisfy, exportSettings)
      local outputPath = renditionToSatisfy.destinationPath
      local alternateFileSuffix = plan.alternateProfile
        and plan.alternateProfile.fileSuffix
      local workingSpace = WorkingSpace.new(
        outputPath,
        plan.keepIntermediates,
        alternateFileSuffix
      )
      workingSpacesByRendition[renditionToSatisfy] = workingSpace
      sharedRenderSettingsByRendition[renditionToSatisfy] =
        captureSharedRenderSettings(exportSettings)
      plan:applyPrimaryRenderSettings(exportSettings)
      return workingSpace.primaryPath
    end,
  }

  logger:info('Starting rendering of originals')

  for sourceRendition, renditionToSatisfy in
    filterContext:renditions(renditionOptions)
  do
    logger:info('Processing rendition')

    local job = RenditionJob.new(
      plan,
      workingSpacesByRendition[renditionToSatisfy],
      sharedRenderSettingsByRendition[renditionToSatisfy],
      sourceRendition,
      renditionToSatisfy
    )

    local processed = job:process()
    sharedRenderSettingsByRendition[renditionToSatisfy] = nil
    workingSpacesByRendition[renditionToSatisfy] = nil
    if not processed then
      break
    end

  end
end

return Processor
