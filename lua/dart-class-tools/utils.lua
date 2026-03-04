local M = {}

--- Capitalize the first letter of a string.
---@param s string
---@return string
function M.capitalize(s)
  if not s or #s == 0 then return s end
  return s:sub(1, 1):upper() .. s:sub(2)
end

--- Convert a camelCase variable name to snake_case key.
---@param src string
---@return string
function M.var_to_key(src)
  local result = src:gsub("(%u)", function(c) return "_" .. c:lower() end)
  return result
end

--- Remove trailing substring if present.
---@param source string
---@param ending string
---@return string
function M.remove_end(source, ending)
  if source:sub(-#ending) == ending then
    return source:sub(1, -(#ending + 1))
  end
  return source
end

--- Remove leading substring if present.
---@param source string
---@param start string
---@return string
function M.remove_start(source, start)
  if source:sub(1, #start) == start then
    return source:sub(#start + 1)
  end
  return source
end

--- Indent every line by two spaces.
---@param source string
---@return string
function M.indent(source)
  local lines = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = "  " .. line
  end
  return table.concat(lines, "\n")
end

--- Check if a string is blank (empty or whitespace only).
---@param s string|nil
---@return boolean
function M.is_blank(s)
  return not s or s:match("^%s*$") ~= nil
end

--- Count occurrences of a single character in a string.
---@param source string
---@param ch string single character
---@return integer
function M.count_char(source, ch)
  local n = 0
  for i = 1, #source do
    if source:sub(i, i) == ch then n = n + 1 end
  end
  return n
end

--- Check if a string includes any of the given matches (word-based or substring).
---@param source string
---@param matches string[]
---@param word_based? boolean default true
---@return boolean
function M.includes_one(source, matches, word_based)
  if word_based == nil then word_based = true end
  if word_based then
    for word in source:gmatch("%S+") do
      for _, m in ipairs(matches) do
        if word == m then return true end
      end
    end
  else
    for _, m in ipairs(matches) do
      if source:find(m, 1, true) then return true end
    end
  end
  return false
end

--- Check if a string includes all of the given matches.
---@param source string
---@param matches string[]
---@return boolean
function M.includes_all(source, matches)
  for _, m in ipairs(matches) do
    if not source:find(m, 1, true) then return false end
  end
  return true
end

--- Trim whitespace from both ends.
---@param s string
---@return string
function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Split string by newlines.
---@param s string
---@return string[]
function M.split_lines(s)
  local lines = {}
  for line in s:gmatch("([^\n]*)\n?") do
    if line ~= "" or #lines < select(2, s:gsub("\n", "\n")) + 1 then
      lines[#lines + 1] = line
    end
  end
  -- Remove trailing empty string if the source doesn't end with newline
  if #lines > 0 and lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

--- Make a valid Dart variable name from a string.
---@param source string
---@return string
function M.to_var_name(source)
  local s = source
  local r = ""

  local function replace(char)
    if s:find(char, 1, true) then
      local parts = {}
      for part in (s .. char):gmatch("(.-)%" .. char) do
        parts[#parts + 1] = part
      end
      r = ""
      for i, w in ipairs(parts) do
        if i > 1 then
          r = r .. M.capitalize(w)
        else
          r = r .. w
        end
      end
      s = r
    end
  end

  replace("-")
  replace("~")
  replace(":")
  replace("#")

  if #r == 0 then r = s end

  local keywords = {
    "assert", "break", "case", "catch", "class", "const", "continue",
    "default", "do", "else", "enum", "extends", "false", "final",
    "finally", "for", "if", "in", "is", "new", "null", "rethrow",
    "return", "super", "switch", "this", "throw", "true", "try",
    "var", "void", "while", "with",
  }

  for _, kw in ipairs(keywords) do
    if r == kw then
      r = r .. "_"
      break
    end
  end

  if #r > 0 and r:sub(1, 1):match("%d") then
    r = "n" .. r
  end

  return r
end

--- Check if table contains a value.
---@param tbl table
---@param val any
---@return boolean
function M.tbl_contains(tbl, val)
  for _, v in ipairs(tbl) do
    if v == val then return true end
  end
  return false
end

return M
