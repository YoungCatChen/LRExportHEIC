---@class ColorSpaceSpec
---@field title string
---@field sdr string
---@field hdr? string
---@field output string

local Model = {}

---@type table<string, ColorSpaceSpec>
Model.colorSpaces = {
  SRGB = {
    title = 'sRGB',
    sdr = 'sRGB',
    hdr = 'sRGB_hdr',
    output = 'SRGB',
  },
  DisplayP3 = {
    title = 'Display P3',
    sdr = 'DisplayP3',
    hdr = 'p3_hdr',
    output = 'DisplayP3',
  },
  AdobeRGB1998 = {
    title = 'Adobe RGB',
    sdr = 'AdobeRGB',
    output = 'AdobeRGB1998',
  },
  Rec2020 = {
    title = 'Rec. 2020',
    sdr = 'Rec2020',
    hdr = 'Rec2020_hdr',
    output = 'ITUR_2020',
  },
}

Model.sdrColorSpaceItems = {
  { title = Model.colorSpaces.SRGB.title, value = 'SRGB' },
  { title = Model.colorSpaces.DisplayP3.title, value = 'DisplayP3' },
  {
    title = Model.colorSpaces.AdobeRGB1998.title,
    value = 'AdobeRGB1998',
  },
  { title = Model.colorSpaces.Rec2020.title, value = 'Rec2020' },
}

Model.hdrColorSpaceItems = {
  { title = Model.colorSpaces.SRGB.title, value = 'SRGB' },
  { title = Model.colorSpaces.DisplayP3.title, value = 'DisplayP3' },
  { title = Model.colorSpaces.Rec2020.title, value = 'Rec2020' },
}

Model.exportPresetFields = {
  { key = 'HEICQuality', default = 75 },
  { key = 'HEICUseSizeLimit', default = false },
  { key = 'HEICSizeLimit', default = 3000 },
  { key = 'HEICMinQuality', default = 10 },
  { key = 'HEICMaxQuality', default = 90 },
  { key = 'HEICColorSpace', default = 'SRGB' },
  { key = 'HEICBitDepth', default = 10 },
  { key = 'HEICUseHDR', default = false },
  { key = 'HEICKeepIntermediateTIFFs', default = false },
}

---@param value string
---@return ColorSpaceSpec
function Model.colorSpaceFor(value)
  return Model.colorSpaces[value] or Model.colorSpaces.SRGB
end

---@param useHDR boolean
---@return table[]
function Model.colorSpaceItems(useHDR)
  if useHDR then
    return Model.hdrColorSpaceItems
  end
  return Model.sdrColorSpaceItems
end

return Model
