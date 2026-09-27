local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

---@class WorkingSpace
---@field primaryPath string
---@field alternatePath string?
---@field logPath string
---@field private temporaryDirectory string?
local WorkingSpace = {}
WorkingSpace.__index = WorkingSpace

---@return string path
local function createTemporaryDirectory()
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

---Allocates stable paths for every file produced while processing a rendition.
---
---Preserved intermediates live beside the final output; otherwise all working
---files share one temporary directory that can be removed as a unit.
---@param destinationPath string
---@param keepIntermediates boolean
---@param alternateFileSuffix string?
---@return WorkingSpace workingSpace
function WorkingSpace.new(
  destinationPath,
  keepIntermediates,
  alternateFileSuffix
)
  local primaryPath
  local alternatePath
  local logPath
  local temporaryDirectory

  if keepIntermediates then
    primaryPath = destinationPath .. '.intermediate.tif'
    logPath = destinationPath .. '.encoder-output.log'
    if alternateFileSuffix then
      alternatePath = destinationPath
        .. '.intermediate-'
        .. alternateFileSuffix
        .. '.tif'
    end
  else
    temporaryDirectory = createTemporaryDirectory()
    primaryPath = LrPathUtils.child(temporaryDirectory, 'primary.tif')
    logPath = LrPathUtils.child(temporaryDirectory, 'encoder-output.log')
    if alternateFileSuffix then
      alternatePath = LrPathUtils.child(temporaryDirectory, 'alternate.tif')
    end
  end

  return setmetatable({
    primaryPath = primaryPath,
    alternatePath = alternatePath,
    logPath = logPath,
    temporaryDirectory = temporaryDirectory,
  }, WorkingSpace)
end

---Deletes only temporary working files; user-requested intermediates remain.
function WorkingSpace:cleanup()
  if self.temporaryDirectory then
    pcall(function()
      LrFileUtils.delete(self.temporaryDirectory)
    end)
    self.temporaryDirectory = nil
  end
end

return WorkingSpace
