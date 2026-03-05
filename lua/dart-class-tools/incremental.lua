local utils = require("dart-class-tools.utils")

local M = {}

--------------------------------------------------------------------------------
-- Method block detection
--
-- Scans the lines of a class body to find well-known method blocks
-- (constructor, copyWith, toMap, fromMap, toJson, fromJson, toString,
--  operator ==, hashCode) and records their start/end lines and the set
-- of field names each block currently covers.
--------------------------------------------------------------------------------

---@class MethodBlock
---@field kind string e.g. "constructor", "copyWith", "toMap", …
---@field start_line number 1-indexed absolute line number
---@field end_line number 1-indexed absolute line number
---@field fields string[] list of field names the block currently covers
---@field text string the raw text of the block (lines joined by \n)

--- Try to find the end of a brace-delimited block starting at `start_idx`.
--- Returns the index of the line that closes the block.
---@param lines string[] 1-indexed array of all buffer lines
---@param start_idx number 1-indexed line where the block opens
---@return number end_idx
local function find_block_end(lines, start_idx)
  local depth = 0
  for i = start_idx, #lines do
    local line = lines[i]
    depth = depth + utils.count_char(line, "{") - utils.count_char(line, "}")
    depth = depth + utils.count_char(line, "(") - utils.count_char(line, ")")
    -- A semicolon at depth 0 also ends the block (single-line / arrow methods)
    if depth <= 0 then
      return i
    end
    -- Handle arrow methods that end with ;
    if i > start_idx and utils.trim(line):match(";%s*$") and depth <= 0 then
      return i
    end
  end
  return start_idx
end

--- Find the end of a method/block that may use both {} for body and () for params.
--- Tracks curly braces and parentheses separately to handle factory constructors etc.
---@param lines string[]
---@param start_idx number
---@return number
local function find_method_end(lines, start_idx)
  local curlies = 0
  local parens = 0
  local found_body_start = false
  for i = start_idx, #lines do
    local line = lines[i]
    curlies = curlies + utils.count_char(line, "{") - utils.count_char(line, "}")
    parens = parens + utils.count_char(line, "(") - utils.count_char(line, ")")

    if curlies > 0 then found_body_start = true end

    -- Arrow method ending with ;
    local trimmed = utils.trim(line)
    if trimmed:match("=>") and trimmed:match(";%s*$") and curlies == 0 and parens == 0 then
      return i
    end

    -- Single-line methods or factory constructors ending with ;
    if curlies == 0 and parens == 0 and trimmed:match(";%s*$") then
      return i
    end

    -- Normal block end
    if found_body_start and curlies == 0 then
      return i
    end
  end
  return start_idx
end

