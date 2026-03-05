local utils = require("dart-class-tools.utils")
local parser = require("dart-class-tools.parser")

local M = {}

--- Configuration defaults.
local default_config = {
  use_equatable = false,
  use_as_cast = true,
  use_default_values = false,
  use_jenkins_hash = false,
  use_value_getter = false,
  constructor_default_values = false,
  json_key_format = "variable", -- "variable" | "snake_case" | "camelCase"
}

---@type table
M.config = vim.deepcopy(default_config)

--- Convert variable name to JSON key based on config.
---@param src string
---@return string
local function var_to_key(src)
  local fmt = M.config.json_key_format or "variable"
  if fmt == "snake_case" then
    return src:gsub("(%u)", function(c) return "_" .. c:lower() end)
  elseif fmt == "camelCase" then
    -- Already camelCase from Dart convention
    return src
  else
    return src
  end
end

--- Detect if the project is a Flutter project by checking pubspec.yaml.
--- Result is cached per working directory to avoid repeated file I/O.
---@return boolean
local _flutter_cache = {}
local function is_flutter_project()
  local cwd = vim.fn.getcwd()
  if _flutter_cache[cwd] ~= nil then
    return _flutter_cache[cwd]
  end
  local pubspec_path = cwd .. "/pubspec.yaml"
  local f = io.open(pubspec_path, "r")
  if not f then
    _flutter_cache[cwd] = false
    return false
  end
  local content = f:read("*a")
  f:close()
  local result = content:find("flutter:") ~= nil and content:find("sdk: flutter") ~= nil
  _flutter_cache[cwd] = result
  return result
end

--------------------------------------------------------------------------------
-- Constructor generation
--------------------------------------------------------------------------------

