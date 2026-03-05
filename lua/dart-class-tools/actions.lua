local parser = require("dart-class-tools.parser")
local generator = require("dart-class-tools.generator")
local incremental = require("dart-class-tools.incremental")

local M = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- The canonical order of method kinds that form a "data class".
local ALL_KINDS = {
  "constructor", "copyWith", "toMap", "fromMap", "toJson", "fromJson",
  "toString", "equality", "hashCode",
}

--- Which kinds have field-level tracking (so we can detect incomplete blocks).
local FIELD_TRACKED = {
  constructor = true,
  copyWith = true,
  toMap = true,
  fromMap = true,
  toString = true,
  equality = true,
  hashCode = true,
}

--- Determine which kinds are applicable for a given class.
---@param clazz DartClass
---@return table<string, boolean>
local function applicable_kinds(clazz)
  local kinds = { constructor = true }

  if clazz:is_widget() then
    -- Widgets only get constructor
    return kinds
  end

  local skip_instance = clazz:is_abstract() or clazz:is_sealed()
  if clazz:has_superclass() and not clazz:is_abstract() and not clazz:is_sealed() then
    skip_instance = false
  end

  if not skip_instance then
    kinds.copyWith = true
    kinds.toMap = true
    kinds.fromMap = true
    kinds.toJson = true
    kinds.fromJson = true
  end

  kinds.toString = true
  kinds.equality = true
  kinds.hashCode = true

  return kinds
end

--- Get the status of each method kind for a class.
---@param clazz DartClass
---@param blocks table<string, MethodBlock>
---@return table<string, BlockStatus>
local function get_all_statuses(clazz, blocks)
  local class_fields = incremental.get_class_field_names(clazz)
  local statuses = {}

  for _, kind in ipairs(ALL_KINDS) do
    if kind == "toJson" or kind == "fromJson" then
      statuses[kind] = incremental.wrapper_status(blocks[kind])
    elseif FIELD_TRACKED[kind] then
      statuses[kind] = incremental.block_status(blocks[kind], class_fields)
    else
      statuses[kind] = blocks[kind] and "complete" or "absent"
    end
  end

  return statuses
end

--- Get a human-readable title for a code action.
---@param kind string
---@param status BlockStatus
---@return string
local function action_title(kind, status)
  local names = {
    constructor = "constructor",
    copyWith = "copyWith",
    toMap = "toMap",
    fromMap = "fromMap",
    toJson = "toJson",
    fromJson = "fromJson",
    toString = "toString",
    equality = "equality (== & hashCode)",
    dataClass = "data class",
  }
  local name = names[kind] or kind

  if status == "incomplete" then
    return "Update " .. name .. " (add missing fields)"
  elseif status == "absent" then
    return "Generate " .. name
  else
    return "Regenerate " .. name
  end
end

--------------------------------------------------------------------------------
-- Incremental apply: the core of the new architecture
--
-- Instead of rebuilding the entire class, we:
-- 1. Detect existing blocks and their field coverage
-- 2. Generate only the requested method(s) fresh
-- 3. Compare with existing blocks → produce minimal edits
-- 4. Apply edits to the buffer
--------------------------------------------------------------------------------

--- Generate the text for a single kind, returning the generated text and imports.
---@param clazz DartClass
---@param kind string
---@return string|nil text, string[] imports
local function generate_kind(clazz, kind)
  local imports = {}
  local text

  if kind == "constructor" then
    text = generator.generate_constructor(clazz)
  elseif kind == "copyWith" then
    local t, imps = generator.generate_copy_with(clazz)
    text = t
    imports = imps or {}
  elseif kind == "toMap" then
    text = generator.generate_to_map(clazz)
  elseif kind == "fromMap" then
    local t, imps = generator.generate_from_map(clazz)
    text = t
    imports = imps or {}
  elseif kind == "toJson" then
    local t, imps = generator.generate_to_json(clazz)
    text = t
    imports = imps or {}
  elseif kind == "fromJson" then
    local t, imps = generator.generate_from_json(clazz)
    text = t
    imports = imps or {}
  elseif kind == "toString" then
    text = generator.generate_to_string(clazz)
  elseif kind == "equality" then
    local t, imps = generator.generate_equality(clazz)
    text = t
    imports = imps or {}
  elseif kind == "hashCode" then
    local t, imps = generator.generate_hash_code(clazz)
    text = t
    imports = imps or {}
  end

  return text, imports
