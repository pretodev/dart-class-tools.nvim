local utils = require("dart-class-tools.utils")

local M = {}

---@class DartField
---@field raw_type string
---@field name string
---@field line number 1-indexed line number
---@field is_final boolean
---@field is_const boolean
---@field is_enum boolean
---@field is_late boolean
local DartField = {}
DartField.__index = DartField

---@param raw_type string
---@param name string
---@param line? number
---@param is_final? boolean
---@param is_const? boolean
---@param is_late? boolean
---@return DartField
function DartField.new(raw_type, name, line, is_final, is_const, is_late)
  local self = setmetatable({}, DartField)
  self.raw_type = raw_type
  self.name = utils.to_var_name(name)
  self.line = line or 1
  self.is_final = is_final == nil and true or is_final
  self.is_const = is_const or false
  self.is_enum = false
  self.is_late = is_late or false
  return self
end

function DartField:type()
  if self:is_nullable() then
    return utils.remove_end(self.raw_type, "?")
  end
  return self.raw_type
end

function DartField:is_nullable()
  return self.raw_type:sub(-1) == "?"
end

--- Check if the raw_type matches or starts with the given collection type.
---@param ctype string e.g. "List", "Map", "Set"
---@return boolean
function DartField:is_collection_type(ctype)
  return self.raw_type == ctype
    or self.raw_type:sub(1, #ctype + 1) == ctype .. "<"
    or self.raw_type == ctype .. "?"
    or false
end

function DartField:is_list()
  local t = self.raw_type:gsub("%?$", "")
  return t == "List" or t:sub(1, 5) == "List<"
end

function DartField:is_map()
  local t = self.raw_type:gsub("%?$", "")
  return t == "Map" or t:sub(1, 4) == "Map<"
end

function DartField:is_set()
  local t = self.raw_type:gsub("%?$", "")
  return t == "Set" or t:sub(1, 4) == "Set<"
end

function DartField:is_collection()
  return self:is_list() or self:is_map() or self:is_set()
end

--- Return the inner type of a List or Set collection.
---@return DartField
function DartField:collection_type()
  if self:is_list() or self:is_set() then
    local collection = self:is_set() and "Set" or "List"
    local base = self.raw_type:gsub("%?$", "")
    local inner_type
    if base == collection then
      inner_type = "dynamic"
    else
      inner_type = base:match("^" .. collection .. "<(.+)>$") or "dynamic"
    end
    return DartField.new(inner_type, self.name, self.line, self.is_final)
  end
  return self
end

function DartField:is_primitive()
  local t = self:collection_type():type()
  return t == "String"
    or t == "num"
    or t == "dynamic"
    or t == "bool"
    or self:is_double()
    or self:is_int()
    or self:is_map()
end

function DartField:is_double()
  return self:collection_type():type() == "double"
end

function DartField:is_int()
  return self:collection_type():type() == "int"
end

function DartField:is_private()
  return self.name:sub(1, 1) == "_"
end

function DartField:def_value()
  if self:is_list() then
    return "const []"
  elseif self:is_map() or self:is_set() then
    return "const {}"
  else
    local t = self:type()
    if t == "String" then return "''"
    elseif t == "num" or t == "int" then return "0"
    elseif t == "double" then return "0.0"
    elseif t == "bool" then return "false"
    elseif t == "dynamic" then return "null"
    else return t .. "()"
    end
  end
end

M.DartField = DartField

---@class DartClass
---@field name string|nil
---@field full_generic_type string
---@field superclass string|nil
---@field interfaces string[]
---@field mixins string[]
---@field constr string|nil raw constructor text
---@field properties DartField[]
---@field starts_at_line number|nil 1-indexed
---@field ends_at_line number|nil 1-indexed
---@field constr_starts_at_line number|nil
---@field constr_ends_at_line number|nil
---@field class_content string
---@field is_enum_decl boolean whether this is an enum declaration (not a class)
local DartClass = {}
DartClass.__index = DartClass

---@return DartClass
function DartClass.new()
  local self = setmetatable({}, DartClass)
  self.name = nil
  self.full_generic_type = ""
  self.superclass = nil
  self.interfaces = {}
  self.mixins = {}
  self.constr = nil
  self.properties = {}
  self.starts_at_line = nil
  self.ends_at_line = nil
  self.constr_starts_at_line = nil
  self.constr_ends_at_line = nil
  self.class_content = ""
  self.is_enum_decl = false
  return self
end

function DartClass:type_name()
  return self.name .. self:generic_type()
end

function DartClass:generic_type()
  if not self.full_generic_type or self.full_generic_type == "" then
    return ""
  end
  -- Strip bounded generics: <T extends Foo> -> <T>
  local parts = {}
  for part in self.full_generic_type:gmatch("[^,]+") do
    part = utils.trim(part)
    local ext_pos = part:find("extends")
    if ext_pos then
      part = utils.trim(part:sub(1, ext_pos - 1))
      -- Re-add closing > if this was the last segment
    end
    parts[#parts + 1] = part
  end
  local result = table.concat(parts, ", ")
  -- Ensure closing bracket
  if not result:find(">") and self.full_generic_type:find(">") then
    result = result .. ">"
  end
  return result
end

function DartClass:props_end_at_line()
  if #self.properties > 0 then
    return self.properties[#self.properties].line
  end
  return -1
end

function DartClass:has_superclass()
  return self.superclass ~= nil
end

function DartClass:class_detected()
  return self.starts_at_line ~= nil
end

function DartClass:has_constructor()
  return self.constr_starts_at_line ~= nil
    and self.constr_ends_at_line ~= nil
    and self.constr ~= nil
end

function DartClass:has_ending()
  return self.ends_at_line ~= nil
end

function DartClass:has_properties()
  return #self.properties > 0
end

--- Return only properties suitable for code generation (excludes late fields).
---@return DartField[]
function DartClass:gen_properties()
  local result = {}
  for _, p in ipairs(self.properties) do
    if not p.is_late then
      result[#result + 1] = p
    end
  end
  return result
end

function DartClass:all_properties_final()
  local props = self:gen_properties()
  if #props == 0 then return false end
  for _, prop in ipairs(props) do
    if not prop.is_final then return false end
  end
  return true
end

--- Check if any property has the `late` keyword.
--- A class with late fields cannot have a const constructor.
---@return boolean
function DartClass:has_late_properties()
  for _, p in ipairs(self.properties) do
    if p.is_late then return true end
  end
  return false
end

function DartClass:few_props()
  return #self:gen_properties() <= 4
end

function DartClass:is_valid()
  return self:class_detected()
    and self:has_ending()
    and self:has_properties()
    and self:unique_prop_names()
end

function DartClass:is_widget()
  return self.superclass ~= nil
    and (self.superclass == "StatelessWidget" or self.superclass == "StatefulWidget")
end

function DartClass:is_state()
  return not self:is_widget()
    and self.superclass ~= nil
    and self.superclass:sub(1, 6) == "State<"
end

function DartClass:is_abstract()
  return utils.trim(self.class_content):sub(1, 14) == "abstract class"
end

function DartClass:is_sealed()
  return utils.trim(self.class_content):sub(1, 12) == "sealed class"
end

function DartClass:has_named_constructor()
  if self.constr ~= nil then
    local fConstr = self.constr:gsub("^%s*const%s+", "")
    fConstr = utils.trim(fConstr)
    return fConstr:sub(1, #self.name + 2) == self.name .. "({"
  end
  return true
end

function DartClass:uses_equatable()
  return (self:has_superclass() and self.superclass == "Equatable")
    or (self.mixins and utils.tbl_contains(self.mixins, "EquatableMixin"))
end

function DartClass:unique_prop_names()
  local seen = {}
  for _, p in ipairs(self.properties) do
    if seen[p.name] then return false end
    seen[p.name] = true
  end
  return true
end

M.DartClass = DartClass

--------------------------------------------------------------------------------
-- Parser
--------------------------------------------------------------------------------

--- Detect all enum type names declared in the text.
---@param text string
---@return table<string,boolean>
local function detect_enum_types(text)
  local enum_types = {}
  for name in text:gmatch("enum%s+([A-Z][a-zA-Z0-9_]*)") do
    enum_types[name] = true
  end
  return enum_types
end

--- Split a class declaration line while maintaining generic types.
---@param line string
---@return string[]
local function split_maintaining_generics(line)
  local words = {}
  local index = 1
  local generics = 0

  for i = 1, #line do
    local char = line:sub(i, i)
    local is_curly = char == "{"
    local is_space = char == " "

    if char == "<" then generics = generics + 1 end
    if char == ">" then generics = generics - 1 end

    if generics == 0 and (is_space or is_curly) then
      local word = utils.trim(line:sub(index, i - 1))

      if #word > 0 then
        local is_only_generic = word:sub(1, 1) == "<"
        if is_only_generic and #words > 0 then
          words[#words] = words[#words] .. word
        else
          words[#words + 1] = word
        end
      end

      if is_curly then break end
      index = i + 1
    end
  end

  return words
end

--- Parse enum declarations from text and return DartClass objects for them.
---@param text string
---@return DartClass[]
local function parse_enums(text)
  local enums = {}
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local i = 1
  while i <= #lines do
    local line = lines[i]
    local trimmed = utils.trim(line)

    -- Check for enum declaration
    local enum_name = trimmed:match("^enum%s+([A-Z][a-zA-Z0-9_]*)")
    if enum_name then
      local clazz = DartClass.new()
      clazz.name = enum_name
      clazz.starts_at_line = i
      clazz.is_enum_decl = true
      clazz.class_content = line

      local curly_brackets = utils.count_char(line, "{") - utils.count_char(line, "}")

      -- Check for enhanced enum with fields
      -- Look for semicolon that separates values from members
      local found_semicolon = false
      local j = i + 1

      while j <= #lines and curly_brackets > 0 do
        local eline = lines[j]
        clazz.class_content = clazz.class_content .. "\n" .. eline
        curly_brackets = curly_brackets + utils.count_char(eline, "{") - utils.count_char(eline, "}")

        -- Semicolon can be on its own line or at the end of the last enum value
        local etrimmed = utils.trim(eline)
        if etrimmed == ";" or (etrimmed:match(";%s*$") and not etrimmed:match("^final") and not etrimmed:match("^const")) then
          found_semicolon = true
        end

        if curly_brackets == 0 then
          clazz.ends_at_line = j
          break
        end
        j = j + 1
      end

      if not clazz.ends_at_line and curly_brackets == 0 then
        clazz.ends_at_line = i
      end

      -- Parse fields from enhanced enum (after the semicolon)
      if found_semicolon then
        local in_fields = false
        local bracket_depth = 0
        for k = i + 1, (clazz.ends_at_line or j) do
          local eline = utils.trim(lines[k])

          if eline == ";" or (eline:match(";%s*$") and not eline:match("^final") and not eline:match("^const")) then
            in_fields = true
          elseif in_fields then
            bracket_depth = bracket_depth + utils.count_char(eline, "(") - utils.count_char(eline, ")")

            if bracket_depth == 0
              and not eline:match("^//")
              and not eline:match("^@")
              and not eline:match("^}")
              and not eline:match("^{")
              and not eline:match("^const%s+" .. enum_name)
              and not utils.includes_one(eline, { "static", "factory", "get ", "set ", "return", "=>" }, false)
              and eline:match("final%s+")
            then
              -- Parse field: final Type name;
              local ftype, fname = eline:match("final%s+(.-)%s+([%w_]+)%s*;")
              if ftype and fname then
                local prop = DartField.new(ftype, fname, k, true, false)
                clazz.properties[#clazz.properties + 1] = prop
              end
            end

            -- Detect constructor
            local constr_match = eline:match("^const%s+" .. enum_name .. "%(")
              or eline:match("^" .. enum_name .. "%(")
            if constr_match then
              clazz.constr_starts_at_line = k
              -- Simple single-line constructor detection
              if eline:match(";%s*$") or eline:match(")%s*;%s*$") then
                clazz.constr_ends_at_line = k
                clazz.constr = lines[k]
              else
                -- Multi-line constructor
                local constr_text = lines[k]
                local ck = k + 1
                local parens = utils.count_char(lines[k], "(") - utils.count_char(lines[k], ")")
                while ck <= (clazz.ends_at_line or j) and parens > 0 do
                  constr_text = constr_text .. "\n" .. lines[ck]
                  parens = parens + utils.count_char(lines[ck], "(") - utils.count_char(lines[ck], ")")
                  ck = ck + 1
                end
                clazz.constr_ends_at_line = ck - 1
                clazz.constr = constr_text
              end
            end
          end
        end
      end

      if clazz:has_ending() and clazz:has_properties() then
        enums[#enums + 1] = clazz
      end

      i = (clazz.ends_at_line or j) + 1
    else
      i = i + 1
    end
  end

  return enums
end

--- Parse all classes from text buffer.
---@param text string
---@return DartClass[], table<string,boolean>
function M.parse_classes(text)
  local enum_types = detect_enum_types(text)
  local clazzes = {}
  local clazz = DartClass.new()
  local lines = {}

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local curly_brackets = 0
  local brackets = 0

  for i = 1, #lines do
    local line = lines[i]
    local trimmed = utils.trim(line)
    local class_line = trimmed:sub(1, 6) == "class "
      or trimmed:sub(1, 15) == "abstract class "
      or trimmed:sub(1, 13) == "sealed class "

    if class_line then
      clazz = DartClass.new()
      clazz.starts_at_line = i
      curly_brackets = 0
      brackets = 0

      local class_next = false
      local extends_next = false
      local implements_next = false
      local mixins_next = false

      local words = split_maintaining_generics(line)
      for _, word in ipairs(words) do
        word = utils.trim(word)
        if #word > 0 then
          if word == "class" then
            class_next = true
          elseif word == "extends" then
            extends_next = true
            mixins_next = false
            implements_next = false
          elseif extends_next then
            extends_next = false
            clazz.superclass = word
          elseif word == "with" then
            mixins_next = true
            extends_next = false
            implements_next = false
          elseif word == "implements" then
            mixins_next = false
            extends_next = false
            implements_next = true
          elseif class_next then
            class_next = false
            -- Extract generics
            local lt_pos = word:find("<")
            if lt_pos then
              -- Find matching >
              local gt_pos = word:match(".*()>")
              if gt_pos then
                clazz.full_generic_type = word:sub(lt_pos, gt_pos)
              end
              word = word:sub(1, lt_pos - 1)
            end
            clazz.name = word
          elseif mixins_next then
            local mixin = utils.remove_end(word, ",")
            mixin = utils.trim(mixin)
            if #mixin > 0 then
              clazz.mixins[#clazz.mixins + 1] = mixin
            end
          elseif implements_next then
            local impl = utils.remove_end(word, ",")
            impl = utils.trim(impl)
            if #impl > 0 then
              clazz.interfaces[#clazz.interfaces + 1] = impl
            end
          end
        end
      end

      -- Do not add State<T> classes
      if not clazz:is_state() then
        clazzes[#clazzes + 1] = clazz
      end
    end

    if clazz:class_detected() then
      curly_brackets = curly_brackets + utils.count_char(line, "{") - utils.count_char(line, "}")
      brackets = brackets + utils.count_char(line, "(") - utils.count_char(line, ")")

      -- Detect constructor
      local constr_trimmed = line:gsub("^%s*const%s+", ""):gsub("^%s+", "")
      local includes_constr = constr_trimmed:sub(1, #(clazz.name or "") + 1) == (clazz.name or "") .. "("
      if includes_constr and not class_line then
        clazz.constr_starts_at_line = i
      end

      if clazz.constr_starts_at_line and not clazz.constr_ends_at_line then
        clazz.constr = clazz.constr == nil and (line .. "\n") or (clazz.constr .. line .. "\n")
        if brackets == 0 then
          clazz.constr_ends_at_line = i
          clazz.constr = utils.remove_end(clazz.constr, "\n")
        end
      end

      clazz.class_content = clazz.class_content .. line
      if curly_brackets ~= 0 then
        clazz.class_content = clazz.class_content .. "\n"
      else
        clazz.ends_at_line = i
        clazz = DartClass.new()
      end

      -- Parse properties: only at curly depth 1 and bracket depth 0
      if brackets == 0 and curly_brackets == 1 then
        local line_valid = true

        -- Line shouldn't start with the class name (constructor or error)
        if clazz.name and utils.trim(line):sub(1, #clazz.name) == clazz.name then
          line_valid = false
        end
        -- Ignore comments
        if utils.trim(line):sub(1, 2) == "//" then line_valid = false end
        -- These symbols indicate not a field
        if utils.includes_one(line, { "{", "}", "=>", "@" }, false) then line_valid = false end
        -- Filter out keywords
        if utils.includes_one(line, { "static", "set", "get", "return", "factory" }) then line_valid = false end
        -- Do not include final values assigned a value
        if utils.includes_all(line, { "final ", "=" }) then line_valid = false end
        -- Do not include non-final fields declared after constructor
        if clazz.constr_starts_at_line and not line:find("final ") then line_valid = false end
        -- Make sure not to catch abstract functions
        if line:gsub("%s", ""):sub(-2) == ");" then line_valid = false end

        if line_valid then
          local field_type = nil
          local field_name = nil
          local is_final = false
          local is_const_field = false
          local is_late_field = false

          -- Remove comments before parsing
          local line_nc = line
          local comment_pos = line:find("//")
          if comment_pos then
            line_nc = utils.trim(line:sub(1, comment_pos - 1))
          end

          local words_list = {}
          for w in utils.trim(line_nc):gmatch("%S+") do
            words_list[#words_list + 1] = w
          end

          for wi = 1, #words_list do
            local word = words_list[wi]
            local is_last = wi == #words_list

            if #word > 0 and word ~= "}" and word ~= "{" then
              if word == "final" then
                is_final = true
              elseif wi == 1 and word == "const" then
                is_const_field = true
              elseif word == "late" then
                is_late_field = true
              end

              if word ~= "final" and word ~= "const" and word ~= "late" then
                local is_variable = word:sub(-1) == ";"
                  or (not is_last and words_list[wi + 1] == "=")
                -- Make sure we don't capture abstract functions
                is_variable = is_variable and not word:find("%(") and not word:find("%)")

                if is_variable then
                  if field_name == nil then
                    field_name = utils.remove_end(word, ";")
                  end
                else
                  if field_type == nil then
                    field_type = word
                  elseif field_name == nil then
                    -- Types can have gaps: Pair<A, B>
                    field_type = field_type .. " " .. word
                  end
                end
              end
            end
          end

          if field_type and field_name then
            local prop = DartField.new(field_type, field_name, i, is_final, is_const_field, is_late_field)

            -- Auto-detect enums
            local base_type = field_type:gsub("%?$", "")
            if enum_types[base_type] then
              prop.is_enum = true
            end

            -- Check previous line for // enum comment (legacy)
            if i > 1 and not prop.is_enum then
              local prev_line = lines[i - 1]
              if prev_line and prev_line:match("/%/%s*enum") then
                prop.is_enum = true
              end
            end

            clazz.properties[#clazz.properties + 1] = prop
          end
        end
      end
    end
  end

  -- Also parse enums
  local enum_classes = parse_enums(text)
  for _, ec in ipairs(enum_classes) do
    clazzes[#clazzes + 1] = ec
  end

  return clazzes, enum_types
end

--- Find a class/enum at a specific line.
---@param clazzes DartClass[]
---@param line_nr number 1-indexed
---@return DartClass|nil
function M.find_class_at_line(clazzes, line_nr)
  for _, clazz in ipairs(clazzes) do
    if clazz.starts_at_line and clazz.ends_at_line then
      if line_nr >= clazz.starts_at_line and line_nr <= clazz.ends_at_line then
        return clazz
      end
    end
  end
  return nil
end

--- Find a class/enum by name.
--- When multiple classes share the same name (unlikely but possible), returns
--- the first match.  Falls back to nil if not found.
---@param clazzes DartClass[]
---@param name string
---@return DartClass|nil
function M.find_class_by_name(clazzes, name)
  for _, clazz in ipairs(clazzes) do
    if clazz.name == name then
      return clazz
    end
  end
  return nil
end

--- Check if cursor is on a valid position for code actions.
---@param clazz DartClass
---@param line_nr number 1-indexed
---@return boolean
function M.is_valid_action_position(clazz, line_nr)
  if not clazz or not clazz:is_valid() then return false end

  local is_at_class_decl = line_nr == clazz.starts_at_line
  local is_in_properties = false
  for _, p in ipairs(clazz.properties) do
    if p.line == line_nr then
      is_in_properties = true
      break
    end
  end
  local is_in_constr = clazz.constr_starts_at_line
    and clazz.constr_ends_at_line
    and line_nr >= clazz.constr_starts_at_line
    and line_nr <= clazz.constr_ends_at_line

  return is_at_class_decl or is_in_properties or is_in_constr
end

return M
