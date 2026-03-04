local parser = require("dart-class-tools.parser")
local generator = require("dart-class-tools.generator")

local M = {}

--- Apply a generation result to the current buffer.
---@param bufnr number
---@param clazz DartClass
---@param part? string specific part to generate, or nil for all
local function apply_generation(bufnr, clazz, part)
  local result = generator.generate(clazz, part)
  if not result then
    vim.notify("dart-class-tools: no changes generated", vim.log.levels.WARN)
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, line_count, false)
  -- Convert to 1-indexed table
  local buf_lines_1 = {}
  for i, l in ipairs(buf_lines) do
    buf_lines_1[i] = l
  end

  local new_lines, imports = generator.build_class_text(buf_lines_1, clazz, result)

  if #new_lines == 0 then
    vim.notify("dart-class-tools: no changes to apply", vim.log.levels.INFO)
    return
  end

  -- Replace class lines in the buffer (0-indexed for nvim api)
  vim.api.nvim_buf_set_lines(bufnr, clazz.starts_at_line - 1, clazz.ends_at_line, false, new_lines)

  -- Handle imports
  if imports and #imports > 0 then
    local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, vim.api.nvim_buf_line_count(bufnr), false)
    local existing_text = table.concat(current_lines, "\n")

    local new_imports = {}
    for _, imp in ipairs(imports) do
      local import_str
      if imp:sub(1, 6) == "import" then
        import_str = imp
      else
        import_str = "import '" .. imp .. "';"
      end

      if not existing_text:find(import_str, 1, true) then
        -- Also check if already has the import without exact match
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
      -- Find insertion point (after existing imports or at top)
      local insert_line = 0
      for i, line in ipairs(current_lines) do
        if line:match("^import ") or line:match("^export ") or line:match("^part ") then
          insert_line = i
        end
      end

      -- Add blank line before first import if needed
      if insert_line == 0 then
        -- Insert at very top, but after any library declarations or comments
        for i, line in ipairs(current_lines) do
          if line:match("^library ") or line:match("^//") then
            insert_line = i
          else
            break
          end
        end
      end

      -- Insert new imports
      for j, imp_line in ipairs(new_imports) do
        vim.api.nvim_buf_set_lines(bufnr, insert_line + j - 1, insert_line + j - 1, false, { imp_line })
      end

      -- Add blank line after imports if next line isn't blank
      local after_import_line = insert_line + #new_imports
      local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, vim.api.nvim_buf_line_count(bufnr), false)
      if after_import_line < #all_lines and all_lines[after_import_line + 1] ~= "" then
        vim.api.nvim_buf_set_lines(bufnr, after_import_line, after_import_line, false, { "" })
      end
    end
  end
end

--- Get the action title for a part.
---@param part string
---@return string
local function action_title(part)
  local titles = {
    constructor = "Generate constructor",
    copyWith = "Generate copyWith",
    toMap = "Generate toMap",
    fromMap = "Generate fromMap",
    toJson = "Generate toJson",
    fromJson = "Generate fromJson",
    toString = "Generate toString",
    equality = "Generate equality",
    dataClass = "Generate data class",
  }
  return titles[part] or ("Generate " .. part)
end

--- Check which methods already exist in the class.
---@param clazz DartClass
---@return table<string,boolean>
local function existing_methods(clazz)
  local exists = {}
  if parser.method_exists(clazz, clazz.name .. "({") or parser.method_exists(clazz, clazz.name .. "([") or parser.method_exists(clazz, clazz.name .. "(") then
    -- Check more carefully: does the class have a real constructor (not just the class name appearing)
    if clazz:has_constructor() then
      exists.constructor = true
    end
  end
  if parser.method_exists(clazz, "copyWith(") then exists.copyWith = true end
  if parser.method_exists(clazz, "Map<String,dynamic>toMap()") then exists.toMap = true end
  if parser.method_exists(clazz, "factory" .. clazz.name .. ".fromMap(") then exists.fromMap = true end
  if parser.method_exists(clazz, "StringtoJson()") then exists.toJson = true end
  if parser.method_exists(clazz, "factory" .. clazz.name .. ".fromJson(") then exists.fromJson = true end
  if parser.method_exists(clazz, "StringtoString()") then exists.toString = true end
  if parser.method_exists(clazz, "booloperator==") then exists.equality = true end
  return exists
end

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

  -- Skip enum declarations — we only generate for classes
  if clazz.is_enum_decl then return {} end

  if not parser.is_valid_action_position(clazz, cursor_line) then return {} end

  local exists = existing_methods(clazz)
  local actions = {}

  local is_widget = clazz:is_widget()
  local is_abstract_or_sealed = clazz:is_abstract() or clazz:is_sealed()
  -- Allow sealed subclasses
  local skip_instance = is_abstract_or_sealed
    and not (clazz:has_superclass() and not clazz:is_abstract() and not clazz:is_sealed())

  -- Data class action (full generation) -- not for widgets
  if not is_widget then
    actions[#actions + 1] = {
      title = action_title("dataClass"),
      kind = "quickfix",
      bufnr = bufnr,
      clazz = clazz,
      part = nil,
    }
  end

  -- Constructor
  if not exists.constructor then
    actions[#actions + 1] = {
      title = action_title("constructor"),
      kind = "quickfix",
      bufnr = bufnr,
      clazz = clazz,
      part = "constructor",
    }
  end

  if not is_widget then
    if not skip_instance then
      -- copyWith
      if not exists.copyWith then
        actions[#actions + 1] = {
          title = action_title("copyWith"),
          kind = "quickfix",
          bufnr = bufnr,
          clazz = clazz,
          part = "copyWith",
        }
      end

      -- toMap
      if not exists.toMap then
        actions[#actions + 1] = {
          title = action_title("toMap"),
          kind = "quickfix",
          bufnr = bufnr,
          clazz = clazz,
          part = "toMap",
        }
      end

      -- fromMap
      if not exists.fromMap then
        actions[#actions + 1] = {
          title = action_title("fromMap"),
          kind = "quickfix",
          bufnr = bufnr,
          clazz = clazz,
          part = "fromMap",
        }
      end

      -- toJson
      if not exists.toJson then
        actions[#actions + 1] = {
          title = action_title("toJson"),
          kind = "quickfix",
          bufnr = bufnr,
          clazz = clazz,
          part = "toJson",
        }
      end

      -- fromJson
      if not exists.fromJson then
        actions[#actions + 1] = {
          title = action_title("fromJson"),
          kind = "quickfix",
          bufnr = bufnr,
          clazz = clazz,
          part = "fromJson",
        }
      end
    end

    -- toString
    if not exists.toString then
      actions[#actions + 1] = {
        title = action_title("toString"),
        kind = "quickfix",
        bufnr = bufnr,
        clazz = clazz,
        part = "toString",
      }
    end

    -- equality (== and hashCode)
    if not exists.equality then
      actions[#actions + 1] = {
        title = action_title("equality"),
        kind = "quickfix",
        bufnr = bufnr,
        clazz = clazz,
        part = "equality",
      }
    end
  end

  return actions
end

--- Execute a code action.
---@param action table code action from get_code_actions
function M.execute_action(action)
  apply_generation(action.bufnr, action.clazz, action.part)
end

return M