---@param clazz DartClass
---@return string
function M.generate_constructor(clazz)
  local with_defaults = M.config.constructor_default_values

  local constr = "  "
  local start_bracket = "({"
  local end_bracket = "})"

  if clazz.constr ~= nil and clazz:has_constructor() then
    local existing_has_const = utils.trim(clazz.constr):sub(1, 5) == "const"
    local gen_props = clazz:gen_properties()
    local all_final = #gen_props > 0 and clazz:all_properties_final()
    local can_be_const = not clazz:has_late_properties()

    if can_be_const and (existing_has_const or all_final) then
      constr = constr .. "const "
    end

    -- Detect existing bracket style
    local fConstr = clazz.constr:gsub("^%s*const%s+", "")
    fConstr = utils.trim(fConstr)

    if fConstr:sub(1, #clazz.name + 2) == clazz.name .. "([" then
      start_bracket = "(["
    elseif fConstr:sub(1, #clazz.name + 2) == clazz.name .. "({" then
      start_bracket = "({"
    else
      start_bracket = "("
    end

    if fConstr:find("%]%)") then end_bracket = "])"
    elseif fConstr:find("%}%)") then end_bracket = "})"
    else end_bracket = ")"
    end
  else
    local all_final = #clazz:gen_properties() > 0 and clazz:all_properties_final()
    local can_be_const = not clazz:has_late_properties()
    if clazz:is_widget() or (all_final and can_be_const) then
      constr = constr .. "const "
    end
  end

  constr = constr .. clazz.name .. start_bracket .. "\n"

  -- Add Key? key for widgets
  if clazz:is_widget() then
    local has_key = false
    if clazz.constr then
      for line in clazz.constr:gmatch("[^\n]+") do
        if utils.trim(line):sub(1, 8) == "Key? key" then
          has_key = true
          break
        end
      end
    end
    if not has_key then
      constr = constr .. "    Key? key,\n"
    end
  end

  for _, prop in ipairs(clazz:gen_properties()) do
    local parameter = "this." .. prop.name

    constr = constr .. "    "

    if not prop:is_nullable() then
      local has_default = with_defaults
        and ((prop:is_primitive() or prop:is_collection()) and prop.raw_type ~= "dynamic")
      local is_named = start_bracket == "({" and end_bracket == "})"

      if has_default then
        constr = constr .. parameter .. " = " .. prop:def_value() .. ",\n"
      elseif is_named then
        constr = constr .. "required " .. parameter .. ",\n"
      else
        constr = constr .. parameter .. ",\n"
      end
    else
      constr = constr .. parameter .. ",\n"
    end
  end

  if clazz:is_widget() then
    constr = constr .. "  " .. end_bracket .. " : super(key: key);"
  else
    -- Check for existing initializer list or body
    if clazz.constr ~= nil and clazz:has_constructor() then
      local idx_colon = clazz.constr:find(" : ")
      local ends_with_brace = utils.trim(clazz.constr):sub(-1) == "{"

      if idx_colon then
        local ending = clazz.constr:sub(idx_colon + 1)
        constr = constr .. "  " .. end_bracket .. " " .. ending
      elseif ends_with_brace then
        local brace_pos = clazz.constr:find("{[^{]*$")
        if brace_pos then
          local ending = clazz.constr:sub(brace_pos)
          constr = constr .. "  " .. end_bracket .. " " .. ending
        else
          constr = constr .. "  " .. end_bracket .. ";"
        end
      else
        constr = constr .. "  " .. end_bracket .. ";"
      end
    else
      constr = constr .. "  " .. end_bracket .. ";"
    end
  end

  return constr
end

--------------------------------------------------------------------------------
-- copyWith generation
--------------------------------------------------------------------------------

---@param clazz DartClass
---@return string, string[] extra_imports
function M.generate_copy_with(clazz)
  local uses_vg = M.config.use_value_getter
  local imports = {}
  local method = "  " .. clazz:type_name() .. " copyWith({\n"

  for _, prop in ipairs(clazz:gen_properties()) do
    if uses_vg and prop:is_nullable() then
      method = method .. "    ValueGetter<" .. prop.raw_type .. ">? " .. prop.name .. ",\n"
    else
      method = method .. "    " .. prop:type() .. "? " .. prop.name .. ",\n"
    end
  end

  method = method .. "  }) {\n"
  method = method .. "    return " .. clazz:type_name() .. "(\n"

  for _, p in ipairs(clazz:gen_properties()) do
    local prefix = clazz:has_named_constructor() and (p.name .. ": ") or ""

    if uses_vg and p:is_nullable() then
      method = method .. "      " .. prefix .. p.name .. " != null ? " .. p.name .. "() : this." .. p.name .. ",\n"
    else
      method = method .. "      " .. prefix .. p.name .. " ?? this." .. p.name .. ",\n"
    end
  end

  method = method .. "    );\n"
  method = method .. "  }"

  if uses_vg then
    imports[#imports + 1] = "package:flutter/widgets.dart"
  end

  return method, imports
end

--------------------------------------------------------------------------------
-- toMap generation
--------------------------------------------------------------------------------

---@param prop DartField
---@param name? string
---@param end_flag? string
---@return string
local function custom_type_to_map(prop, name, end_flag)
  local p = prop:is_collection() and prop:collection_type() or prop
  name = name or p.name
  end_flag = end_flag or ",\n"
  local null_safe = p:is_nullable() and "?" or ""

  local t = p:type()
  if t == "DateTime" then
    return name .. null_safe .. ".toUtc().toIso8601String()" .. end_flag
  elseif t == "Color" then
    return name .. null_safe .. ".value" .. end_flag
  elseif t == "IconData" then
    return name .. null_safe .. ".codePoint" .. end_flag
  else
    if p:is_primitive() then
      return name .. end_flag
    else
      return name .. null_safe .. ".toMap()" .. end_flag
    end
  end
end

---@param clazz DartClass
---@return string
function M.generate_to_map(clazz)
  local props = clazz:gen_properties()
  local method = "  Map<String, dynamic> toMap() {\n"
  method = method .. "    return {\n"

  for idx, p in ipairs(props) do
    local key = var_to_key(p.name)
    method = method .. "      '" .. key .. "': "

    if p.is_enum then
      local null_safe = p:is_nullable() and "?" or ""
      method = method .. p.name .. null_safe .. ".name,\n"
    elseif p:is_collection() then
      local null_safe = p:is_nullable() and "?" or ""

      if p:is_map() or p:collection_type():is_primitive() then
        local map_flag = p:is_set() and (null_safe .. ".toList()") or ""
        method = method .. p.name .. map_flag .. ",\n"
      else
        method = method .. p.name .. null_safe .. ".map((x) => "
          .. custom_type_to_map(p, "x", "") .. ")" .. null_safe .. ".toList(),\n"
      end
    else
      method = method .. custom_type_to_map(p)
    end

    if idx == #props then
      method = method .. "    };\n"
    end
  end

  method = method .. "  }"
  return method
end

--------------------------------------------------------------------------------
-- fromMap generation
--------------------------------------------------------------------------------

---@param prop DartField
---@param value? string
---@return string
local function custom_type_from_map(prop, value)
  local p = prop:is_collection() and prop:collection_type() or prop
  local is_nested = value ~= nil
  value = value or ("map['" .. var_to_key(p.name) .. "']")

  local t = p:type()
  if t == "DateTime" then
    return "DateTime.parse(" .. value .. ").toLocal()"
  elseif t == "Color" then
    return "Color(" .. value .. ")"
  elseif t == "IconData" then
    return "IconData(" .. value .. ", fontFamily: 'MaterialIcons')"
  else
    local map_value
    if is_nested then
      if M.config.use_as_cast then
        map_value = "Map<String, dynamic>.from(" .. value .. " as Map<String, dynamic>)"
      else
        map_value = "Map<String, dynamic>.from(" .. value .. ")"
      end
    else
      map_value = value
    end
    return p:type() .. ".fromMap(" .. map_value .. ")"
  end
end

---@param prop DartField
---@return string
local function get_cast_type(prop)
  if prop:is_collection() then
    if prop:is_list() then
      return prop:is_nullable() and "List<dynamic>?" or "List<dynamic>"
    elseif prop:is_set() then
      return prop:is_nullable() and "Set<dynamic>?" or "Set<dynamic>"
    elseif prop:is_map() then
      return prop:is_nullable() and "Map<String, dynamic>?" or "Map<String, dynamic>"
    end
  elseif not prop:is_primitive() and not prop.is_enum then
    return prop:is_nullable() and "Map<String, dynamic>?" or "Map<String, dynamic>"
  elseif prop.is_enum then
    return prop:is_nullable() and "String?" or "String"
  else
    return prop:is_nullable() and prop.raw_type or prop:type()
  end
  return prop.raw_type
end

---@param value string
---@param prop DartField
---@return string
local function apply_cast(value, prop)
  if not M.config.use_as_cast then return value end
  local cast_type = get_cast_type(prop)
  return value .. " as " .. cast_type
end

---@param clazz DartClass
---@return string, string[] extra_imports
function M.generate_from_map(clazz)
  local with_defaults = M.config.use_default_values
  local use_as_cast = M.config.use_as_cast
  local props = clazz:gen_properties()
  local imports = {}

  -- Check for nullable enums -> needs collection import
  for _, p in ipairs(props) do
    if p.is_enum and p:is_nullable() then
      imports[#imports + 1] = "package:collection/collection.dart"
      break
    end
  end

  local method = "  factory " .. clazz.name .. ".fromMap(Map<String, dynamic> map) {\n"
  method = method .. "    return " .. clazz:type_name() .. "(\n"

  for idx, p in ipairs(props) do
    local key = var_to_key(p.name)
    local prefix = clazz:has_named_constructor() and (p.name .. ": ") or ""
    method = method .. "      " .. prefix

    local base_value = "map['" .. key .. "']"
    local value = apply_cast(base_value, p)
    -- Null check is needed for nullable non-primitive, non-collection, non-enum types
    -- (e.g. User?, DateTime?) because calling .fromMap(null) or DateTime.parse(null) would crash.
    -- For collections, null handling is done inline. For enums, firstWhereOrNull handles it.
    local add_null_check = p:is_nullable()
      and not p:is_primitive()
      and not p:is_collection()
      and not p.is_enum

    if add_null_check then
      method = method .. base_value .. " != null ? "
    end

    if p.is_enum then
      local enum_value = use_as_cast and ("(" .. apply_cast(base_value, p) .. ")") or value
      if p:is_nullable() then
        method = method .. p:type() .. ".values.firstWhereOrNull((element) => element.name.toLowerCase() == "
          .. enum_value .. "?.toLowerCase())"
      else
        method = method .. p:type() .. ".values.firstWhere((element) => element.name.toLowerCase() == "
          .. enum_value .. ".toLowerCase())"
      end
    elseif p:is_collection() then
      local default_collection = p:is_list() and "[]" or "{}"
      -- When using as-cast, wrap value in parentheses for proper precedence
      local coll_value = use_as_cast and ("(" .. value .. ")") or value

      if p:is_nullable() then
        if use_as_cast then
          method = method .. p:type() .. ".from("
          if p:is_primitive() then
            method = method .. value .. " ?? const " .. default_collection .. ")"
          else
            method = method .. coll_value .. "?.map((x) => " .. custom_type_from_map(p, "x") .. ") ?? const " .. default_collection .. ")"
          end
        else
          method = method .. value .. " != null ? "
          method = method .. p:type() .. ".from("
          if p:is_primitive() then
            method = method .. value .. " ?? const " .. default_collection .. ")"
          else
            method = method .. value .. "?.map((x) => " .. custom_type_from_map(p, "x") .. ") ?? const " .. default_collection .. ")"
          end
          method = method .. " : null"
        end
      else
        method = method .. p:type() .. ".from("
        if p:is_primitive() then
          method = method .. (with_defaults and (value .. " ?? const " .. default_collection) or value) .. ")"
        else
          if with_defaults then
            method = method .. coll_value .. ".map((x) => " .. custom_type_from_map(p, "x") .. ") ?? const " .. default_collection .. ")"
          else
            method = method .. coll_value .. ".map((x) => " .. custom_type_from_map(p, "x") .. "))"
          end
        end
      end
    elseif p:is_primitive() then
      local default_val = (not p:is_nullable() and with_defaults) and (" ?? " .. p:def_value()) or ""
      local type_conversion = ""
      if not use_as_cast then
        if p:is_double() then
          type_conversion = "?.toDouble()"
        elseif p:is_int() then
          type_conversion = "?.toInt()"
        end
      end
      method = method .. value .. type_conversion .. default_val
    else
      method = method .. custom_type_from_map(p)
    end

    if add_null_check then
      method = method .. " : null"
    end

    method = method .. ",\n"

    if idx == #props then
      method = method .. "    );\n"
    end
  end

  method = method .. "  }"
  return method, imports
end

--------------------------------------------------------------------------------
-- toJson / fromJson
--------------------------------------------------------------------------------

---@param clazz DartClass
---@return string, string[] extra_imports
function M.generate_to_json(clazz)
  local method = "  String toJson() => json.encode(toMap());"
  return method, { "dart:convert" }
end

---@param clazz DartClass
---@return string, string[] extra_imports
function M.generate_from_json(clazz)
  local method = "  factory " .. clazz.name .. ".fromJson(String source) => "
    .. clazz.name .. ".fromMap(Map<String, dynamic>.from(json.decode(source)));"
  return method, { "dart:convert" }
end

--------------------------------------------------------------------------------
-- toString
--------------------------------------------------------------------------------

---@param clazz DartClass
---@return string
function M.generate_to_string(clazz)
  local short = clazz:few_props()
  local props = clazz:gen_properties()
  local method = "  @override\n"

  if short then
    method = method .. "  String toString() =>\n      '"
  else
    method = method .. "  String toString() {\n"
    method = method .. "    return '"
  end

  method = method .. clazz.name .. "("
  for i, p in ipairs(props) do
    if i > 1 then method = method .. " " end
    method = method .. p.name .. ": $" .. p.name
    if i < #props then method = method .. "," end
  end
  method = method .. ")';"

  if not short then
    method = method .. "\n  }"
  end

  return method
end

--------------------------------------------------------------------------------
-- Equality (== and hashCode)
--------------------------------------------------------------------------------

---@param clazz DartClass
---@return string, string[] extra_imports
function M.generate_equality(clazz)
  local props = clazz:gen_properties()
  local flutter = is_flutter_project()
  local imports = {}

  local has_collection = false
  for _, p in ipairs(props) do
    if p:is_collection() then
      has_collection = true
      break
    end
  end

  if has_collection then
    if flutter then
      imports[#imports + 1] = "package:flutter/foundation.dart"
    else
      imports[#imports + 1] = "package:collection/collection.dart"
    end
  end

  local method = "  @override\n"
  method = method .. "  bool operator ==(Object other) {\n"
  method = method .. "    if (identical(this, other)) return true;\n"

  if has_collection and not flutter then
    local has_list = false
    local has_map = false
    local has_set = false
    for _, p in ipairs(props) do
      if p:is_collection() then
        if p:is_list() then has_list = true end
        if p:is_map() then has_map = true end
        if p:is_set() then has_set = true end
      end
    end
    if has_list then method = method .. "    final listEquals = const ListEquality().equals;\n" end
    if has_map then method = method .. "    final mapEquals = const MapEquality().equals;\n" end
    if has_set then method = method .. "    final setEquals = const SetEquality().equals;\n" end
  end

  method = method .. "\n"
  method = method .. "    return other is " .. clazz:type_name() .. " &&\n"

  for i, prop in ipairs(props) do
    if prop:is_collection() then
      local fn
      if prop:is_set() then fn = "setEquals"
      elseif prop:is_map() then fn = "mapEquals"
      else fn = "listEquals"
      end
      method = method .. "        " .. fn .. "(other." .. prop.name .. ", " .. prop.name .. ")"
    else
      method = method .. "        other." .. prop.name .. " == " .. prop.name
    end

    if i < #props then
      method = method .. " &&\n"
    else
      method = method .. ";\n"
    end
  end

  method = method .. "  }"
  return method, imports
end

---@param clazz DartClass
---@return string, string[] extra_imports
function M.generate_hash_code(clazz)
  local use_jenkins = M.config.use_jenkins_hash
  local short = not use_jenkins and clazz:few_props()
  local props = clazz:gen_properties()
  local imports = {}

  local method = "  @override\n"

  if short then
    method = method .. "  int get hashCode =>"
  else
    method = method .. "  int get hashCode {\n"
    method = method .. "    return "
  end

  if use_jenkins then
    imports[#imports + 1] = "dart:ui"
    method = method .. "hashList([\n"
    for _, p in ipairs(props) do
      method = method .. "      " .. p.name .. ",\n"
    end
    method = method .. "    ]);"
  else
    for i, p in ipairs(props) do
      local is_first = i == 1
      if short then
        method = method .. (is_first and "\n      " or " ") .. p.name .. ".hashCode"
      else
        method = method .. (is_first and "" or "        ") .. p.name .. ".hashCode"
      end

      if i < #props then
        if short then
          method = method .. " ^"
        else
          method = method .. " ^\n"
        end
      else
        method = method .. ";"
      end
    end
  end

  if not short then
    method = method .. "\n  }"
  end

  return method, imports
end

--------------------------------------------------------------------------------
-- Full data class generation
--------------------------------------------------------------------------------

---@class GenerationResult
---@field text string new class text
---@field imports string[] list of imports needed
---@field starts_at_line number
---@field ends_at_line number

--- Generate all (or one specific part of) boilerplate methods for a class.
--- NOTE: In the incremental architecture, actions.lua uses the individual
--- generator functions directly (generate_constructor, generate_copy_with, etc.)
--- and build_edit() from incremental.lua. This function is retained for tests
--- and Dart validation scripts.
---@param clazz DartClass
---@param part? string specific part to generate, or nil for all
---@return GenerationResult|nil
function M.generate(clazz, part)
  if not clazz:is_valid() then return nil end

  -- Skip enum declarations — we only generate for classes
  if clazz.is_enum_decl then return nil end

  local all_imports = {}
  local methods = {}

  ---@param imp string
  local function add_import(imp)
    for _, existing in ipairs(all_imports) do
      if existing == imp then return end
    end
    all_imports[#all_imports + 1] = imp
  end

  local function should_gen(name)
    return part == nil or part == name
  end

  -- Constructor
  if should_gen("constructor") then
    local constr_text = M.generate_constructor(clazz)
    -- We'll handle constructor insertion separately
    methods.constructor = constr_text
  end

  local skip_non_widget = clazz:is_widget()

  if not skip_non_widget then
    local skip_abstract = clazz:is_abstract() or clazz:is_sealed()
    -- Allow sealed subclasses
    if clazz:has_superclass() and not clazz:is_abstract() and not clazz:is_sealed() then
      skip_abstract = false
    end

    if not skip_abstract then
      if should_gen("copyWith") then
        local text, imps = M.generate_copy_with(clazz)
        methods.copyWith = text
        for _, imp in ipairs(imps) do add_import(imp) end
      end

      if should_gen("toMap") then
        methods.toMap = M.generate_to_map(clazz)
      end

      if should_gen("fromMap") then
        local text, imps = M.generate_from_map(clazz)
        methods.fromMap = text
        for _, imp in ipairs(imps) do add_import(imp) end
      end

      if should_gen("toJson") then
        local text, imps = M.generate_to_json(clazz)
        methods.toJson = text
        for _, imp in ipairs(imps) do add_import(imp) end
      end

      if should_gen("fromJson") then
        local text, imps = M.generate_from_json(clazz)
        methods.fromJson = text
        for _, imp in ipairs(imps) do add_import(imp) end
      end
    end

    if should_gen("toString") then
      methods.toString = M.generate_to_string(clazz)
    end

    if should_gen("equality") then
      local eq_text, eq_imps = M.generate_equality(clazz)
      methods.equality = eq_text
      for _, imp in ipairs(eq_imps) do add_import(imp) end

      local hash_text, hash_imps = M.generate_hash_code(clazz)
      methods.hashCode = hash_text
      for _, imp in ipairs(hash_imps) do add_import(imp) end
    end
  end

  return {
    methods = methods,
    imports = all_imports,
    starts_at_line = clazz.starts_at_line,
    ends_at_line = clazz.ends_at_line,
  }
end

--- Build the complete class text with generated methods.
--- NOTE: In the incremental architecture, incremental.lua's build_edit() and
--- apply_edits() replace this function for runtime use. This function is
--- retained for tests and Dart validation scripts.
---@param buf_lines string[] buffer lines (1-indexed array)
---@param clazz DartClass
---@param result table from M.generate()
---@return string[] new_lines to replace, string[] imports_needed
function M.build_class_text(buf_lines, clazz, result)
  if not result or not result.methods then return {}, {} end

  local methods = result.methods

  -- Get original class lines
  local class_lines = {}
  for i = clazz.starts_at_line, clazz.ends_at_line do
    class_lines[#class_lines + 1] = buf_lines[i] or ""
  end

  -- Build the new class body
  local new_lines = {}

  -- Class declaration line
  new_lines[#new_lines + 1] = class_lines[1]

  -- Properties (from starts_at_line+1 to props_end or constructor start)
  local props_end = 1
  for i = 2, #class_lines do
    local absolute_line = clazz.starts_at_line + i - 1

    -- Skip if inside existing constructor range
    if clazz:has_constructor()
      and absolute_line >= clazz.constr_starts_at_line
      and absolute_line <= clazz.constr_ends_at_line then
      -- skip existing constructor lines
      goto continue
    end

    -- Check if this line is the closing brace
    if i == #class_lines then
      break
    end

    -- Check if this is a property line or blank line before methods
    local line = class_lines[i]
    local trimmed = utils.trim(line)

    -- Keep property lines and blank lines before constructor/methods
    local is_prop_line = false
    for _, p in ipairs(clazz.properties) do
      if p.line == absolute_line then
        is_prop_line = true
        break
      end
    end

    -- Also keep comment/annotation lines above properties
    local is_annotation_or_comment = trimmed:sub(1, 2) == "//" or trimmed:sub(1, 1) == "@"

    if is_prop_line or is_annotation_or_comment then
      new_lines[#new_lines + 1] = line
      props_end = #new_lines
    elseif trimmed == "" and #new_lines <= props_end + 1 then
      -- Keep blank lines between properties, but NOT trailing blank lines
      -- after the last property (those will be added by the method insertion logic)
      local next_is_prop_or_annotation = false
      if i + 1 <= #class_lines then
        local next_absolute = clazz.starts_at_line + i
        for _, p in ipairs(clazz.properties) do
          if p.line == next_absolute then
            next_is_prop_or_annotation = true
            break
          end
        end
        local next_trimmed = utils.trim(class_lines[i + 1] or "")
        if next_trimmed:sub(1, 2) == "//" or next_trimmed:sub(1, 1) == "@" then
          next_is_prop_or_annotation = true
        end
      end
      if next_is_prop_or_annotation then
        new_lines[#new_lines + 1] = line
      end
      -- Otherwise skip trailing blank line — methods will add their own separator
    end

    ::continue::
  end

  -- Add generated methods
  local method_order = { "constructor", "copyWith", "toMap", "fromMap", "toJson", "fromJson", "toString", "equality", "hashCode" }

  for _, method_name in ipairs(method_order) do
    local method_text = methods[method_name]
    if method_text then
      new_lines[#new_lines + 1] = ""
      -- All generators now produce properly indented output (2-space prefix)
      -- Use a pattern that preserves empty lines (blank lines within methods)
      for mline in (method_text .. "\n"):gmatch("([^\n]*)\n") do
        new_lines[#new_lines + 1] = mline
      end
    end
  end

  -- Closing brace
  new_lines[#new_lines + 1] = "}"

  return new_lines, result.imports
end

return M
