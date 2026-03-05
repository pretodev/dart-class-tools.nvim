#!/usr/bin/env luajit
--[[
  Test runner for dart-class-tools.nvim
  Runs parser + generator against fixtures without Neovim.
  Usage: luajit test/run_tests.lua
]]

-- Stub vim global for modules that reference it at load time
vim = {
  deepcopy = function(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
      copy[k] = vim.deepcopy(v)
    end
    return setmetatable(copy, getmetatable(t))
  end,
  fn = { getcwd = function() return "." end },
  log = { levels = { INFO = 1, WARN = 2, ERROR = 3 } },
}

-- Add the lua/ directory to the module search path
local script_dir = arg[0]:match("(.*/)")
if not script_dir then script_dir = "./" end
local root = script_dir .. "../"
package.path = root .. "lua/?.lua;" .. root .. "lua/?/init.lua;" .. package.path

-- Load modules
local utils = require("dart-class-tools.utils")
local parser = require("dart-class-tools.parser")
local generator = require("dart-class-tools.generator")
local incremental = require("dart-class-tools.incremental")

--------------------------------------------------------------------------------
-- Test infrastructure
--------------------------------------------------------------------------------
local passed = 0
local failed = 0
local errors = {}

local function ok(condition, msg)
  if condition then
    passed = passed + 1
    io.write("  PASS: " .. msg .. "\n")
  else
    failed = failed + 1
    errors[#errors + 1] = msg
    io.write("  FAIL: " .. msg .. "\n")
  end
end

local function eq(a, b, msg)
  if a == b then
    passed = passed + 1
    io.write("  PASS: " .. msg .. "\n")
  else
    failed = failed + 1
    local detail = msg .. "\n    expected: " .. tostring(b) .. "\n    got:      " .. tostring(a)
    errors[#errors + 1] = detail
    io.write("  FAIL: " .. detail .. "\n")
  end
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then error("Cannot open file: " .. path) end
  local content = f:read("*a")
  f:close()
  return content
end

local fixtures_dir = root .. "test/fixtures/"

--------------------------------------------------------------------------------
-- Utils tests
--------------------------------------------------------------------------------
io.write("\n=== Utils Tests ===\n")

eq(utils.capitalize("hello"), "Hello", "capitalize basic")
eq(utils.capitalize(""), "", "capitalize empty")
eq(utils.var_to_key("createdAt"), "created_at", "var_to_key camelCase")
eq(utils.var_to_key("name"), "name", "var_to_key simple")
eq(utils.var_to_key("isActive"), "is_active", "var_to_key boolean-style")
eq(utils.remove_end("hello?", "?"), "hello", "remove_end match")
eq(utils.remove_end("hello", "?"), "hello", "remove_end no match")
eq(utils.remove_start("finalFoo", "final"), "Foo", "remove_start match")
eq(utils.trim("  hello  "), "hello", "trim")
eq(utils.is_blank("  "), true, "is_blank whitespace")
eq(utils.is_blank("x"), false, "is_blank non-blank")
eq(utils.count_char("{{}", "{"), 2, "count_char")
ok(utils.includes_one("final String name;", { "final" }), "includes_one word match")
ok(not utils.includes_one("final String name;", { "static" }), "includes_one word no match")
ok(utils.includes_all("class Foo extends Bar", { "class", "extends" }), "includes_all")
eq(utils.to_var_name("my-var"), "myVar", "to_var_name hyphen")
eq(utils.to_var_name("class"), "class_", "to_var_name keyword")
eq(utils.to_var_name("123abc"), "n123abc", "to_var_name leading digit")

--------------------------------------------------------------------------------
-- Parser tests
--------------------------------------------------------------------------------
io.write("\n=== Parser Tests ===\n")

local input_text = read_file(fixtures_dir .. "input_class.dart")
local clazzes, enum_types = parser.parse_classes(input_text)

-- Verify enum_types detected
ok(enum_types["Status"] == true, "detect_enum_types: Status found")
ok(enum_types["Priority"] == true, "detect_enum_types: Priority found")

-- Count classes (excluding State classes)
-- We expect: User, Product, Order, Task (4 classes) + Priority enhanced enum = 5
local class_names = {}
for _, c in ipairs(clazzes) do
  class_names[#class_names + 1] = c.name
end
io.write("  Parsed classes/enums: " .. table.concat(class_names, ", ") .. "\n")

-- Find specific classes
local user_class, product_class, order_class, task_class, priority_enum
for _, c in ipairs(clazzes) do
  if c.name == "User" then user_class = c
  elseif c.name == "Product" then product_class = c
  elseif c.name == "Order" then order_class = c
  elseif c.name == "Task" then task_class = c
  elseif c.name == "Priority" then priority_enum = c
  end
end

-- User class parsing
ok(user_class ~= nil, "User class parsed")
if user_class then
  eq(#user_class.properties, 4, "User has 4 properties")
  ok(user_class:is_valid(), "User is_valid")
  ok(user_class:all_properties_final(), "User all_properties_final")
  ok(not user_class:is_widget(), "User is not widget")
  ok(not user_class:is_abstract(), "User is not abstract")
  ok(not user_class:has_constructor(), "User has no constructor")
  eq(user_class.starts_at_line, 1, "User starts at line 1")
  eq(user_class.ends_at_line, 6, "User ends at line 6")

  -- Check individual properties
  local p1 = user_class.properties[1]
  eq(p1.name, "name", "User prop1 name")
  eq(p1.raw_type, "String", "User prop1 type")
  ok(p1.is_final, "User prop1 is final")
  ok(not p1:is_nullable(), "User prop1 not nullable")

  local p3 = user_class.properties[3]
  eq(p3.name, "email", "User prop3 name")
  eq(p3.raw_type, "String?", "User prop3 type")
  ok(p3:is_nullable(), "User prop3 is nullable")

  local p4 = user_class.properties[4]
  eq(p4.name, "isActive", "User prop4 name")
  eq(p4.raw_type, "bool", "User prop4 type")
end

-- Product class parsing
ok(product_class ~= nil, "Product class parsed")
if product_class then
  eq(#product_class.properties, 4, "Product has 4 properties")
  local tags = product_class.properties[3]
  eq(tags.name, "tags", "Product.tags name")
  eq(tags.raw_type, "List<String>", "Product.tags type")
  ok(tags:is_list(), "Product.tags is_list")
  ok(tags:is_collection(), "Product.tags is_collection")

  local metadata = product_class.properties[4]
  eq(metadata.raw_type, "Map<String, dynamic>", "Product.metadata type")
  -- Note: the parser splits on whitespace, so "Map<String," and "dynamic>" may be separate
  -- Let's check what we actually got:
  io.write("  Product.metadata raw_type = '" .. metadata.raw_type .. "'\n")
  ok(metadata:is_map() or metadata.raw_type:sub(1, 3) == "Map", "Product.metadata is_map or starts with Map")
end

-- Order class parsing
ok(order_class ~= nil, "Order class parsed")
if order_class then
  eq(#order_class.properties, 5, "Order has 5 properties")

  local status_prop = order_class.properties[2]
  eq(status_prop.name, "status", "Order.status name")
  eq(status_prop.raw_type, "Status", "Order.status type")
  ok(status_prop.is_enum, "Order.status is_enum (auto-detected)")

  local prev_status = order_class.properties[3]
  eq(prev_status.name, "previousStatus", "Order.previousStatus name")
  eq(prev_status.raw_type, "Status?", "Order.previousStatus type")
  ok(prev_status:is_nullable(), "Order.previousStatus is nullable")
  ok(prev_status.is_enum, "Order.previousStatus is_enum (auto-detected)")

  local created_at = order_class.properties[4]
  eq(created_at.name, "createdAt", "Order.createdAt name")
  eq(created_at.raw_type, "DateTime", "Order.createdAt type")

  local items = order_class.properties[5]
  eq(items.name, "items", "Order.items name")
  eq(items.raw_type, "List<Product>", "Order.items type")
  ok(items:is_list(), "Order.items is_list")
end

-- Task class parsing
ok(task_class ~= nil, "Task class parsed")
if task_class then
  eq(#task_class.properties, 2, "Task has 2 properties")
  local prio = task_class.properties[2]
  eq(prio.name, "priority", "Task.priority name")
  eq(prio.raw_type, "Priority", "Task.priority type")
  ok(prio.is_enum, "Task.priority is_enum (auto-detected)")
end

-- Priority enhanced enum parsing
ok(priority_enum ~= nil, "Priority enum parsed")
if priority_enum then
  ok(priority_enum.is_enum_decl, "Priority is_enum_decl")
  eq(#priority_enum.properties, 1, "Priority has 1 property")
  if #priority_enum.properties > 0 then
    eq(priority_enum.properties[1].name, "label", "Priority.label name")
    eq(priority_enum.properties[1].raw_type, "String", "Priority.label type")
  end
end

-- find_class_at_line
ok(parser.find_class_at_line(clazzes, 1) == user_class, "find_class_at_line: User at line 1")
ok(parser.find_class_at_line(clazzes, 3) == user_class, "find_class_at_line: User at line 3")
ok(parser.find_class_at_line(clazzes, 9) == product_class, "find_class_at_line: Product at line 9")
ok(parser.find_class_at_line(clazzes, 100) == nil, "find_class_at_line: nil for out-of-range")

-- is_valid_action_position
ok(parser.is_valid_action_position(user_class, 1), "is_valid_action_position: class decl line")
ok(parser.is_valid_action_position(user_class, 2), "is_valid_action_position: property line")
ok(not parser.is_valid_action_position(user_class, 6), "is_valid_action_position: closing brace")

--------------------------------------------------------------------------------
-- Generator tests
--------------------------------------------------------------------------------
io.write("\n=== Generator Tests ===\n")

-- Configure generator with defaults matching the expected output
generator.config = {
  use_equatable = false,
  use_as_cast = true,
  use_default_values = false,
  use_jenkins_hash = false,
  use_value_getter = false,
  constructor_default_values = false,
  json_key_format = "variable",
}

-- Test constructor generation for User
if user_class then
  local constr = generator.generate_constructor(user_class)
  io.write("  --- User constructor ---\n")
  io.write(constr .. "\n")
  io.write("  ----------------------\n")

  ok(constr:find("const ") ~= nil, "User constructor starts with const")
  ok(constr:find("User({", 1, true) ~= nil, "User constructor has User({")
  ok(constr:find("required this.name", 1, true) ~= nil, "User constructor has required this.name")
  ok(constr:find("required this.age", 1, true) ~= nil, "User constructor has required this.age")
  ok(constr:find("this.email,", 1, true) ~= nil, "User constructor has this.email (no required)")
  ok(constr:find("required this.isActive", 1, true) ~= nil, "User constructor has required this.isActive")
  ok(constr:find("});", 1, true) ~= nil, "User constructor ends with });")
end

-- Test copyWith generation for User
if user_class then
  local copy, imps = generator.generate_copy_with(user_class)
  io.write("  --- User copyWith ---\n")
  io.write(copy .. "\n")
  io.write("  --------------------\n")

  ok(copy:find("User copyWith({", 1, true) ~= nil, "User copyWith has correct signature")
  ok(copy:find("String? name", 1, true) ~= nil, "User copyWith has String? name param")
  ok(copy:find("int? age", 1, true) ~= nil, "User copyWith has int? age param")
  ok(copy:find("String? email", 1, true) ~= nil, "User copyWith has String? email param")
  ok(copy:find("name: name ?? this.name", 1, true) ~= nil, "User copyWith has correct name body")
  eq(#imps, 0, "User copyWith has no extra imports")
end

-- Test toMap generation for User
if user_class then
  local to_map = generator.generate_to_map(user_class)
  io.write("  --- User toMap ---\n")
  io.write(to_map .. "\n")
  io.write("  ------------------\n")

  ok(to_map:find("Map<String, dynamic> toMap()", 1, true) ~= nil, "User toMap has correct signature")
  ok(to_map:find("'name': name", 1, true) ~= nil, "User toMap has 'name': name")
  ok(to_map:find("'age': age", 1, true) ~= nil, "User toMap has 'age': age")
  ok(to_map:find("'isActive': isActive", 1, true) ~= nil, "User toMap has 'isActive': isActive")
end

-- Test fromMap generation for User
if user_class then
  local from_map, imps = generator.generate_from_map(user_class)
  io.write("  --- User fromMap ---\n")
  io.write(from_map .. "\n")
  io.write("  --------------------\n")

  ok(from_map:find("factory User.fromMap(Map<String, dynamic> map)", 1, true) ~= nil, "User fromMap has correct signature")
  ok(from_map:find("name: map['name'] as String", 1, true) ~= nil, "User fromMap has name cast")
  ok(from_map:find("age: map['age'] as int", 1, true) ~= nil, "User fromMap has age cast")
  ok(from_map:find("email: map['email'] as String?", 1, true) ~= nil, "User fromMap has email nullable cast")
  ok(from_map:find("isActive: map['isActive'] as bool", 1, true) ~= nil, "User fromMap has isActive cast")
  eq(#imps, 0, "User fromMap has no extra imports (no nullable enums)")
end

-- Test toJson generation
if user_class then
  local to_json, imps = generator.generate_to_json(user_class)
  eq(to_json, "  String toJson() => json.encode(toMap());", "User toJson matches")
  ok(#imps > 0, "User toJson requires dart:convert")
  eq(imps[1], "dart:convert", "User toJson import is dart:convert")
end

-- Test fromJson generation
if user_class then
  local from_json, imps = generator.generate_from_json(user_class)
  ok(from_json:find("factory User.fromJson(String source)", 1, true) ~= nil, "User fromJson has correct signature")
  ok(from_json:find("User.fromMap(Map<String, dynamic>.from(json.decode(source)))", 1, true) ~= nil, "User fromJson body correct")
end

-- Test toString generation for User
if user_class then
  local ts = generator.generate_to_string(user_class)
  io.write("  --- User toString ---\n")
  io.write(ts .. "\n")
  io.write("  ---------------------\n")

  ok(ts:find("@override", 1, true) ~= nil, "User toString has @override")
  -- User has 4 props, so few_props() is true (<= 4)
  ok(user_class:few_props() == true, "User few_props is true (4 props)")
  ok(ts:find("=>\n", 1, true) ~= nil, "User toString uses arrow form")
  ok(ts:find("name: $name", 1, true) ~= nil, "User toString has name interpolation")
end

-- Test equality generation for User
if user_class then
  local eq_text, eq_imps = generator.generate_equality(user_class)
  io.write("  --- User equality ---\n")
  io.write(eq_text .. "\n")
  io.write("  ---------------------\n")

  ok(eq_text:find("@override", 1, true) ~= nil, "User equality has @override")
  ok(eq_text:find("bool operator ==(Object other)", 1, true) ~= nil, "User equality has correct signature")
  ok(eq_text:find("identical(this, other)", 1, true) ~= nil, "User equality has identical check")
  ok(eq_text:find("other is User", 1, true) ~= nil, "User equality has type check")
  ok(eq_text:find("other.name == name", 1, true) ~= nil, "User equality compares name")
  eq(#eq_imps, 0, "User equality has no imports (no collections)")
end

-- Test hashCode generation for User
if user_class then
  local hc, hc_imps = generator.generate_hash_code(user_class)
  io.write("  --- User hashCode ---\n")
  io.write(hc .. "\n")
  io.write("  ---------------------\n")

  ok(hc:find("@override", 1, true) ~= nil, "User hashCode has @override")
  ok(hc:find("int get hashCode", 1, true) ~= nil, "User hashCode has correct signature")
  ok(hc:find("name.hashCode", 1, true) ~= nil, "User hashCode has name.hashCode")
  -- User has 4 props, few, so it should be short form (arrow)
  ok(user_class:few_props(), "User few_props (4 <= 4)")
  ok(hc:find("=>", 1, true) ~= nil, "User hashCode uses arrow (short form)")
end

--------------------------------------------------------------------------------
-- Full generation + build_class_text test for User
--------------------------------------------------------------------------------
io.write("\n=== Full Generation Test (User) ===\n")

if user_class then
  local result = generator.generate(user_class, nil)
  ok(result ~= nil, "User full generate returns result")

  if result then
    ok(result.methods ~= nil, "User result has methods")
    ok(result.methods.constructor ~= nil, "User result has constructor")
    ok(result.methods.copyWith ~= nil, "User result has copyWith")
    ok(result.methods.toMap ~= nil, "User result has toMap")
    ok(result.methods.fromMap ~= nil, "User result has fromMap")
    ok(result.methods.toJson ~= nil, "User result has toJson")
    ok(result.methods.fromJson ~= nil, "User result has fromJson")
    ok(result.methods.toString ~= nil, "User result has toString")
    ok(result.methods.equality ~= nil, "User result has equality")
    ok(result.methods.hashCode ~= nil, "User result has hashCode")

    -- Check imports
    local has_dart_convert = false
    for _, imp in ipairs(result.imports) do
      if imp == "dart:convert" then has_dart_convert = true end
    end
    ok(has_dart_convert, "User result imports dart:convert")

    -- Build class text
    local input_lines = {}
    for line in (input_text .. "\n"):gmatch("([^\n]*)\n") do
      input_lines[#input_lines + 1] = line
    end

    local new_lines, needed_imports = generator.build_class_text(input_lines, user_class, result)
    ok(#new_lines > 0, "build_class_text returns lines")

    local generated_text = table.concat(new_lines, "\n")
    io.write("\n  --- Generated User class ---\n")
    for i, line in ipairs(new_lines) do
      io.write(string.format("  %3d: %s\n", i, line))
    end
    io.write("  ----------------------------\n")

    -- Compare key elements
    ok(generated_text:find("class User {", 1, true) ~= nil, "Generated has class User {")
    ok(generated_text:find("final String name;", 1, true) ~= nil, "Generated has properties")
    ok(generated_text:find("const User({", 1, true) ~= nil, "Generated has constructor")
    ok(generated_text:find("copyWith({", 1, true) ~= nil, "Generated has copyWith")
    ok(generated_text:find("toMap()", 1, true) ~= nil, "Generated has toMap")
    ok(generated_text:find(".fromMap(", 1, true) ~= nil, "Generated has fromMap")
    ok(generated_text:find("toJson()", 1, true) ~= nil, "Generated has toJson")
    ok(generated_text:find(".fromJson(", 1, true) ~= nil, "Generated has fromJson")
    ok(generated_text:find("toString()", 1, true) ~= nil, "Generated has toString")
    ok(generated_text:find("operator ==(", 1, true) ~= nil, "Generated has operator ==")
    ok(generated_text:find("hashCode", 1, true) ~= nil, "Generated has hashCode")
    ok(new_lines[#new_lines] == "}", "Generated ends with }")
  end
end

--------------------------------------------------------------------------------
-- Order class generation (enums, DateTime, nested custom type)
--------------------------------------------------------------------------------
io.write("\n=== Order Class Generation ===\n")

if order_class then
  local result = generator.generate(order_class, nil)
  ok(result ~= nil, "Order full generate returns result")

  if result then
    -- toMap should use .name for enum
    local to_map = result.methods.toMap
    ok(to_map ~= nil, "Order has toMap")
    if to_map then
      io.write("  --- Order toMap ---\n")
      io.write(to_map .. "\n")
      io.write("  ------------------\n")
      ok(to_map:find("status.name", 1, true) ~= nil, "Order toMap: status uses .name")
      ok(to_map:find("previousStatus?.name", 1, true) ~= nil, "Order toMap: previousStatus uses ?.name")
      ok(to_map:find("createdAt.toUtc().toIso8601String()", 1, true) ~= nil, "Order toMap: DateTime uses toIso8601String")
      ok(to_map:find("items.map", 1, true) ~= nil or to_map:find("items?.map", 1, true) ~= nil, "Order toMap: items uses .map for nested Product")
    end

    -- fromMap should use firstWhere / firstWhereOrNull for enums
    local from_map = result.methods.fromMap
    ok(from_map ~= nil, "Order has fromMap")
    if from_map then
      io.write("  --- Order fromMap ---\n")
      io.write(from_map .. "\n")
      io.write("  --------------------\n")
      ok(from_map:find("Status.values.firstWhere", 1, true) ~= nil, "Order fromMap: Status uses firstWhere")
      ok(from_map:find("firstWhereOrNull", 1, true) ~= nil, "Order fromMap: nullable enum uses firstWhereOrNull")
      ok(from_map:find("DateTime.parse", 1, true) ~= nil, "Order fromMap: DateTime uses DateTime.parse")
      ok(from_map:find("Product.fromMap", 1, true) ~= nil, "Order fromMap: nested Product uses fromMap")
    end

    -- Check imports for nullable enum
    local has_collection = false
    for _, imp in ipairs(result.imports) do
      if imp == "package:collection/collection.dart" then has_collection = true end
    end
    ok(has_collection, "Order imports package:collection/collection.dart (for nullable enum)")
  end
end

--------------------------------------------------------------------------------
-- Product class generation (collections)
--------------------------------------------------------------------------------
io.write("\n=== Product Class Generation ===\n")

if product_class then
  io.write("  Product properties:\n")
  for _, p in ipairs(product_class.properties) do
    io.write(string.format("    %s %s (list=%s map=%s coll=%s prim=%s)\n",
      p.raw_type, p.name,
      tostring(p:is_list()), tostring(p:is_map()),
      tostring(p:is_collection()), tostring(p:is_primitive())))
  end

  local result = generator.generate(product_class, nil)
  ok(result ~= nil, "Product full generate returns result")

  if result then
    local to_map = result.methods.toMap
    if to_map then
      io.write("  --- Product toMap ---\n")
      io.write(to_map .. "\n")
      io.write("  --------------------\n")
      ok(to_map:find("'tags': tags", 1, true) ~= nil, "Product toMap: tags is primitive list (direct)")
      ok(to_map:find("'metadata': metadata", 1, true) ~= nil, "Product toMap: metadata is map (direct)")
    end

    -- equality should use listEquals / mapEquals
    local eq_text = result.methods.equality
    if eq_text then
      io.write("  --- Product equality ---\n")
      io.write(eq_text .. "\n")
      io.write("  -----------------------\n")
      ok(eq_text:find("listEquals", 1, true) ~= nil or eq_text:find("ListEquality", 1, true) ~= nil,
        "Product equality uses listEquals or ListEquality for tags")
      ok(eq_text:find("mapEquals", 1, true) ~= nil or eq_text:find("MapEquality", 1, true) ~= nil,
        "Product equality uses mapEquals or MapEquality for metadata")
    end
  end
end

--------------------------------------------------------------------------------
-- DartField unit tests
--------------------------------------------------------------------------------
io.write("\n=== DartField Tests ===\n")

local f1 = parser.DartField.new("String", "name", 1, true)
eq(f1:type(), "String", "DartField type() for non-nullable")
eq(f1:is_nullable(), false, "DartField not nullable")
eq(f1:is_primitive(), true, "String is primitive")

local f2 = parser.DartField.new("String?", "email", 2, true)
eq(f2:type(), "String", "DartField type() strips ?")
eq(f2:is_nullable(), true, "DartField is nullable")

local f3 = parser.DartField.new("List<String>", "tags", 3, true)
ok(f3:is_list(), "List<String> is_list")
ok(f3:is_collection(), "List<String> is_collection")
ok(not f3:is_map(), "List<String> not is_map")
eq(f3:collection_type():type(), "String", "List<String> collection inner type is String")
ok(f3:is_primitive(), "List<String> is_primitive (inner String is primitive)")

local f4 = parser.DartField.new("Map<String, dynamic>", "data", 4, true)
ok(f4:is_map(), "Map<String, dynamic> is_map")
ok(f4:is_collection(), "Map<String, dynamic> is_collection")

local f5 = parser.DartField.new("DateTime", "created", 5, true)
ok(not f5:is_primitive(), "DateTime is not primitive")
ok(not f5:is_collection(), "DateTime is not collection")
ok(not f5.is_enum, "DateTime is not enum")

local f6 = parser.DartField.new("List<Product>", "items", 6, true)
ok(f6:is_list(), "List<Product> is_list")
eq(f6:collection_type():type(), "Product", "List<Product> inner type is Product")
ok(not f6:collection_type():is_primitive(), "Product inner type is not primitive")

local f7 = parser.DartField.new("Set<String>", "uniqueTags", 7, true)
ok(f7:is_set(), "Set<String> is_set")
ok(f7:is_collection(), "Set<String> is_collection")

--------------------------------------------------------------------------------
-- Edge case tests
--------------------------------------------------------------------------------
io.write("\n=== Edge Case Tests ===\n")

local edge_text = read_file(fixtures_dir .. "edge_cases.dart")
local edge_clazzes = parser.parse_classes(edge_text)

-- Find classes by name
local edge_map = {}
for _, c in ipairs(edge_clazzes) do
  edge_map[c.name] = c
end

-- 1. Generic class: Pair<A, B>
local pair_class = edge_map["Pair"]
ok(pair_class ~= nil, "Edge: Pair<A, B> class parsed")
if pair_class then
  eq(#pair_class.properties, 2, "Edge: Pair has 2 properties")
  ok(pair_class:is_valid(), "Edge: Pair is_valid")
  ok(pair_class.full_generic_type ~= "", "Edge: Pair has generics")
  ok(pair_class:type_name():find("Pair<A, B>") ~= nil or pair_class:type_name():find("Pair<A,B>") ~= nil,
    "Edge: Pair type_name includes generics")

  local result = generator.generate(pair_class, nil)
  ok(result ~= nil, "Edge: Pair generates result")
  if result then
    -- copyWith should return Pair<A, B>
    local copy = result.methods.copyWith
    ok(copy:find("Pair<A", 1, true) ~= nil, "Edge: Pair copyWith uses generic return type")
  end
end

-- 2. Abstract class: Animal
local animal_class = edge_map["Animal"]
ok(animal_class ~= nil, "Edge: Animal abstract class parsed")
if animal_class then
  ok(animal_class:is_abstract(), "Edge: Animal is_abstract")
  ok(animal_class:is_valid(), "Edge: Animal is_valid")

  local result = generator.generate(animal_class, nil)
  ok(result ~= nil, "Edge: Animal generates result")
  if result then
    -- Abstract class should have constructor but skip copyWith/serialization
    ok(result.methods.constructor ~= nil, "Edge: Animal has constructor")
    ok(result.methods.copyWith == nil, "Edge: Animal skips copyWith (abstract)")
    ok(result.methods.toMap == nil, "Edge: Animal skips toMap (abstract)")
    ok(result.methods.fromMap == nil, "Edge: Animal skips fromMap (abstract)")
    -- toString and equality should still be generated
    ok(result.methods.toString ~= nil, "Edge: Animal has toString")
    ok(result.methods.equality ~= nil, "Edge: Animal has equality")
  end
end

-- 3. Sealed class: Shape
local shape_class = edge_map["Shape"]
ok(shape_class ~= nil, "Edge: Shape sealed class parsed")
if shape_class then
  ok(shape_class:is_sealed(), "Edge: Shape is_sealed")

  local result = generator.generate(shape_class, nil)
  ok(result ~= nil, "Edge: Shape generates result")
  if result then
    ok(result.methods.constructor ~= nil, "Edge: Shape has constructor")
    ok(result.methods.copyWith == nil, "Edge: Shape skips copyWith (sealed)")
    ok(result.methods.toMap == nil, "Edge: Shape skips toMap (sealed)")
  end
end

-- 4. Non-final fields: MutableConfig
local mutable_class = edge_map["MutableConfig"]
ok(mutable_class ~= nil, "Edge: MutableConfig parsed")
if mutable_class then
  eq(#mutable_class.properties, 2, "Edge: MutableConfig has 2 properties")
  ok(not mutable_class:all_properties_final(), "Edge: MutableConfig not all_properties_final")

  local result = generator.generate(mutable_class, nil)
  ok(result ~= nil, "Edge: MutableConfig generates result")
  if result then
    -- Constructor should NOT be const (non-final fields)
    local constr = result.methods.constructor
    ok(constr:find("const ") == nil, "Edge: MutableConfig constructor not const")
  end
end

-- 5. Mixed final/non-final: MixedFields
local mixed_class = edge_map["MixedFields"]
ok(mixed_class ~= nil, "Edge: MixedFields parsed")
if mixed_class then
  ok(not mixed_class:all_properties_final(), "Edge: MixedFields not all_properties_final")
  local result = generator.generate(mixed_class, nil)
  ok(result ~= nil, "Edge: MixedFields generates result")
  if result then
    local constr = result.methods.constructor
    ok(constr:find("const ") == nil, "Edge: MixedFields constructor not const")
  end
end

-- 6. Class with existing constructor: WithConstructor
local with_constr = edge_map["WithConstructor"]
ok(with_constr ~= nil, "Edge: WithConstructor parsed")
if with_constr then
  ok(with_constr:has_constructor(), "Edge: WithConstructor has_constructor")
  eq(#with_constr.properties, 2, "Edge: WithConstructor has 2 properties")

  local result = generator.generate(with_constr, nil)
  ok(result ~= nil, "Edge: WithConstructor generates result")
  if result then
    -- Constructor should preserve const from existing
    local constr = result.methods.constructor
    ok(constr:find("const ") ~= nil, "Edge: WithConstructor preserves const")
  end
end

-- 7. Subclass: Dog extends Animal
local dog_class = edge_map["Dog"]
ok(dog_class ~= nil, "Edge: Dog subclass parsed")
if dog_class then
  ok(dog_class:has_superclass(), "Edge: Dog has_superclass")
  eq(dog_class.superclass, "Animal", "Edge: Dog superclass is Animal")
  ok(not dog_class:is_abstract(), "Edge: Dog is not abstract")

  local result = generator.generate(dog_class, nil)
  ok(result ~= nil, "Edge: Dog generates result")
  if result then
    ok(result.methods.copyWith ~= nil, "Edge: Dog has copyWith (subclass allowed)")
    ok(result.methods.toMap ~= nil, "Edge: Dog has toMap")
  end
end

-- 8. Single property: Wrapper
local wrapper_class = edge_map["Wrapper"]
ok(wrapper_class ~= nil, "Edge: Wrapper parsed")
if wrapper_class then
  eq(#wrapper_class.properties, 1, "Edge: Wrapper has 1 property")
  ok(wrapper_class:few_props(), "Edge: Wrapper few_props (1 <= 4)")

  local result = generator.generate(wrapper_class, nil)
  ok(result ~= nil, "Edge: Wrapper generates result")
  if result then
    -- hashCode should be arrow form (single prop)
    local hc = result.methods.hashCode
    ok(hc:find("=>", 1, true) ~= nil, "Edge: Wrapper hashCode uses arrow form")
    -- toString should be arrow form
    local ts = result.methods.toString
    ok(ts:find("=>", 1, true) ~= nil, "Edge: Wrapper toString uses arrow form")
  end
end

-- 9. Large class (> 4 props): LargeClass
local large_class = edge_map["LargeClass"]
ok(large_class ~= nil, "Edge: LargeClass parsed")
if large_class then
  eq(#large_class.properties, 5, "Edge: LargeClass has 5 properties")
  ok(not large_class:few_props(), "Edge: LargeClass NOT few_props (5 > 4)")

  local result = generator.generate(large_class, nil)
  ok(result ~= nil, "Edge: LargeClass generates result")
  if result then
    -- hashCode should use long form (return block)
    local hc = result.methods.hashCode
    ok(hc:find("int get hashCode {", 1, true) ~= nil, "Edge: LargeClass hashCode uses block form")
    -- toString should use long form (return block)
    local ts = result.methods.toString
    ok(ts:find("return '", 1, true) ~= nil, "Edge: LargeClass toString uses block form")
  end
end

-- 10. Nullable collections: NullableCollections
local nullable_coll = edge_map["NullableCollections"]
ok(nullable_coll ~= nil, "Edge: NullableCollections parsed")
if nullable_coll then
  eq(#nullable_coll.properties, 3, "Edge: NullableCollections has 3 properties")
  ok(nullable_coll.properties[1]:is_nullable(), "Edge: NullableCollections tags is nullable")
  ok(nullable_coll.properties[1]:is_list(), "Edge: NullableCollections tags is list")
  ok(nullable_coll.properties[2]:is_nullable(), "Edge: NullableCollections metadata is nullable")
  ok(nullable_coll.properties[2]:is_map(), "Edge: NullableCollections metadata is map")
  ok(nullable_coll.properties[3]:is_nullable(), "Edge: NullableCollections ids is nullable")
  ok(nullable_coll.properties[3]:is_set(), "Edge: NullableCollections ids is set")

  local result = generator.generate(nullable_coll, nil)
  ok(result ~= nil, "Edge: NullableCollections generates result")
  if result then
    -- copyWith should have nullable collection params
    local copy = result.methods.copyWith
    ok(copy:find("List<String>?", 1, true) ~= nil, "Edge: NullableCollections copyWith has List<String>?")
  end
end

-- 11. DateTime fields: Event
local event_class = edge_map["Event"]
ok(event_class ~= nil, "Edge: Event parsed")
if event_class then
  local result = generator.generate(event_class, nil)
  ok(result ~= nil, "Edge: Event generates result")
  if result then
    local to_map = result.methods.toMap
    ok(to_map:find("startTime.toUtc().toIso8601String()", 1, true) ~= nil,
      "Edge: Event toMap startTime uses toIso8601String")
    ok(to_map:find("endTime?.toUtc().toIso8601String()", 1, true) ~= nil,
      "Edge: Event toMap endTime uses ?. for nullable DateTime")

    local from_map = result.methods.fromMap
    ok(from_map:find("DateTime.parse", 1, true) ~= nil, "Edge: Event fromMap uses DateTime.parse")
  end
end

-- 12. Nested custom types: Comment
local comment_class = edge_map["Comment"]
ok(comment_class ~= nil, "Edge: Comment parsed")
if comment_class then
  local result = generator.generate(comment_class, nil)
  ok(result ~= nil, "Edge: Comment generates result")
  if result then
    local to_map = result.methods.toMap
    ok(to_map:find("author.toMap()", 1, true) ~= nil, "Edge: Comment toMap uses author.toMap()")
    ok(to_map:find("replyTo?.toMap()", 1, true) ~= nil, "Edge: Comment toMap uses replyTo?.toMap()")

    local from_map = result.methods.fromMap
    ok(from_map:find("User.fromMap", 1, true) ~= nil, "Edge: Comment fromMap uses User.fromMap")
  end
end

-- 13. Enum skip: Priority enum should not generate
if priority_enum then
  local result = generator.generate(priority_enum, nil)
  ok(result == nil, "Edge: Priority enum generates nil (skipped)")
end

-- 14. WithLate: is_late flag, gen_properties exclusion, build_class_text preservation
local with_late = edge_map["WithLate"]
ok(with_late ~= nil, "Edge: WithLate parsed")
if with_late then
  eq(#with_late.properties, 2, "Edge: WithLate has 2 total properties")

  -- Check is_late flag
  local name_prop, computed_prop
  for _, p in ipairs(with_late.properties) do
    if p.name == "name" then name_prop = p end
    if p.name == "computed" then computed_prop = p end
  end
  ok(name_prop ~= nil, "Edge: WithLate has 'name' property")
  ok(computed_prop ~= nil, "Edge: WithLate has 'computed' property")
  if name_prop then
    ok(not name_prop.is_late, "Edge: WithLate 'name' is NOT late")
  end
  if computed_prop then
    ok(computed_prop.is_late, "Edge: WithLate 'computed' IS late")
  end

  -- gen_properties should exclude the late field
  local gen_props = with_late:gen_properties()
  eq(#gen_props, 1, "Edge: WithLate gen_properties returns 1 (excludes late)")
  if #gen_props > 0 then
    eq(gen_props[1].name, "name", "Edge: WithLate gen_properties[1] is 'name'")
  end

  -- Generate and check build_class_text preserves the late field line
  local result = generator.generate(with_late, nil)
  ok(result ~= nil, "Edge: WithLate generates result")
  if result then
    local edge_lines = {}
    for line in (edge_text .. "\n"):gmatch("([^\n]*)\n") do
      edge_lines[#edge_lines + 1] = line
    end
    local new_lines, _ = generator.build_class_text(edge_lines, with_late, result)
    local output = table.concat(new_lines, "\n")
    ok(output:find("late final String computed;", 1, true) ~= nil,
      "Edge: WithLate build_class_text preserves late field line")
    -- Constructor should only have 'name', not 'computed'
    ok(output:find("required this.name", 1, true) ~= nil,
      "Edge: WithLate constructor has 'name'")
    ok(output:find("this.computed", 1, true) == nil,
      "Edge: WithLate constructor does NOT have 'computed'")
    -- Constructor must NOT be const (late fields prevent const)
    ok(result.methods.constructor:find("const ") == nil,
      "Edge: WithLate constructor is NOT const (late field prevents it)")
  end
end

-- 15. Comment.fromMap: nullable custom type (User?) has null check
if comment_class then
  local result = generator.generate(comment_class, nil)
  if result and result.methods.fromMap then
    local fm = result.methods.fromMap
    -- replyTo is User? — should have null check
    ok(fm:find("map['replyTo'] != null", 1, true) ~= nil,
      "Edge: Comment fromMap has null check for nullable User? (replyTo)")
    ok(fm:find(": null", 1, true) ~= nil,
      "Edge: Comment fromMap has ': null' fallback for nullable replyTo")
    -- author is User (non-nullable) — should NOT have null check
    local author_section = fm:match("author:(.-)[\n,]")
    if author_section then
      ok(author_section:find("!= null") == nil,
        "Edge: Comment fromMap does NOT null-check non-nullable author")
    end
  end
end

-- 16. Event.fromMap: nullable DateTime (endTime?) has null check
if event_class then
  local result = generator.generate(event_class, nil)
  if result and result.methods.fromMap then
    local fm = result.methods.fromMap
    -- endTime is DateTime? — should have null check
    ok(fm:find("map['endTime'] != null", 1, true) ~= nil,
      "Edge: Event fromMap has null check for nullable DateTime? (endTime)")
    ok(fm:find("DateTime.parse", 1, true) ~= nil,
      "Edge: Event fromMap uses DateTime.parse for endTime")
    -- startTime is DateTime (non-nullable) — should NOT have null check
    local start_section = fm:match("startTime:(.-)[\n,]")
    if start_section then
      ok(start_section:find("!= null") == nil,
        "Edge: Event fromMap does NOT null-check non-nullable startTime")
    end
  end
end

-- 17. WithConstructor build_class_text: no duplicate blank line before constructor
if with_constr then
  local result = generator.generate(with_constr, nil)
  if result then
    local edge_lines = {}
    for line in (edge_text .. "\n"):gmatch("([^\n]*)\n") do
      edge_lines[#edge_lines + 1] = line
    end
    local new_lines, _ = generator.build_class_text(edge_lines, with_constr, result)
    -- Check that there are no consecutive blank lines (double blank)
    local found_double_blank = false
    for li = 1, #new_lines - 1 do
      if utils.trim(new_lines[li]) == "" and utils.trim(new_lines[li + 1]) == "" then
        found_double_blank = true
        break
      end
    end
    ok(not found_double_blank, "Edge: WithConstructor build_class_text has no double blank lines")
    -- Also verify the old constructor is replaced, not duplicated
    local constr_count = 0
    for _, line in ipairs(new_lines) do
      if line:find("WithConstructor({", 1, true) then
        constr_count = constr_count + 1
      end
    end
    eq(constr_count, 1, "Edge: WithConstructor has exactly 1 constructor (no duplicate)")
  end
end

--------------------------------------------------------------------------------
-- Incremental module tests
--------------------------------------------------------------------------------
io.write("\n=== Incremental: Field Extraction Tests ===\n")

-- extract_this_fields
do
  local text = [[
  const User({
    required this.name,
    required this.age,
    this.email,
    required this.isActive,
  });]]
  local fields = incremental.extract_this_fields(text)
  eq(#fields, 4, "extract_this_fields: User constructor has 4 fields")
  eq(fields[1], "name", "extract_this_fields: first is name")
  eq(fields[2], "age", "extract_this_fields: second is age")
  eq(fields[3], "email", "extract_this_fields: third is email")
  eq(fields[4], "isActive", "extract_this_fields: fourth is isActive")

  -- No duplicates
  local text2 = "  Foo({required this.x, required this.x});"
  local f2 = incremental.extract_this_fields(text2)
  eq(#f2, 1, "extract_this_fields: deduplicates")
end

-- extract_copywith_fields
do
  local text = [[
  User copyWith({String? name, int? age, String? email, bool? isActive}) {
    return User(
      name: name ?? this.name,
      age: age ?? this.age,
      email: email ?? this.email,
      isActive: isActive ?? this.isActive,
    );
  }]]
  local fields = incremental.extract_copywith_fields(text)
  eq(#fields, 4, "extract_copywith_fields: User has 4 fields")
  eq(fields[1], "name", "extract_copywith_fields: first is name")
  eq(fields[4], "isActive", "extract_copywith_fields: last is isActive")
end

-- extract_tomap_fields
do
  local text = [[
  Map<String, dynamic> toMap() {
    return {'name': name, 'age': age, 'email': email, 'isActive': isActive};
  }]]
  local fields = incremental.extract_tomap_fields(text)
  eq(#fields, 4, "extract_tomap_fields: User has 4 fields")
  eq(fields[1], "name", "extract_tomap_fields: first is name")
end

-- extract_frommap_fields
do
  local text = [[
  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      name: map['name'] as String,
      age: map['age'] as int,
      email: map['email'] as String?,
      isActive: map['isActive'] as bool,
    );
  }]]
  local fields = incremental.extract_frommap_fields(text)
  -- fromMap extracts both named param keys and map['key'] keys, deduplicating
  ok(#fields >= 4, "extract_frommap_fields: User has >= 4 fields")
  -- Check that key fields are present
  local fset = {}
  for _, f in ipairs(fields) do fset[f] = true end
  ok(fset["name"], "extract_frommap_fields: has name")
  ok(fset["age"], "extract_frommap_fields: has age")
  ok(fset["email"], "extract_frommap_fields: has email")
  ok(fset["isActive"], "extract_frommap_fields: has isActive")
end

-- extract_tostring_fields
do
  local text = "  @override\n  String toString() =>\n      'User(name: $name, age: $age, email: $email, isActive: $isActive)';"
  local fields = incremental.extract_tostring_fields(text)
  eq(#fields, 4, "extract_tostring_fields: User has 4 fields")
  eq(fields[1], "name", "extract_tostring_fields: first is name")
end

-- extract_equality_fields
do
  local text = [[
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is User &&
        other.name == name &&
        other.age == age &&
        other.email == email &&
        other.isActive == isActive;
  }]]
  local fields = incremental.extract_equality_fields(text)
  eq(#fields, 4, "extract_equality_fields: User has 4 fields")
  eq(fields[1], "name", "extract_equality_fields: first is name")
end

-- extract_hashcode_fields
do
  local text = "  @override\n  int get hashCode =>\n      name.hashCode ^ age.hashCode ^ email.hashCode ^ isActive.hashCode;"
  local fields = incremental.extract_hashcode_fields(text)
  eq(#fields, 4, "extract_hashcode_fields: User has 4 fields")
  eq(fields[1], "name", "extract_hashcode_fields: first is name")
end

--------------------------------------------------------------------------------
io.write("\n=== Incremental: Block Detection Tests ===\n")

-- Test block detection on the expected_user.dart (fully generated class)
do
  local user_full_text = read_file(fixtures_dir .. "expected_user.dart")
  local full_lines = {}
  for line in (user_full_text .. "\n"):gmatch("([^\n]*)\n") do
    full_lines[#full_lines + 1] = line
  end

  local full_clazzes = parser.parse_classes(user_full_text)
  local full_user
  for _, c in ipairs(full_clazzes) do
    if c.name == "User" then full_user = c; break end
  end
  ok(full_user ~= nil, "Block detect: parsed User from expected_user.dart")

  if full_user then
    local blocks = incremental.detect_blocks(full_user, full_lines)

    -- Constructor
    ok(blocks.constructor ~= nil, "Block detect: found constructor")
    if blocks.constructor then
      eq(blocks.constructor.kind, "constructor", "Block detect: constructor kind")
      eq(#blocks.constructor.fields, 4, "Block detect: constructor has 4 fields")
    end

    -- copyWith
    ok(blocks.copyWith ~= nil, "Block detect: found copyWith")
    if blocks.copyWith then
      eq(#blocks.copyWith.fields, 4, "Block detect: copyWith has 4 fields")
    end

    -- toMap
    ok(blocks.toMap ~= nil, "Block detect: found toMap")
    if blocks.toMap then
      eq(#blocks.toMap.fields, 4, "Block detect: toMap has 4 fields")
    end

    -- fromMap
    ok(blocks.fromMap ~= nil, "Block detect: found fromMap")
    if blocks.fromMap then
      ok(#blocks.fromMap.fields >= 4, "Block detect: fromMap has >= 4 fields")
    end

    -- toJson
    ok(blocks.toJson ~= nil, "Block detect: found toJson")

    -- fromJson
    ok(blocks.fromJson ~= nil, "Block detect: found fromJson")

    -- toString
    ok(blocks.toString ~= nil, "Block detect: found toString")
    if blocks.toString then
      eq(#blocks.toString.fields, 4, "Block detect: toString has 4 fields")
    end

    -- equality
    ok(blocks.equality ~= nil, "Block detect: found equality")
    if blocks.equality then
      eq(#blocks.equality.fields, 4, "Block detect: equality has 4 fields")
    end

    -- hashCode
    ok(blocks.hashCode ~= nil, "Block detect: found hashCode")
    if blocks.hashCode then
      eq(#blocks.hashCode.fields, 4, "Block detect: hashCode has 4 fields")
    end
  end
end

-- Test block detection on bare class (no methods)
do
  local bare_text = "class Bare {\n  final String name;\n  final int age;\n}\n"
  local bare_lines = {}
  for line in (bare_text .. "\n"):gmatch("([^\n]*)\n") do
    bare_lines[#bare_lines + 1] = line
  end

  local bare_clazzes = parser.parse_classes(bare_text)
  local bare_class = bare_clazzes[1]
  ok(bare_class ~= nil, "Block detect bare: parsed class")

  if bare_class then
    local blocks = incremental.detect_blocks(bare_class, bare_lines)
    eq(blocks.constructor, nil, "Block detect bare: no constructor")
    eq(blocks.copyWith, nil, "Block detect bare: no copyWith")
    eq(blocks.toMap, nil, "Block detect bare: no toMap")
    eq(blocks.fromMap, nil, "Block detect bare: no fromMap")
    eq(blocks.toJson, nil, "Block detect bare: no toJson")
    eq(blocks.fromJson, nil, "Block detect bare: no fromJson")
    eq(blocks.toString, nil, "Block detect bare: no toString")
    eq(blocks.equality, nil, "Block detect bare: no equality")
    eq(blocks.hashCode, nil, "Block detect bare: no hashCode")
  end
end

-- Test block detection with partial methods (only constructor + toString)
do
  local partial_text = [[class Partial {
  final String name;
  final int age;

  const Partial({
    required this.name,
    required this.age,
  });

  @override
  String toString() =>
      'Partial(name: $name, age: $age)';
}
]]
  local partial_lines = {}
  for line in (partial_text .. "\n"):gmatch("([^\n]*)\n") do
    partial_lines[#partial_lines + 1] = line
  end

  local partial_clazzes = parser.parse_classes(partial_text)
  local partial_class = partial_clazzes[1]
  ok(partial_class ~= nil, "Block detect partial: parsed class")

  if partial_class then
    local blocks = incremental.detect_blocks(partial_class, partial_lines)
    ok(blocks.constructor ~= nil, "Block detect partial: found constructor")
    ok(blocks.toString ~= nil, "Block detect partial: found toString")
    eq(blocks.copyWith, nil, "Block detect partial: no copyWith")
    eq(blocks.toMap, nil, "Block detect partial: no toMap")
    eq(blocks.equality, nil, "Block detect partial: no equality")
    eq(blocks.hashCode, nil, "Block detect partial: no hashCode")
  end
end

--------------------------------------------------------------------------------
io.write("\n=== Incremental: Field Comparison & Status Tests ===\n")

-- missing_fields
do
  local missing = incremental.missing_fields({"a", "b", "c"}, {"a", "c"})
  eq(#missing, 1, "missing_fields: 1 missing")
  eq(missing[1], "b", "missing_fields: missing field is 'b'")

  local none = incremental.missing_fields({"a", "b"}, {"a", "b"})
  eq(#none, 0, "missing_fields: nothing missing")

  local all = incremental.missing_fields({"a", "b"}, {})
  eq(#all, 2, "missing_fields: all missing when existing is empty")
end

-- fields_match
do
  ok(incremental.fields_match({"a", "b"}, {"b", "a"}), "fields_match: same set different order")
  ok(incremental.fields_match({}, {}), "fields_match: both empty")
  ok(not incremental.fields_match({"a"}, {"a", "b"}), "fields_match: different sizes")
  ok(not incremental.fields_match({"a", "c"}, {"a", "b"}), "fields_match: different elements")
end

-- get_class_field_names
do
  if user_class then
    local names = incremental.get_class_field_names(user_class)
    eq(#names, 4, "get_class_field_names: User has 4 gen fields")
    eq(names[1], "name", "get_class_field_names: first is name")
  end
end

-- block_status
do
  -- absent
  eq(incremental.block_status(nil, {"a", "b"}), "absent", "block_status: nil block = absent")

  -- complete
  local complete_block = { fields = {"a", "b", "c"} }
  eq(incremental.block_status(complete_block, {"a", "b", "c"}), "complete", "block_status: all fields = complete")

  -- incomplete
  local incomplete_block = { fields = {"a", "c"} }
  eq(incremental.block_status(incomplete_block, {"a", "b", "c"}), "incomplete", "block_status: missing field = incomplete")
end

-- wrapper_status
do
  eq(incremental.wrapper_status(nil), "absent", "wrapper_status: nil = absent")
  eq(incremental.wrapper_status({ fields = {} }), "complete", "wrapper_status: present = complete")
end

--------------------------------------------------------------------------------
io.write("\n=== Incremental: Insert Point Tests ===\n")

-- Test find_insert_point on bare class
do
  local bare_text = "class Bare {\n  final String name;\n  final int age;\n}\n"
  local bare_lines = {}
  for line in (bare_text .. "\n"):gmatch("([^\n]*)\n") do
    bare_lines[#bare_lines + 1] = line
  end
  local bare_clazzes = parser.parse_classes(bare_text)
  local bare_class = bare_clazzes[1]

  if bare_class then
    local blocks = {}
    -- Constructor should insert after last property
    local insert_pt = incremental.find_insert_point(bare_class, blocks, "constructor")
    eq(insert_pt, bare_class:props_end_at_line(), "find_insert_point: constructor goes after props")

    -- copyWith should also go after props when no constructor block detected
    local insert_cw = incremental.find_insert_point(bare_class, blocks, "copyWith")
    eq(insert_cw, bare_class:props_end_at_line(), "find_insert_point: copyWith after props (no constr block)")
  end
end

-- Test find_insert_point with some blocks present
do
  local user_full_text = read_file(fixtures_dir .. "expected_user.dart")
  local full_lines = {}
  for line in (user_full_text .. "\n"):gmatch("([^\n]*)\n") do
    full_lines[#full_lines + 1] = line
  end

  local full_clazzes = parser.parse_classes(user_full_text)
  local full_user
  for _, c in ipairs(full_clazzes) do
    if c.name == "User" then full_user = c; break end
  end

  if full_user then
    local blocks = incremental.detect_blocks(full_user, full_lines)

    -- toString should insert after fromJson
    if blocks.fromJson then
      local pt = incremental.find_insert_point(full_user, blocks, "toString")
      ok(pt >= blocks.fromJson.end_line, "find_insert_point: toString after fromJson")
    end

    -- equality should insert after toString
    if blocks.toString then
      local pt = incremental.find_insert_point(full_user, blocks, "equality")
      ok(pt >= blocks.toString.end_line, "find_insert_point: equality after toString")
    end
  end
end

--------------------------------------------------------------------------------
io.write("\n=== Incremental: Build Edit Tests ===\n")

-- build_edit: idempotency (identical text returns nil)
do
  local user_full_text = read_file(fixtures_dir .. "expected_user.dart")
  local full_lines = {}
  for line in (user_full_text .. "\n"):gmatch("([^\n]*)\n") do
    full_lines[#full_lines + 1] = line
  end

  local full_clazzes = parser.parse_classes(user_full_text)
  local full_user
  for _, c in ipairs(full_clazzes) do
    if c.name == "User" then full_user = c; break end
  end

  if full_user then
    local blocks = incremental.detect_blocks(full_user, full_lines)

    -- Generate fresh constructor and compare with existing
    local fresh_constr = generator.generate_constructor(full_user)
    local edit = incremental.build_edit("constructor", full_user, blocks, fresh_constr)
    eq(edit, nil, "build_edit idempotent: constructor unchanged returns nil")

    -- Generate fresh toString and compare
    local fresh_ts = generator.generate_to_string(full_user)
    local ts_edit = incremental.build_edit("toString", full_user, blocks, fresh_ts)
    eq(ts_edit, nil, "build_edit idempotent: toString unchanged returns nil")

    -- Generate fresh hashCode
    local fresh_hc = generator.generate_hash_code(full_user)
    local hc_edit = incremental.build_edit("hashCode", full_user, blocks, fresh_hc)
    eq(hc_edit, nil, "build_edit idempotent: hashCode unchanged returns nil")
  end
end

-- build_edit: insert when block absent
do
  local bare_text = "class Bare {\n  final String name;\n  final int age;\n}\n"
  local bare_lines = {}
  for line in (bare_text .. "\n"):gmatch("([^\n]*)\n") do
    bare_lines[#bare_lines + 1] = line
  end
  local bare_clazzes = parser.parse_classes(bare_text)
  local bare_class = bare_clazzes[1]

  if bare_class then
    local blocks = {}
    local constr_text = generator.generate_constructor(bare_class)
    local edit = incremental.build_edit("constructor", bare_class, blocks, constr_text)
    ok(edit ~= nil, "build_edit insert: returns edit for absent block")
    if edit then
      eq(edit.action, "insert_after", "build_edit insert: action is insert_after")
      ok(#edit.new_lines > 0, "build_edit insert: has new_lines")
      -- First line should be blank separator
      eq(edit.new_lines[1], "", "build_edit insert: first line is blank separator")
    end
  end
end

-- build_edit: replace when block differs
do
  -- Create a class with a constructor missing a field
  local text = [[class TwoField {
  final String name;
  final int age;

  const TwoField({
    required this.name,
  });
}
]]
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]

  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.constructor ~= nil, "build_edit replace: found partial constructor")

    if blocks.constructor then
      eq(#blocks.constructor.fields, 1, "build_edit replace: constructor has 1 field")

      -- Generate a fresh constructor (should have 2 fields)
      local fresh = generator.generate_constructor(clazz)
      ok(fresh:find("this.age", 1, true) ~= nil, "build_edit replace: fresh has age field")

      local edit = incremental.build_edit("constructor", clazz, blocks, fresh)
      ok(edit ~= nil, "build_edit replace: returns edit for incomplete block")
      if edit then
        eq(edit.action, "replace", "build_edit replace: action is replace")
        eq(edit.start_line, blocks.constructor.start_line, "build_edit replace: start_line matches")
        eq(edit.end_line, blocks.constructor.end_line, "build_edit replace: end_line matches")
        -- New lines should contain both fields
        local new_text = table.concat(edit.new_lines, "\n")
        ok(new_text:find("this.name", 1, true) ~= nil, "build_edit replace: new has name")
        ok(new_text:find("this.age", 1, true) ~= nil, "build_edit replace: new has age")
      end
    end
  end
end

--------------------------------------------------------------------------------
io.write("\n=== Incremental: Apply Edits Tests ===\n")

-- apply_edits: single insert
do
  local lines = { "line1", "line2", "line3", "line4" }
  local edits = {
    { start_line = 2, end_line = 2, new_lines = { "inserted_a", "inserted_b" }, action = "insert_after" },
  }
  local result = incremental.apply_edits(lines, edits)
  eq(#result, 6, "apply_edits insert: total lines = 6")
  eq(result[1], "line1", "apply_edits insert: line 1 unchanged")
  eq(result[2], "line2", "apply_edits insert: line 2 unchanged")
  eq(result[3], "inserted_a", "apply_edits insert: inserted line a")
  eq(result[4], "inserted_b", "apply_edits insert: inserted line b")
  eq(result[5], "line3", "apply_edits insert: line 3 shifted")
  eq(result[6], "line4", "apply_edits insert: line 4 shifted")
end

-- apply_edits: single replace
do
  local lines = { "line1", "old2", "old3", "line4" }
  local edits = {
    { start_line = 2, end_line = 3, new_lines = { "new2" }, action = "replace" },
  }
  local result = incremental.apply_edits(lines, edits)
  eq(#result, 3, "apply_edits replace: total lines = 3")
  eq(result[1], "line1", "apply_edits replace: line 1 unchanged")
  eq(result[2], "new2", "apply_edits replace: replaced lines")
  eq(result[3], "line4", "apply_edits replace: line 4 unchanged")
end

-- apply_edits: multiple edits (descending order)
do
  local lines = { "a", "b", "c", "d", "e" }
  local edits = {
    { start_line = 4, end_line = 4, new_lines = { "D_replaced" }, action = "replace" },
    { start_line = 2, end_line = 2, new_lines = { "B_replaced" }, action = "replace" },
  }
  local result = incremental.apply_edits(lines, edits)
  eq(#result, 5, "apply_edits multi: total lines = 5")
  eq(result[1], "a", "apply_edits multi: a unchanged")
  eq(result[2], "B_replaced", "apply_edits multi: b replaced")
  eq(result[3], "c", "apply_edits multi: c unchanged")
  eq(result[4], "D_replaced", "apply_edits multi: d replaced")
  eq(result[5], "e", "apply_edits multi: e unchanged")
end

-- apply_edits: empty edits returns same lines
do
  local lines = { "x", "y", "z" }
  local result = incremental.apply_edits(lines, {})
  eq(#result, 3, "apply_edits empty: same count")
  eq(result[1], "x", "apply_edits empty: same content")
end

--------------------------------------------------------------------------------
io.write("\n=== Incremental: Integration Tests ===\n")

-- Full integration: generate all for bare User, detect blocks, verify idempotency
do
  -- Start with bare class
  local bare_user_text = "class User {\n  final String name;\n  final int age;\n  final String? email;\n  final bool isActive;\n}\n"
  local lines = {}
  for line in (bare_user_text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local clazzes = parser.parse_classes(bare_user_text)
  local clazz = clazzes[1]
  ok(clazz ~= nil, "Integration: parsed bare User")

  if clazz then
    -- Step 1: detect blocks on bare class (all absent)
    local blocks = incremental.detect_blocks(clazz, lines)
    local field_names = incremental.get_class_field_names(clazz)
    eq(incremental.block_status(blocks.constructor, field_names), "absent", "Integration: constructor absent initially")
    eq(incremental.block_status(blocks.copyWith, field_names), "absent", "Integration: copyWith absent initially")

    -- Step 2: generate all methods and build edits
    local all_kinds = { "constructor", "copyWith", "toMap", "fromMap", "toJson", "fromJson", "toString", "equality", "hashCode" }
    local edits = {}

    for _, kind in ipairs(all_kinds) do
      local gen_text, _ = nil, {}
      if kind == "constructor" then
        gen_text = generator.generate_constructor(clazz)
      elseif kind == "copyWith" then
        gen_text = generator.generate_copy_with(clazz)
      elseif kind == "toMap" then
        gen_text = generator.generate_to_map(clazz)
      elseif kind == "fromMap" then
        gen_text = generator.generate_from_map(clazz)
      elseif kind == "toJson" then
        gen_text = generator.generate_to_json(clazz)
      elseif kind == "fromJson" then
        gen_text = generator.generate_from_json(clazz)
      elseif kind == "toString" then
        gen_text = generator.generate_to_string(clazz)
      elseif kind == "equality" then
        gen_text = generator.generate_equality(clazz)
      elseif kind == "hashCode" then
        gen_text = generator.generate_hash_code(clazz)
      end

      if gen_text then
        local edit = incremental.build_edit(kind, clazz, blocks, gen_text)
        if edit then
          edits[#edits + 1] = edit
        end
      end
    end

    ok(#edits > 0, "Integration: produced edits for bare class")

    -- Step 3: apply edits
    local new_lines = incremental.apply_edits(lines, edits)
    ok(#new_lines > #lines, "Integration: new lines longer than bare class")

    local new_text = table.concat(new_lines, "\n")
    ok(new_text:find("const User({", 1, true) ~= nil, "Integration: has constructor")
    ok(new_text:find("copyWith({", 1, true) ~= nil, "Integration: has copyWith")
    ok(new_text:find("toMap()", 1, true) ~= nil, "Integration: has toMap")
    ok(new_text:find("fromMap(", 1, true) ~= nil, "Integration: has fromMap")
    ok(new_text:find("toJson()", 1, true) ~= nil, "Integration: has toJson")
    ok(new_text:find("fromJson(", 1, true) ~= nil, "Integration: has fromJson")
    ok(new_text:find("toString()", 1, true) ~= nil, "Integration: has toString")
    ok(new_text:find("operator ==(", 1, true) ~= nil, "Integration: has equality")
    ok(new_text:find("hashCode", 1, true) ~= nil, "Integration: has hashCode")
    -- Should end with }
    ok(utils.trim(new_lines[#new_lines]) == "}" or utils.trim(new_lines[#new_lines - 1]) == "}",
      "Integration: class body ends with }")

    -- Step 4: IDEMPOTENCY — re-parse, re-detect, re-generate → no edits
    local round2_clazzes = parser.parse_classes(new_text)
    local round2_clazz
    for _, c in ipairs(round2_clazzes) do
      if c.name == "User" then round2_clazz = c; break end
    end
    ok(round2_clazz ~= nil, "Integration idempotent: re-parsed User")

    if round2_clazz then
      local round2_blocks = incremental.detect_blocks(round2_clazz, new_lines)
      local round2_edits = {}
      local round2_fields = incremental.get_class_field_names(round2_clazz)

      for _, kind in ipairs(all_kinds) do
        local gen_text = nil
        if kind == "constructor" then
          gen_text = generator.generate_constructor(round2_clazz)
        elseif kind == "copyWith" then
          gen_text = generator.generate_copy_with(round2_clazz)
        elseif kind == "toMap" then
          gen_text = generator.generate_to_map(round2_clazz)
        elseif kind == "fromMap" then
          gen_text = generator.generate_from_map(round2_clazz)
        elseif kind == "toJson" then
          gen_text = generator.generate_to_json(round2_clazz)
        elseif kind == "fromJson" then
          gen_text = generator.generate_from_json(round2_clazz)
        elseif kind == "toString" then
          gen_text = generator.generate_to_string(round2_clazz)
        elseif kind == "equality" then
          gen_text = generator.generate_equality(round2_clazz)
        elseif kind == "hashCode" then
          gen_text = generator.generate_hash_code(round2_clazz)
        end

        if gen_text then
          local edit = incremental.build_edit(kind, round2_clazz, round2_blocks, gen_text)
          if edit then
            round2_edits[#round2_edits + 1] = edit
            io.write("    [DEBUG] Non-idempotent edit for " .. kind .. " (action=" .. edit.action .. ")\n")
          end
        end
      end

      eq(#round2_edits, 0, "Integration idempotent: second run produces 0 edits")
    end
  end
end

-- Cross-action safety: generate constructor, then generate copyWith, constructor still intact
do
  local bare_text = "class Safe {\n  final String x;\n  final int y;\n}\n"
  local lines = {}
  for line in (bare_text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local clazzes = parser.parse_classes(bare_text)
  local clazz = clazzes[1]

  if clazz then
    -- Generate constructor
    local blocks = incremental.detect_blocks(clazz, lines)
    local constr_text = generator.generate_constructor(clazz)
    local edit1 = incremental.build_edit("constructor", clazz, blocks, constr_text)
    ok(edit1 ~= nil, "Cross-action: constructor edit produced")
    if edit1 then
      -- Apply constructor
      lines = incremental.apply_edits(lines, { edit1 })

      -- Re-parse
      local text_after = table.concat(lines, "\n")
      local clazzes2 = parser.parse_classes(text_after)
      local clazz2 = clazzes2[1]

      if clazz2 then
        -- Now generate copyWith
        local blocks2 = incremental.detect_blocks(clazz2, lines)
        ok(blocks2.constructor ~= nil, "Cross-action: constructor still detected after re-parse")

        local copy_text = generator.generate_copy_with(clazz2)
        local edit2 = incremental.build_edit("copyWith", clazz2, blocks2, copy_text)
        ok(edit2 ~= nil, "Cross-action: copyWith edit produced")
        if edit2 then
          lines = incremental.apply_edits(lines, { edit2 })
          local final_text = table.concat(lines, "\n")

          -- Verify constructor is still intact
          ok(final_text:find("const Safe({", 1, true) ~= nil, "Cross-action: constructor still present")
          ok(final_text:find("required this.x", 1, true) ~= nil, "Cross-action: constructor has x")
          ok(final_text:find("required this.y", 1, true) ~= nil, "Cross-action: constructor has y")

          -- Verify copyWith is present
          ok(final_text:find("copyWith({", 1, true) ~= nil, "Cross-action: copyWith present")
          ok(final_text:find("x ?? this.x", 1, true) ~= nil, "Cross-action: copyWith has x")
          ok(final_text:find("y ?? this.y", 1, true) ~= nil, "Cross-action: copyWith has y")
        end
      end
    end
  end
end

-- Incremental update: generate constructor for class, add field, re-generate → only new field added
do
  -- Start with 2-field class and generate constructor
  local text = "class Grow {\n  final String a;\n  final int b;\n}\n"
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]

  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    local constr = generator.generate_constructor(clazz)
    local edit = incremental.build_edit("constructor", clazz, blocks, constr)
    if edit then
      lines = incremental.apply_edits(lines, { edit })
    end

    -- Now simulate adding a third field
    -- Insert "  final bool c;" before the closing brace
    local new_lines_with_field = {}
    for i, l in ipairs(lines) do
      -- Find the blank line before constructor and insert new field before it
      if utils.trim(l) == "" and i > 2 and utils.trim(lines[i + 1] or ""):find("Safe") ~= nil then
        new_lines_with_field[#new_lines_with_field + 1] = "  final bool c;"
      end
      new_lines_with_field[#new_lines_with_field + 1] = l
    end

    -- Actually, let's be more direct: insert after line 3 (final int b;)
    new_lines_with_field = {}
    for i, l in ipairs(lines) do
      new_lines_with_field[#new_lines_with_field + 1] = l
      if l:find("final int b;", 1, true) then
        new_lines_with_field[#new_lines_with_field + 1] = "  final bool c;"
      end
    end

    local new_text = table.concat(new_lines_with_field, "\n")
    local new_clazzes = parser.parse_classes(new_text)
    local new_clazz = new_clazzes[1]

    if new_clazz then
      eq(#new_clazz:gen_properties(), 3, "Incremental update: now 3 fields")
      local new_blocks = incremental.detect_blocks(new_clazz, new_lines_with_field)
      ok(new_blocks.constructor ~= nil, "Incremental update: constructor still detected")

      if new_blocks.constructor then
        -- Constructor should now be incomplete (missing 'c')
        local field_names = incremental.get_class_field_names(new_clazz)
        local status = incremental.block_status(new_blocks.constructor, field_names)
        eq(status, "incomplete", "Incremental update: constructor is incomplete")

        local missing = incremental.missing_fields(field_names, new_blocks.constructor.fields)
        eq(#missing, 1, "Incremental update: 1 missing field")
        eq(missing[1], "c", "Incremental update: missing field is 'c'")

        -- Re-generate and build edit
        local fresh_constr = generator.generate_constructor(new_clazz)
        local update_edit = incremental.build_edit("constructor", new_clazz, new_blocks, fresh_constr)
        ok(update_edit ~= nil, "Incremental update: edit produced")
        if update_edit then
          eq(update_edit.action, "replace", "Incremental update: action is replace")
          local updated_text = table.concat(update_edit.new_lines, "\n")
          ok(updated_text:find("this.a", 1, true) ~= nil, "Incremental update: has old field a")
          ok(updated_text:find("this.b", 1, true) ~= nil, "Incremental update: has old field b")
          ok(updated_text:find("this.c", 1, true) ~= nil, "Incremental update: has new field c")
        end
      end
    end
  end
end

-- Test with expected_user.dart: all blocks complete, all statuses should be complete
do
  local user_full_text = read_file(fixtures_dir .. "expected_user.dart")
  local full_lines = {}
  for line in (user_full_text .. "\n"):gmatch("([^\n]*)\n") do
    full_lines[#full_lines + 1] = line
  end

  local full_clazzes = parser.parse_classes(user_full_text)
  local full_user
  for _, c in ipairs(full_clazzes) do
    if c.name == "User" then full_user = c; break end
  end

  if full_user then
    local blocks = incremental.detect_blocks(full_user, full_lines)
    local field_names = incremental.get_class_field_names(full_user)

    eq(incremental.block_status(blocks.constructor, field_names), "complete", "Status: constructor complete")
    eq(incremental.block_status(blocks.copyWith, field_names), "complete", "Status: copyWith complete")
    eq(incremental.block_status(blocks.toMap, field_names), "complete", "Status: toMap complete")
    eq(incremental.block_status(blocks.toString, field_names), "complete", "Status: toString complete")
    eq(incremental.block_status(blocks.equality, field_names), "complete", "Status: equality complete")
    eq(incremental.block_status(blocks.hashCode, field_names), "complete", "Status: hashCode complete")
    eq(incremental.wrapper_status(blocks.toJson), "complete", "Status: toJson complete")
    eq(incremental.wrapper_status(blocks.fromJson), "complete", "Status: fromJson complete")
  end
end

-- Test block detection with multi-line constructor body (arrow fromJson)
do
  local text = [[class Arrow {
  final String name;

  factory Arrow.fromJson(String source) =>
      Arrow.fromMap(Map<String, dynamic>.from(json.decode(source)));
}
]]
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.fromJson ~= nil, "Arrow fromJson: detected multi-line arrow factory")
    if blocks.fromJson then
      -- Should span both lines
      ok(blocks.fromJson.end_line > blocks.fromJson.start_line,
        "Arrow fromJson: spans multiple lines")
    end
  end
end

-- Test: single-line toJson arrow method detected
do
  local text = [[class Single {
  final String name;

  String toJson() => json.encode(toMap());
}
]]
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.toJson ~= nil, "Single-line toJson: detected")
    if blocks.toJson then
      eq(blocks.toJson.start_line, blocks.toJson.end_line, "Single-line toJson: same start/end")
    end
  end
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
io.write("\n==========================================\n")
io.write(string.format("Results: %d passed, %d failed\n", passed, failed))
if failed > 0 then
  io.write("\nFailed tests:\n")
  for _, e in ipairs(errors) do
    io.write("  - " .. e .. "\n")
  end
  os.exit(1)
else
  io.write("All tests passed!\n")
  os.exit(0)
end