--- Extract field names referenced in a block of text via "this.XXX" or named params.
---@param text string
---@return string[]
local function extract_this_fields(text)
  local fields = {}
  local seen = {}
  for name in text:gmatch("this%.([%w_]+)") do
    if not seen[name] then
      seen[name] = true
      fields[#fields + 1] = name
    end
  end
  return fields
end

--- Extract field names from a copyWith method body by looking at parameter names.
---@param text string
---@return string[]
local function extract_copywith_fields(text)
  local fields = {}
  local seen = {}
  -- Look for "TypeName? fieldName," pattern in the parameter block
  -- and also for "fieldName ?? this.fieldName" or "fieldName: fieldName ?? this.fieldName"
  for name in text:gmatch("([%w_]+)%s*%?%?%s*this%.") do
    if not seen[name] then
      seen[name] = true
      fields[#fields + 1] = name
    end
  end
  -- Also try nullable getter pattern for ValueGetter
  for name in text:gmatch("([%w_]+)%s*!=%s*null%s*%?%s*[%w_]+%(%)%s*:%s*this%.") do
    if not seen[name] then
      seen[name] = true
      fields[#fields + 1] = name
    end
  end
  return fields
end

--- Extract field names from toMap body: 'keyName': fieldName or 'keyName': fieldName.xxx
---@param text string
---@return string[]
local function extract_tomap_fields(text)
  local fields = {}
  local seen = {}
  for name in text:gmatch("'[%w_]+':%s*([%w_]+)") do
    if not seen[name] then
      seen[name] = true
      fields[#fields + 1] = name
    end
  end
  return fields
end

--- Extract field names from fromMap body: fieldName: map['key'] or map['key'] as Type
---@param text string
---@return string[]
local function extract_frommap_fields(text)
  local fields = {}
  local seen = {}
  -- Named constructor params: "fieldName: map['...']"
  for name in text:gmatch("([%w_]+):%s*map%[") do
    if name ~= "Map" and name ~= "return" then
      if not seen[name] then
        seen[name] = true
        fields[#fields + 1] = name
      end
    end
  end
  -- Also catch positional: just "map['fieldName']" matched by the key itself
  -- and unnamed params via map['key'] without a named: prefix
  for key in text:gmatch("map%['([%w_]+)'%]") do
    if not seen[key] then
      seen[key] = true
      fields[#fields + 1] = key
    end
  end
  return fields
end

--- Extract field names from toString: "ClassName(fieldName: $fieldName, ...)"
---@param text string
---@return string[]
local function extract_tostring_fields(text)
  local fields = {}
  local seen = {}
  for name in text:gmatch("([%w_]+):%s*%$[%w_]+") do
    if not seen[name] then
      seen[name] = true
      fields[#fields + 1] = name
    end
  end
  return fields
end

--- Extract field names from equality operator: "other.fieldName == fieldName" or collection equality calls
---@param text string
---@return string[]
local function extract_equality_fields(text)
  local fields = {}
  local seen = {}
  for name in text:gmatch("other%.([%w_]+)%s*==") do
    if not seen[name] then
      seen[name] = true
      fields[#fields + 1] = name
    end
  end
  -- collection equality: listEquals(other.fieldName, fieldName) etc
  for name in text:gmatch("[lmsLMS]%w+Equals%(other%.([%w_]+)") do
    if not seen[name] then
      seen[name] = true
      fields[#fields + 1] = name
    end
  end
  return fields
end

--- Extract field names from hashCode: "fieldName.hashCode"
---@param text string
---@return string[]
local function extract_hashcode_fields(text)
  local fields = {}
  local seen = {}
  for name in text:gmatch("([%w_]+)%.hashCode") do
    if not seen[name] then
      seen[name] = true
      fields[#fields + 1] = name
    end
  end
  return fields
end

--- Extract field names from Equatable props getter: "get props => [field1, field2];"
---@param text string
---@return string[]
local function extract_props_fields(text)
  local fields = {}
  local seen = {}
  -- Match the array content inside [ ... ]
  local array_content = text:match("%[(.-)%]")
  if not array_content then return fields end
  for name in array_content:gmatch("([%w_]+)") do
    if not seen[name] then
      seen[name] = true
      fields[#fields + 1] = name
    end
  end
  return fields
end

--- Detect all method blocks within a class.
---@param clazz DartClass
---@param buf_lines string[] 1-indexed array of all buffer lines
---@return table<string, MethodBlock> map of kind -> MethodBlock
function M.detect_blocks(clazz, buf_lines)
  local blocks = {}
  local class_name = clazz.name
  if not class_name then return blocks end

  -- We scan lines from clazz.starts_at_line+1 to clazz.ends_at_line-1
  local start = clazz.starts_at_line + 1
  local stop = clazz.ends_at_line - 1
  if start > stop then return blocks end

  local i = start
  while i <= stop do
    local line = buf_lines[i]
    if not line then
      i = i + 1
      goto continue
    end
    local trimmed = utils.trim(line)

    -- Check for @override annotation (for toString, equality, hashCode)
    local has_override = trimmed == "@override"
    local check_line = trimmed
    local block_start = i

    if has_override and i + 1 <= stop then
      -- The actual method signature is on the next non-blank line
      local next_i = i + 1
      while next_i <= stop and utils.trim(buf_lines[next_i]) == "" do
        next_i = next_i + 1
      end
      if next_i <= stop then
        check_line = utils.trim(buf_lines[next_i])
      end
    end

    -- Constructor: ClassName( or const ClassName(
    local constr_pat = "^const%s+" .. class_name .. "%(" 
    local constr_pat2 = "^" .. class_name .. "%("
    if not has_override and (check_line:match(constr_pat) or check_line:match(constr_pat2)) then
      local end_line = find_method_end(buf_lines, block_start)
      local text_lines = {}
      for j = block_start, end_line do
        text_lines[#text_lines + 1] = buf_lines[j]
      end
      local text = table.concat(text_lines, "\n")
      blocks.constructor = {
        kind = "constructor",
        start_line = block_start,
        end_line = end_line,
        fields = extract_this_fields(text),
        text = text,
      }
      i = end_line + 1
      goto continue
    end

    -- copyWith
    if not has_override and check_line:match("copyWith%s*%(") then
      local end_line = find_method_end(buf_lines, block_start)
      local text_lines = {}
      for j = block_start, end_line do
        text_lines[#text_lines + 1] = buf_lines[j]
      end
      local text = table.concat(text_lines, "\n")
      blocks.copyWith = {
        kind = "copyWith",
        start_line = block_start,
        end_line = end_line,
        fields = extract_copywith_fields(text),
        text = text,
      }
      i = end_line + 1
      goto continue
    end

    -- toMap
    if not has_override and check_line:match("Map<String,%s*dynamic>%s*toMap%s*%(") then
      local end_line = find_method_end(buf_lines, block_start)
      local text_lines = {}
      for j = block_start, end_line do
        text_lines[#text_lines + 1] = buf_lines[j]
      end
      local text = table.concat(text_lines, "\n")
      blocks.toMap = {
        kind = "toMap",
        start_line = block_start,
        end_line = end_line,
        fields = extract_tomap_fields(text),
        text = text,
      }
      i = end_line + 1
      goto continue
    end

    -- fromMap
    if not has_override and check_line:match("factory%s+" .. class_name .. "%.fromMap%s*%(") then
      local end_line = find_method_end(buf_lines, block_start)
      local text_lines = {}
      for j = block_start, end_line do
        text_lines[#text_lines + 1] = buf_lines[j]
      end
      local text = table.concat(text_lines, "\n")
      blocks.fromMap = {
        kind = "fromMap",
        start_line = block_start,
        end_line = end_line,
        fields = extract_frommap_fields(text),
        text = text,
      }
      i = end_line + 1
      goto continue
    end

    -- toJson
    if not has_override and check_line:match("String%s+toJson%s*%(") then
      local end_line = find_method_end(buf_lines, block_start)
      local text_lines = {}
      for j = block_start, end_line do
        text_lines[#text_lines + 1] = buf_lines[j]
      end
      local text = table.concat(text_lines, "\n")
      blocks.toJson = {
        kind = "toJson",
        start_line = block_start,
        end_line = end_line,
        fields = {},
        text = text,
      }
      i = end_line + 1
      goto continue
    end

    -- fromJson
    if not has_override and check_line:match("factory%s+" .. class_name .. "%.fromJson%s*%(") then
      local end_line = find_method_end(buf_lines, block_start)
      local text_lines = {}
      for j = block_start, end_line do
        text_lines[#text_lines + 1] = buf_lines[j]
      end
      local text = table.concat(text_lines, "\n")
      blocks.fromJson = {
        kind = "fromJson",
        start_line = block_start,
        end_line = end_line,
        fields = {},
        text = text,
      }
      i = end_line + 1
      goto continue
    end

    -- toString (has @override)
    if has_override and check_line:match("String%s+toString%s*%(") then
      -- block_start is at @override
      local sig_line_idx = block_start + 1
      while sig_line_idx <= stop and utils.trim(buf_lines[sig_line_idx]) == "" do
        sig_line_idx = sig_line_idx + 1
      end
      local end_line = find_method_end(buf_lines, sig_line_idx)
      local text_lines = {}
      for j = block_start, end_line do
        text_lines[#text_lines + 1] = buf_lines[j]
      end
      local text = table.concat(text_lines, "\n")
      blocks.toString = {
        kind = "toString",
        start_line = block_start,
        end_line = end_line,
        fields = extract_tostring_fields(text),
        text = text,
      }
      i = end_line + 1
      goto continue
    end

    -- operator == (has @override)
    if has_override and check_line:match("bool%s+operator%s*==") then
      local sig_line_idx = block_start + 1
      while sig_line_idx <= stop and utils.trim(buf_lines[sig_line_idx]) == "" do
        sig_line_idx = sig_line_idx + 1
      end
      local end_line = find_method_end(buf_lines, sig_line_idx)
      local text_lines = {}
      for j = block_start, end_line do
        text_lines[#text_lines + 1] = buf_lines[j]
      end
      local text = table.concat(text_lines, "\n")
      blocks.equality = {
        kind = "equality",
        start_line = block_start,
        end_line = end_line,
        fields = extract_equality_fields(text),
        text = text,
      }
      i = end_line + 1
      goto continue
    end

    -- hashCode (has @override)
    if has_override and check_line:match("int%s+get%s+hashCode") then
      local sig_line_idx = block_start + 1
      while sig_line_idx <= stop and utils.trim(buf_lines[sig_line_idx]) == "" do
        sig_line_idx = sig_line_idx + 1
      end
      local end_line = find_method_end(buf_lines, sig_line_idx)
      local text_lines = {}
      for j = block_start, end_line do
        text_lines[#text_lines + 1] = buf_lines[j]
      end
      local text = table.concat(text_lines, "\n")
      blocks.hashCode = {
        kind = "hashCode",
        start_line = block_start,
        end_line = end_line,
        fields = extract_hashcode_fields(text),
        text = text,
      }
      i = end_line + 1
      goto continue
    end

    -- props — Equatable props (getter, field, or method) with or without @override
    --
    -- Detect ALL forms:
    --   Getter:  List<Object?> get props => ...  /  List<Object?> get props { ... }
    --   Field:   final List<Object?> props = ...;  /  final props = ...;  /  late final List<Object?> props;
    --   Method:  List<Object?> props() => ...  /  List<Object?> props() { ... }  /  props() => ...
    -- Each may or may not have @override.
    local props_style = nil -- "getter" | "field" | "method"
    if check_line:match("List<Object%?>%s+get%s+props")
      or check_line:match("get%s+props%s*=>")
      or check_line:match("get%s+props%s*{") then
      props_style = "getter"
    elseif check_line:match("final%s+List<Object%?>%s+props%s*=")
      or check_line:match("final%s+props%s*=")
      or check_line:match("late%s+final%s+List<Object%?>%s+props")
      or check_line:match("final%s+List<Object%?>%s+props%s*;") then
      props_style = "field"
    elseif check_line:match("List<Object%?>%s+props%s*%(")
      or check_line:match("^props%s*%(") then
      props_style = "method"
    end

    if props_style then
      local sig_line_idx = block_start
      if has_override then
        sig_line_idx = block_start + 1
        while sig_line_idx <= stop and utils.trim(buf_lines[sig_line_idx]) == "" do
          sig_line_idx = sig_line_idx + 1
        end
      end
      local end_line = find_method_end(buf_lines, sig_line_idx)
      local text_lines = {}
      for j = block_start, end_line do
        text_lines[#text_lines + 1] = buf_lines[j]
      end
      local text = table.concat(text_lines, "\n")
      blocks.props = {
        kind = "props",
        start_line = block_start,
        end_line = end_line,
        fields = extract_props_fields(text),
        text = text,
        props_style = props_style,
        has_override = has_override,
      }
      i = end_line + 1
      goto continue
    end

    i = i + 1
    ::continue::
  end

  return blocks
end

--------------------------------------------------------------------------------
-- Field comparison helpers
--------------------------------------------------------------------------------

--- Get the list of gen-eligible field names from a class.
---@param clazz DartClass
---@return string[]
function M.get_class_field_names(clazz)
  local names = {}
  for _, p in ipairs(clazz:gen_properties()) do
    names[#names + 1] = p.name
  end
  return names
end

--- Find field names that are in `wanted` but not in `existing`.
---@param wanted string[]
---@param existing string[]
---@return string[]
function M.missing_fields(wanted, existing)
  local exist_set = {}
  for _, n in ipairs(existing) do exist_set[n] = true end
  local missing = {}
  for _, n in ipairs(wanted) do
    if not exist_set[n] then
      missing[#missing + 1] = n
    end
  end
  return missing
end

--- Find field names that are in `existing` (block) but not in `wanted` (class fields).
--- These are "orphan" fields — referenced by the block but no longer present in the class.
---@param wanted string[]
---@param existing string[]
---@return string[]
function M.orphan_fields(wanted, existing)
  local want_set = {}
  for _, n in ipairs(wanted) do want_set[n] = true end
  local orphans = {}
  for _, n in ipairs(existing) do
    if not want_set[n] then
      orphans[#orphans + 1] = n
    end
  end
  return orphans
end

--- Check if a block has any field mismatch with the class (missing OR orphan fields).
---@param block MethodBlock|nil
---@param class_fields string[]
---@return boolean
function M.has_field_mismatch(block, class_fields)
  if not block then return false end
  local missing = M.missing_fields(class_fields, block.fields)
  if #missing > 0 then return true end
  local orphans = M.orphan_fields(class_fields, block.fields)
  if #orphans > 0 then return true end
  return false
end

--- Check if two field lists cover the same set of names (order-independent).
---@param a string[]
---@param b string[]
---@return boolean
function M.fields_match(a, b)
  if #a ~= #b then return false end
  local set_a = {}
  for _, n in ipairs(a) do set_a[n] = true end
  for _, n in ipairs(b) do
    if not set_a[n] then return false end
  end
  return true
end

--------------------------------------------------------------------------------
-- Block status: "absent" | "incomplete" | "complete"
--------------------------------------------------------------------------------

---@alias BlockStatus "absent"|"incomplete"|"stale"|"complete"

--- Determine the status of a method block.
--- "absent"     — block does not exist
--- "incomplete" — block exists but is missing fields (new fields not covered)
--- "stale"      — block exists but has orphan fields (references removed fields)
---                Note: a block that is both incomplete AND stale is reported as "stale"
---                since stale implies the block is out of sync with the class.
--- "complete"   — block exists and field sets match exactly
---@param block MethodBlock|nil
---@param class_fields string[]
---@return BlockStatus
function M.block_status(block, class_fields)
  if not block then return "absent" end
  local orphans = M.orphan_fields(class_fields, block.fields)
  local missing = M.missing_fields(class_fields, block.fields)
  if #orphans > 0 then return "stale" end
  if #missing > 0 then return "incomplete" end
  return "complete"
end

--- For toJson/fromJson which are thin wrappers, status is just present/absent.
---@param block MethodBlock|nil
---@return BlockStatus
function M.wrapper_status(block)
  if not block then return "absent" end
  return "complete"
end

--- Determine the status of a props block.
--- Like block_status but also checks field ORDER (props must match field order exactly).
--- "absent"     — block does not exist
--- "stale"      — block exists but fields mismatch (wrong set or wrong order)
--- "complete"   — block exists, fields match exactly in order
---@param block MethodBlock|nil
---@param class_fields string[]
---@return BlockStatus
function M.props_status(block, class_fields)
  if not block then return "absent" end
  -- Check set membership first
  local orphans = M.orphan_fields(class_fields, block.fields)
  local missing = M.missing_fields(class_fields, block.fields)
  if #orphans > 0 or #missing > 0 then return "stale" end
  -- Check order
  if #block.fields ~= #class_fields then return "stale" end
  for i, name in ipairs(class_fields) do
    if block.fields[i] ~= name then return "stale" end
  end
  return "complete"
end

--------------------------------------------------------------------------------
-- Insertion point calculation
--
-- When inserting a new block, we need to find the right location in the class.
-- The canonical order is:
--   properties → constructor → copyWith → toMap → fromMap → toJson → fromJson → toString → equality → hashCode
-- A new block should go AFTER the last existing block that precedes it in this
-- order, or after the last property if no preceding blocks exist.
--------------------------------------------------------------------------------

local METHOD_ORDER = {
  "constructor", "copyWith", "toMap", "fromMap", "toJson", "fromJson",
  "toString", "equality", "hashCode", "props",
}

--- Get the 1-indexed position in METHOD_ORDER for a given kind.
---@param kind string
---@return number
local function method_order_index(kind)
  for i, k in ipairs(METHOD_ORDER) do
    if k == kind then return i end
  end
  return 0
end

--- Find the line after which a new block of `kind` should be inserted.
---@param clazz DartClass
---@param blocks table<string, MethodBlock>
---@param kind string
---@return number insert_after_line (1-indexed absolute line)
function M.find_insert_point(clazz, blocks, kind)
  local target_idx = method_order_index(kind)
  local best_line = clazz:props_end_at_line()

  -- If constructor exists and is tracked by parser, use its end
  if clazz:has_constructor() and clazz.constr_ends_at_line then
    if method_order_index("constructor") < target_idx then
      if clazz.constr_ends_at_line > best_line then
        best_line = clazz.constr_ends_at_line
      end
    end
  end

  -- Check all detected blocks that precede `kind` in the order
  for _, mk in ipairs(METHOD_ORDER) do
    if method_order_index(mk) >= target_idx then break end
    local b = blocks[mk]
    if b and b.end_line > best_line then
      best_line = b.end_line
    end
  end

  return best_line
end

--------------------------------------------------------------------------------
-- Incremental apply
--
-- Given a class, detected blocks, and a desired action (kind),
-- produce a list of buffer edits (replace ranges or insertions).
--------------------------------------------------------------------------------

---@class BufferEdit
---@field start_line number 1-indexed, inclusive
---@field end_line number 1-indexed, inclusive (for replacement)
---@field new_lines string[]
---@field action string "replace" or "insert_after"

--- Build a single edit to replace or insert a method block.
--- When building edits for multiple kinds, pass the same `blocks` table
--- throughout. For absent blocks this function does NOT mutate `blocks`.
--- The caller should use _canonical_order on edits to ensure correct stacking
--- when multiple inserts share the same start_line.
---@param kind string
---@param clazz DartClass
---@param blocks table<string, MethodBlock>
---@param generated_text string the freshly generated method text
---@return BufferEdit|nil
function M.build_edit(kind, clazz, blocks, generated_text)
  local block = blocks[kind]
  local gen_lines = {}
  for line in (generated_text .. "\n"):gmatch("([^\n]*)\n") do
    gen_lines[#gen_lines + 1] = line
  end

  if block then
    -- Block exists → replace it entirely with the new generated text.
    -- But first check if the text is identical (idempotency).
    local existing_lines = {}
    for line in (block.text .. "\n"):gmatch("([^\n]*)\n") do
      existing_lines[#existing_lines + 1] = line
    end
    -- Compare
    if #existing_lines == #gen_lines then
      local identical = true
      for j = 1, #gen_lines do
        if gen_lines[j] ~= existing_lines[j] then
          identical = false
          break
        end
      end
      if identical then return nil end -- idempotent: no change needed
    end
    return {
      start_line = block.start_line,
      end_line = block.end_line,
      new_lines = gen_lines,
      action = "replace",
      _canonical_order = method_order_index(kind),
    }
  else
    -- Block absent → insert after the right position
    local insert_after = M.find_insert_point(clazz, blocks, kind)
    -- Prepend a blank separator line
    local lines_with_sep = { "" }
    for _, l in ipairs(gen_lines) do
      lines_with_sep[#lines_with_sep + 1] = l
    end
    return {
      start_line = insert_after,
      end_line = insert_after, -- not replacing anything
      new_lines = lines_with_sep,
      action = "insert_after",
      _canonical_order = method_order_index(kind),
    }
  end
end

--- Apply a list of edits to a buffer lines array (returns a new array).
--- Edits must be sorted by start_line DESCENDING to avoid offset issues.
---@param buf_lines string[] 1-indexed
---@param edits BufferEdit[]
---@return string[]
function M.apply_edits(buf_lines, edits)
  -- Sort edits by start_line descending so later edits don't shift earlier ones.
  -- When two insert_after edits share the same start_line, sort by canonical
  -- order DESCENDING so they stack up in the correct (ascending) order after
  -- sequential application.
  table.sort(edits, function(a, b)
    if a.start_line ~= b.start_line then
      return a.start_line > b.start_line
    end
    -- Same start_line: process higher canonical order first (descending)
    local ao = a._canonical_order or 0
    local bo = b._canonical_order or 0
    return ao > bo
  end)

  local result = {}
  for i, l in ipairs(buf_lines) do
    result[i] = l
  end

  for _, edit in ipairs(edits) do
    if edit.action == "replace" then
      -- Remove old lines and insert new ones
      local new_result = {}
      for i = 1, edit.start_line - 1 do
        new_result[#new_result + 1] = result[i]
      end
      for _, l in ipairs(edit.new_lines) do
        new_result[#new_result + 1] = l
      end
      for i = edit.end_line + 1, #result do
        new_result[#new_result + 1] = result[i]
      end
      result = new_result
    elseif edit.action == "insert_after" then
      local new_result = {}
      for i = 1, edit.start_line do
        new_result[#new_result + 1] = result[i]
      end
      for _, l in ipairs(edit.new_lines) do
        new_result[#new_result + 1] = l
      end
      for i = edit.start_line + 1, #result do
        new_result[#new_result + 1] = result[i]
      end
      result = new_result
    end
  end

  return result
end

-- Export internals for testing
M.extract_this_fields = extract_this_fields
M.extract_copywith_fields = extract_copywith_fields
M.extract_tomap_fields = extract_tomap_fields
M.extract_frommap_fields = extract_frommap_fields
M.extract_tostring_fields = extract_tostring_fields
M.extract_equality_fields = extract_equality_fields
M.extract_hashcode_fields = extract_hashcode_fields
M.extract_props_fields = extract_props_fields
M.find_method_end = find_method_end

return M