end

--- Apply incremental edits for the given kind(s) to a buffer.
--- This is the main entry point for executing actions.
---@param bufnr number
---@param clazz DartClass the class from the action (may be stale/serialized — only .name is used)
---@param kinds string[]|nil list of kinds to generate/update, or nil for "data class" (all applicable)
local function apply_incremental(bufnr, clazz, kinds)
  -- Re-parse to get fresh state
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, line_count, false)

  -- Convert to 1-indexed
  local lines_1 = {}
  for i, l in ipairs(buf_lines) do lines_1[i] = l end

  -- Re-parse the file to get fresh class state.
  -- Use class NAME (not starts_at_line) to find the correct class.
  -- starts_at_line can become stale if the buffer was modified between
  -- action creation and execution (e.g., another class was generated first,
  -- shifting line numbers).  The class name is a plain string that is
  -- always stable and survives LSP argument serialization.
  local text = table.concat(buf_lines, "\n")
  local clazzes = parser.parse_classes(text)
  local class_name = clazz.name
  if not class_name then
    vim.notify("dart-class-tools: action has no class name", vim.log.levels.WARN)
    return
  end
  local fresh_clazz = parser.find_class_by_name(clazzes, class_name)
  if not fresh_clazz or not fresh_clazz:is_valid() then
    vim.notify("dart-class-tools: could not re-parse class '" .. class_name .. "'", vim.log.levels.WARN)
    return
  end

  -- If kinds is nil, compute all applicable kinds from the fresh class.
  -- This avoids calling metatable methods on the potentially stale/serialized
  -- action.clazz object (which may have lost its metatable during LSP
  -- argument serialization).
  if not kinds then
    local ak = applicable_kinds(fresh_clazz)
    kinds = {}
    for _, kind in ipairs(ALL_KINDS) do
      if ak[kind] then kinds[#kinds + 1] = kind end
    end
  end

  -- Detect existing blocks
  local blocks = incremental.detect_blocks(fresh_clazz, lines_1)

  -- Collect all edits and imports
  local edits = {}
  local all_imports = {}

  local function add_import(imp)
    for _, existing in ipairs(all_imports) do
      if existing == imp then return end
    end
    all_imports[#all_imports + 1] = imp
  end

  for _, kind in ipairs(kinds) do
    local gen_text, imports = generate_kind(fresh_clazz, kind)
    if gen_text then
      local edit = incremental.build_edit(kind, fresh_clazz, blocks, gen_text)
      if edit then
        edits[#edits + 1] = edit
        -- NOTE: We do NOT mutate `blocks` with faked entries here.
        -- All insert_after edits for absent blocks target the same start_line
        -- (props_end or the end of the last preceding block in original buffer space).
        -- apply_edits() sorts by start_line DESC with canonical order DESC tiebreaker,
        -- which correctly stacks multiple inserts at the same point.
        --
        -- For "replace" edits on existing blocks, the block already exists in the
        -- blocks table and subsequent kinds' insert points are unaffected since
        -- replacements don't shift line numbers in the original buffer coordinate space.
      end
      for _, imp in ipairs(imports) do add_import(imp) end
    end
  end

  if #edits == 0 and #all_imports == 0 then
    vim.notify("dart-class-tools: no changes needed (already up to date)", vim.log.levels.INFO)
    return
  end

  -- Apply edits to buffer
  if #edits > 0 then
    local new_lines = incremental.apply_edits(lines_1, edits)
    vim.api.nvim_buf_set_lines(bufnr, 0, line_count, false, new_lines)
  end

  -- Handle imports
  if #all_imports > 0 then
    local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, vim.api.nvim_buf_line_count(bufnr), false)
    local existing_text = table.concat(current_lines, "\n")

    local new_imports = {}
    for _, imp in ipairs(all_imports) do
      local import_str
      if imp:sub(1, 6) == "import" then
        import_str = imp
      else
        import_str = "import '" .. imp .. "';"
      end

      if not existing_text:find(import_str, 1, true) then
        local package_part = imp:match("package:(.+)") or imp
        local has_import = false
        for _, line in ipairs(current_lines) do
          if line:find(package_part, 1, true) and line:match("^import ") then
            has_import = true
            break
          end
        end
        if not has_import then
          new_imports[#new_imports + 1] = import_str
        end
      end
    end

    if #new_imports > 0 then
      local insert_line = 0
      for i, line in ipairs(current_lines) do
        if line:match("^import ") or line:match("^export ") or line:match("^part ") then
          insert_line = i
        end
      end

      if insert_line == 0 then
        for i, line in ipairs(current_lines) do
          if line:match("^library ") or line:match("^//") then
            insert_line = i
          else
            break
          end
        end
      end

      for j, imp_line in ipairs(new_imports) do
        vim.api.nvim_buf_set_lines(bufnr, insert_line + j - 1, insert_line + j - 1, false, { imp_line })
      end

      local after_import_line = insert_line + #new_imports
      local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, vim.api.nvim_buf_line_count(bufnr), false)
      if after_import_line < #all_lines and all_lines[after_import_line + 1] ~= "" then
        vim.api.nvim_buf_set_lines(bufnr, after_import_line, after_import_line, false, { "" })
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Code action provider
--------------------------------------------------------------------------------

--- Provide code actions for the current buffer position.
---@param bufnr number
---@param cursor_line number 1-indexed
---@return table[] list of code action items
function M.get_code_actions(bufnr, cursor_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, vim.api.nvim_buf_line_count(bufnr), false)
  local text = table.concat(lines, "\n")

  local clazzes = parser.parse_classes(text)
  local clazz = parser.find_class_at_line(clazzes, cursor_line)

  if not clazz or not clazz:is_valid() then return {} end
  if clazz.is_enum_decl then return {} end
  if not parser.is_valid_action_position(clazz, cursor_line) then return {} end

  -- Convert to 1-indexed for block detection
  local lines_1 = {}
  for i, l in ipairs(lines) do lines_1[i] = l end

  local blocks = incremental.detect_blocks(clazz, lines_1)
  local statuses = get_all_statuses(clazz, blocks)
  local kinds = applicable_kinds(clazz)

  local actions = {}

  -- Data class action: show if ANY kind is absent or incomplete
  if not clazz:is_widget() then
    local any_needed = false
    for _, kind in ipairs(ALL_KINDS) do
      if kinds[kind] then
        local s = statuses[kind]
        if s == "absent" or s == "incomplete" then
          any_needed = true
          break
        end
      end
    end

    if any_needed then
      -- Determine if it's a generate or update
      local any_exists = false
      for _, kind in ipairs(ALL_KINDS) do
        if kinds[kind] and statuses[kind] ~= "absent" then
          any_exists = true
          break
        end
      end
      local dc_title = any_exists and "Update data class (add missing)" or "Generate data class"
      actions[#actions + 1] = {
        title = dc_title,
        kind = "quickfix",
        bufnr = bufnr,
        clazz = clazz,
        action_kinds = nil, -- nil means "all applicable"
      }
    end
  end

  -- Individual actions: only show if absent or incomplete
  for _, kind in ipairs(ALL_KINDS) do
    if not kinds[kind] then goto continue end

    -- equality and hashCode are bundled together
    if kind == "hashCode" then goto continue end

    local status = statuses[kind]
    -- For equality, also check hashCode
    if kind == "equality" then
      local hc_status = statuses.hashCode
      -- If both are complete, skip
      if status == "complete" and hc_status == "complete" then goto continue end
      -- If either is absent/incomplete, show action
      if status == "complete" and hc_status ~= "complete" then
        status = hc_status
      end
    end

    if status == "complete" then goto continue end

    local action_kinds = { kind }
    if kind == "equality" then
      action_kinds = { "equality", "hashCode" }
    end

    actions[#actions + 1] = {
      title = action_title(kind, status),
      kind = "quickfix",
      bufnr = bufnr,
      clazz = clazz,
      action_kinds = action_kinds,
    }

    ::continue::
  end

  return actions
end

--- Execute a code action.
---@param action table code action from get_code_actions
function M.execute_action(action)
  local clazz = action.clazz
  local bufnr = action.bufnr

  if action.action_kinds then
    -- Specific kinds requested
    apply_incremental(bufnr, clazz, action.action_kinds)
  else
    -- Data class: generate all applicable kinds.
    -- Pass nil for kinds — apply_incremental will compute them from the
    -- fresh class (not the potentially stale/serialized action.clazz).
    apply_incremental(bufnr, clazz, nil)
  end
end

-- Export for testing
M.applicable_kinds = applicable_kinds
M.get_all_statuses = get_all_statuses
M.apply_incremental = apply_incremental
M.generate_kind = generate_kind

return M
