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
io.write("\n=== Incremental: Edge Case Tests ===\n")

-- Helper: parse text into lines, parse class, return clazz + lines
local function parse_class_lines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local clazzes = parser.parse_classes(text)
  return clazzes[1], lines
end

-- Helper: generate all applicable methods for a class, apply edits, return new lines + text.
-- All absent blocks insert at the same original-space line (props_end); the canonical order
-- tiebreaker in apply_edits handles correct stacking. Do NOT fake block entries — that
-- produces post-edit-space line numbers which corrupt apply_edits.
local function generate_all_incremental(clazz, lines, kinds)
  kinds = kinds or { "constructor", "copyWith", "toMap", "fromMap", "toJson", "fromJson", "toString", "equality", "hashCode" }
  local blocks = incremental.detect_blocks(clazz, lines)
  local edits = {}
  for _, kind in ipairs(kinds) do
    local gen_text
    if kind == "constructor" then
      gen_text = generator.generate_constructor(clazz)
    elseif kind == "copyWith" then
      gen_text = (generator.generate_copy_with(clazz))
    elseif kind == "toMap" then
      gen_text = generator.generate_to_map(clazz)
    elseif kind == "fromMap" then
      gen_text = (generator.generate_from_map(clazz))
    elseif kind == "toJson" then
      gen_text = (generator.generate_to_json(clazz))
    elseif kind == "fromJson" then
      gen_text = (generator.generate_from_json(clazz))
    elseif kind == "toString" then
      gen_text = generator.generate_to_string(clazz)
    elseif kind == "equality" then
      gen_text = (generator.generate_equality(clazz))
    elseif kind == "hashCode" then
      gen_text = (generator.generate_hash_code(clazz))
    elseif kind == "props" then
      gen_text = generator.generate_props(clazz, blocks.props)
    end
    if gen_text then
      local edit = incremental.build_edit(kind, clazz, blocks, gen_text)
      if edit then
        edits[#edits + 1] = edit
      end
    end
  end
  local new_lines = incremental.apply_edits(lines, edits)
  local new_text = table.concat(new_lines, "\n")
  return new_lines, new_text, #edits
end

-- Helper: verify idempotency (second run produces 0 edits)
local function verify_idempotent(new_lines, new_text, class_name, kinds)
  kinds = kinds or { "constructor", "copyWith", "toMap", "fromMap", "toJson", "fromJson", "toString", "equality", "hashCode" }
  local r2_clazzes = parser.parse_classes(new_text)
  local r2_clazz
  for _, c in ipairs(r2_clazzes) do
    if c.name == class_name then r2_clazz = c; break end
  end
  if not r2_clazz then
    ok(false, "Idempotent " .. class_name .. ": re-parsed class")
    return
  end
  local r2_blocks = incremental.detect_blocks(r2_clazz, new_lines)
  local r2_edits = 0
  for _, kind in ipairs(kinds) do
    local gen_text
    if kind == "constructor" then
      gen_text = generator.generate_constructor(r2_clazz)
    elseif kind == "copyWith" then
      gen_text = (generator.generate_copy_with(r2_clazz))
    elseif kind == "toMap" then
      gen_text = generator.generate_to_map(r2_clazz)
    elseif kind == "fromMap" then
      gen_text = (generator.generate_from_map(r2_clazz))
    elseif kind == "toJson" then
      gen_text = (generator.generate_to_json(r2_clazz))
    elseif kind == "fromJson" then
      gen_text = (generator.generate_from_json(r2_clazz))
    elseif kind == "toString" then
      gen_text = generator.generate_to_string(r2_clazz)
    elseif kind == "equality" then
      gen_text = (generator.generate_equality(r2_clazz))
    elseif kind == "hashCode" then
      gen_text = (generator.generate_hash_code(r2_clazz))
    elseif kind == "props" then
      gen_text = generator.generate_props(r2_clazz, r2_blocks.props)
    end
    if gen_text then
      local edit = incremental.build_edit(kind, r2_clazz, r2_blocks, gen_text)
      if edit then
        r2_edits = r2_edits + 1
        io.write("    [DEBUG] Non-idempotent edit for " .. kind .. " (action=" .. edit.action .. ")\n")
      end
    end
  end
  eq(r2_edits, 0, "Idempotent " .. class_name .. ": second run produces 0 edits")
end

-- ===========================================================================
-- 1. Nullable fields: NullableCollections (nullable List?, Map?, Set?)
-- ===========================================================================
do
  local text = [[class NullableCollections {
  final List<String>? tags;
  final Map<String, dynamic>? metadata;
  final Set<int>? ids;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc NullableColl: parsed")
  if clazz then
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines)
    ok(edit_count > 0, "Edge Inc NullableColl: edits produced")

    -- Constructor: nullable fields should NOT have 'required'
    ok(new_text:find("this.tags,", 1, true) ~= nil, "Edge Inc NullableColl: constructor has tags (no required)")
    ok(new_text:find("this.metadata,", 1, true) ~= nil, "Edge Inc NullableColl: constructor has metadata (no required)")
    ok(new_text:find("this.ids,", 1, true) ~= nil, "Edge Inc NullableColl: constructor has ids (no required)")
    ok(new_text:find("required this.tags") == nil, "Edge Inc NullableColl: tags NOT required")

    -- copyWith should handle nullable collections
    ok(new_text:find("List<String>?", 1, true) ~= nil, "Edge Inc NullableColl: copyWith has List<String>?")
    ok(new_text:find("tags ?? this.tags", 1, true) ~= nil, "Edge Inc NullableColl: copyWith tags uses ??")

    -- toMap should handle nullable collections
    ok(new_text:find("'tags':", 1, true) ~= nil, "Edge Inc NullableColl: toMap has tags key")
    ok(new_text:find("'metadata':", 1, true) ~= nil, "Edge Inc NullableColl: toMap has metadata key")
    ok(new_text:find("'ids':", 1, true) ~= nil, "Edge Inc NullableColl: toMap has ids key")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "NullableCollections")
  end
end

-- ===========================================================================
-- 2. Late fields: WithLate (late field excluded from generation)
-- ===========================================================================
do
  local text = [[class WithLate {
  final String name;
  late final String computed;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc WithLate: parsed")
  if clazz then
    -- gen_properties should exclude late field
    local gen_props = clazz:gen_properties()
    eq(#gen_props, 1, "Edge Inc WithLate: gen_properties has 1 (excludes late)")
    eq(gen_props[1].name, "name", "Edge Inc WithLate: gen property is 'name'")

    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines)
    ok(edit_count > 0, "Edge Inc WithLate: edits produced")

    -- Constructor should only have 'name', not 'computed'
    ok(new_text:find("this.name", 1, true) ~= nil, "Edge Inc WithLate: constructor has name")
    ok(new_text:find("this.computed") == nil, "Edge Inc WithLate: constructor excludes computed (late)")

    -- Constructor should NOT be const (has late fields)
    ok(new_text:find("const WithLate") == nil, "Edge Inc WithLate: constructor NOT const (has late)")

    -- toString should only mention name
    ok(new_text:find("name: $name", 1, true) ~= nil, "Edge Inc WithLate: toString has name")
    ok(new_text:find("computed:") == nil, "Edge Inc WithLate: toString excludes computed")

    -- late field line should still be present in output
    ok(new_text:find("late final String computed;", 1, true) ~= nil,
      "Edge Inc WithLate: late field preserved in output")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "WithLate")
  end
end

-- ===========================================================================
-- 3. Non-final fields: MutableConfig (non-const constructor)
-- ===========================================================================
do
  local text = [[class MutableConfig {
  String host;
  int port;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc MutableConfig: parsed")
  if clazz then
    ok(not clazz:all_properties_final(), "Edge Inc MutableConfig: not all_properties_final")

    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines)
    ok(edit_count > 0, "Edge Inc MutableConfig: edits produced")

    -- Constructor should NOT be const
    ok(new_text:find("const MutableConfig") == nil, "Edge Inc MutableConfig: constructor NOT const")
    ok(new_text:find("MutableConfig({", 1, true) ~= nil, "Edge Inc MutableConfig: has constructor")

    -- Non-final, non-nullable fields should be required
    ok(new_text:find("required this.host", 1, true) ~= nil, "Edge Inc MutableConfig: host is required")
    ok(new_text:find("required this.port", 1, true) ~= nil, "Edge Inc MutableConfig: port is required")

    -- copyWith, toMap, etc. should work
    ok(new_text:find("copyWith({", 1, true) ~= nil, "Edge Inc MutableConfig: has copyWith")
    ok(new_text:find("host ?? this.host", 1, true) ~= nil, "Edge Inc MutableConfig: copyWith has host")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "MutableConfig")
  end
end

-- ===========================================================================
-- 4. Mixed final/non-final: MixedFields
-- ===========================================================================
do
  local text = [[class MixedFields {
  final String id;
  String name;
  final int count;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc MixedFields: parsed")
  if clazz then
    ok(not clazz:all_properties_final(), "Edge Inc MixedFields: not all_properties_final")

    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines)
    ok(edit_count > 0, "Edge Inc MixedFields: edits produced")

    -- Constructor NOT const
    ok(new_text:find("const MixedFields") == nil, "Edge Inc MixedFields: constructor NOT const")

    -- All three fields required (non-nullable)
    ok(new_text:find("required this.id", 1, true) ~= nil, "Edge Inc MixedFields: id required")
    ok(new_text:find("required this.name", 1, true) ~= nil, "Edge Inc MixedFields: name required")
    ok(new_text:find("required this.count", 1, true) ~= nil, "Edge Inc MixedFields: count required")

    -- toString has all 3 fields
    ok(new_text:find("id: $id", 1, true) ~= nil, "Edge Inc MixedFields: toString has id")
    ok(new_text:find("name: $name", 1, true) ~= nil, "Edge Inc MixedFields: toString has name")
    ok(new_text:find("count: $count", 1, true) ~= nil, "Edge Inc MixedFields: toString has count")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "MixedFields")
  end
end

-- ===========================================================================
-- 5. Existing constructor: WithConstructor (incremental adds other methods around it)
-- ===========================================================================
do
  local text = [[class WithConstructor {
  final String name;
  final int age;

  const WithConstructor({required this.name, required this.age});
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc WithConstructor: parsed")
  if clazz then
    ok(clazz:has_constructor(), "Edge Inc WithConstructor: has existing constructor")

    -- Block detection should find the existing constructor
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.constructor ~= nil, "Edge Inc WithConstructor: detected existing constructor")
    if blocks.constructor then
      eq(#blocks.constructor.fields, 2, "Edge Inc WithConstructor: constructor has 2 fields")
    end

    -- Generate all methods (constructor should be unchanged, others inserted)
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines)
    ok(edit_count > 0, "Edge Inc WithConstructor: edits produced for non-constructor methods")

    -- Original constructor should be preserved
    ok(new_text:find("const WithConstructor({", 1, true) ~= nil,
      "Edge Inc WithConstructor: constructor preserved")

    -- Other methods should be present
    ok(new_text:find("copyWith({", 1, true) ~= nil, "Edge Inc WithConstructor: has copyWith")
    ok(new_text:find("toMap()", 1, true) ~= nil, "Edge Inc WithConstructor: has toMap")
    ok(new_text:find("toString()", 1, true) ~= nil, "Edge Inc WithConstructor: has toString")
    ok(new_text:find("operator ==(", 1, true) ~= nil, "Edge Inc WithConstructor: has equality")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "WithConstructor")
  end
end

-- ===========================================================================
-- 6. Const constructor: all-final class gets const
-- ===========================================================================
do
  local text = [[class AllFinal {
  final String x;
  final int y;
  final bool z;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc AllFinal: parsed")
  if clazz then
    ok(clazz:all_properties_final(), "Edge Inc AllFinal: all_properties_final")

    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines)
    ok(edit_count > 0, "Edge Inc AllFinal: edits produced")

    -- Constructor should be const
    ok(new_text:find("const AllFinal({", 1, true) ~= nil, "Edge Inc AllFinal: constructor IS const")

    -- All fields required
    ok(new_text:find("required this.x", 1, true) ~= nil, "Edge Inc AllFinal: x required")
    ok(new_text:find("required this.y", 1, true) ~= nil, "Edge Inc AllFinal: y required")
    ok(new_text:find("required this.z", 1, true) ~= nil, "Edge Inc AllFinal: z required")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "AllFinal")
  end
end

-- ===========================================================================
-- 7. Default values config
-- ===========================================================================
do
  -- Enable default values
  local saved_config = vim.deepcopy(generator.config)
  generator.config.constructor_default_values = true

  local text = [[class WithDefaults {
  final String name;
  final int count;
  final bool active;
  final double price;
  final List<String> tags;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc WithDefaults: parsed")
  if clazz then
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines)
    ok(edit_count > 0, "Edge Inc WithDefaults: edits produced")

    -- With default values, non-nullable primitives get defaults instead of required
    ok(new_text:find('this.name = ', 1, true) ~= nil, "Edge Inc WithDefaults: name has default")
    ok(new_text:find('this.count = ', 1, true) ~= nil, "Edge Inc WithDefaults: count has default")
    ok(new_text:find('this.active = ', 1, true) ~= nil, "Edge Inc WithDefaults: active has default")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "WithDefaults")
  end

  -- Restore config
  generator.config = saved_config
end

-- ===========================================================================
-- 8. Collection types: Product (List<String> + Map<String, dynamic>)
-- ===========================================================================
do
  local text = [[class Product {
  final String title;
  final double price;
  final List<String> tags;
  final Map<String, dynamic> metadata;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc Product: parsed")
  if clazz then
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines)
    ok(edit_count > 0, "Edge Inc Product: edits produced")

    -- toMap should handle collections
    ok(new_text:find("'tags': tags", 1, true) ~= nil, "Edge Inc Product: toMap has tags")
    ok(new_text:find("'metadata': metadata", 1, true) ~= nil, "Edge Inc Product: toMap has metadata")

    -- fromMap should cast collections
    ok(new_text:find("fromMap(Map<String, dynamic>", 1, true) ~= nil,
      "Edge Inc Product: has fromMap factory")

    -- equality should use collection equality for List/Map
    -- (depends on Flutter detection, but at minimum should have equality operator)
    ok(new_text:find("operator ==(", 1, true) ~= nil, "Edge Inc Product: has equality")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "Product")
  end
end

-- ===========================================================================
-- 9. Enum fields in class: Order (Status enum + DateTime + List<Product>)
-- ===========================================================================
do
  local text = "enum Status { active, inactive, pending }\n\n" .. [[class Order {
  final String id;
  final Status status;
  final Status? previousStatus;
  final DateTime createdAt;
  final List<Product> items;
}
]]
  local clazzes = parser.parse_classes(text)
  local clazz
  for _, c in ipairs(clazzes) do
    if c.name == "Order" then clazz = c; break end
  end
  ok(clazz ~= nil, "Edge Inc Order: parsed")
  if clazz then
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines + 1] = line
    end

    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines)
    ok(edit_count > 0, "Edge Inc Order: edits produced")

    -- toMap: enums use .name
    ok(new_text:find("status.name", 1, true) ~= nil, "Edge Inc Order: toMap uses status.name")
    ok(new_text:find("previousStatus?.name", 1, true) ~= nil, "Edge Inc Order: toMap uses previousStatus?.name")

    -- toMap: DateTime uses toIso8601String
    ok(new_text:find("createdAt.toUtc().toIso8601String()", 1, true) ~= nil,
      "Edge Inc Order: toMap createdAt uses toIso8601String")

    -- fromMap: DateTime.parse
    ok(new_text:find("DateTime.parse", 1, true) ~= nil, "Edge Inc Order: fromMap uses DateTime.parse")

    -- Constructor: nullable enum not required
    ok(new_text:find("this.previousStatus,", 1, true) ~= nil,
      "Edge Inc Order: nullable previousStatus not required in constructor")
    ok(new_text:find("required this.status,", 1, true) ~= nil,
      "Edge Inc Order: non-nullable status is required")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "Order")
  end
end

-- ===========================================================================
-- 10. Generic class: Pair<A, B>
-- ===========================================================================
do
  local text = [[class Pair<A, B> {
  final A first;
  final B second;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc Pair: parsed")
  if clazz then
    ok(clazz:type_name():find("Pair<A", 1, true) ~= nil, "Edge Inc Pair: type_name has generics")

    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines)
    ok(edit_count > 0, "Edge Inc Pair: edits produced")

    -- copyWith should use Pair<A, B> return type
    ok(new_text:find("Pair<A", 1, true) ~= nil, "Edge Inc Pair: copyWith uses generic type")

    -- Constructor should have both fields
    ok(new_text:find("this.first", 1, true) ~= nil, "Edge Inc Pair: constructor has first")
    ok(new_text:find("this.second", 1, true) ~= nil, "Edge Inc Pair: constructor has second")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "Pair")
  end
end

-- ===========================================================================
-- 11. Single property: Wrapper (arrow form toString/hashCode)
-- ===========================================================================
do
  local text = [[class Wrapper {
  final String value;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc Wrapper: parsed")
  if clazz then
    ok(clazz:few_props(), "Edge Inc Wrapper: few_props")

    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines)
    ok(edit_count > 0, "Edge Inc Wrapper: edits produced")

    -- hashCode and toString should use arrow form for single prop
    -- (Detect => in the hashCode/toString blocks)
    local r_clazz, r_lines = parse_class_lines(new_text)
    if r_clazz then
      local r_blocks = incremental.detect_blocks(r_clazz, r_lines)
      if r_blocks.hashCode then
        ok(r_blocks.hashCode.text:find("=>", 1, true) ~= nil,
          "Edge Inc Wrapper: hashCode uses arrow form")
      end
      if r_blocks.toString then
        ok(r_blocks.toString.text:find("=>", 1, true) ~= nil,
          "Edge Inc Wrapper: toString uses arrow form")
      end
    end

    -- Idempotency
    verify_idempotent(new_lines, new_text, "Wrapper")
  end
end

-- ===========================================================================
-- 12. Large class (> 4 props): block form for toString/hashCode
-- ===========================================================================
do
  local text = [[class LargeClass {
  final String a;
  final String b;
  final String c;
  final String d;
  final String e;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc LargeClass: parsed")
  if clazz then
    ok(not clazz:few_props(), "Edge Inc LargeClass: NOT few_props")

    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines)
    ok(edit_count > 0, "Edge Inc LargeClass: edits produced")

    -- hashCode should use block form (> 4 props)
    ok(new_text:find("int get hashCode {", 1, true) ~= nil,
      "Edge Inc LargeClass: hashCode uses block form")

    -- toString should have all 5 fields
    ok(new_text:find("a: $a", 1, true) ~= nil, "Edge Inc LargeClass: toString has a")
    ok(new_text:find("e: $e", 1, true) ~= nil, "Edge Inc LargeClass: toString has e")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "LargeClass")
  end
end

-- ===========================================================================
-- 13. DateTime fields: Event (non-nullable + nullable DateTime)
-- ===========================================================================
do
  local text = [[class Event {
  final String title;
  final DateTime startTime;
  final DateTime? endTime;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc Event: parsed")
  if clazz then
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines)
    ok(edit_count > 0, "Edge Inc Event: edits produced")

    -- toMap: non-nullable DateTime
    ok(new_text:find("startTime.toUtc().toIso8601String()", 1, true) ~= nil,
      "Edge Inc Event: toMap startTime")
    -- toMap: nullable DateTime
    ok(new_text:find("endTime?.toUtc().toIso8601String()", 1, true) ~= nil,
      "Edge Inc Event: toMap endTime nullable")

    -- fromMap: DateTime.parse
    ok(new_text:find("DateTime.parse", 1, true) ~= nil, "Edge Inc Event: fromMap uses DateTime.parse")

    -- Constructor: endTime nullable, not required
    ok(new_text:find("this.endTime,", 1, true) ~= nil, "Edge Inc Event: endTime not required")
    ok(new_text:find("required this.startTime", 1, true) ~= nil, "Edge Inc Event: startTime required")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "Event")
  end
end

-- ===========================================================================
-- 14. Incremental update with nullable field added
-- ===========================================================================
do
  -- Start with class that has name and age
  local text = [[class Growing {
  final String name;
  final int age;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc Growing: parsed")
  if clazz then
    -- Generate all
    local new_lines, new_text, _ = generate_all_incremental(clazz, lines)

    -- Now add a nullable field
    local updated_lines = {}
    for i, l in ipairs(new_lines) do
      updated_lines[#updated_lines + 1] = l
      if l:find("final int age;", 1, true) then
        updated_lines[#updated_lines + 1] = "  final String? email;"
      end
    end
    local updated_text = table.concat(updated_lines, "\n")

    local u_clazz
    for _, c in ipairs(parser.parse_classes(updated_text)) do
      if c.name == "Growing" then u_clazz = c; break end
    end
    ok(u_clazz ~= nil, "Edge Inc Growing: re-parsed after adding email")

    if u_clazz then
      eq(#u_clazz:gen_properties(), 3, "Edge Inc Growing: now 3 fields")

      local u_blocks = incremental.detect_blocks(u_clazz, updated_lines)
      local field_names = incremental.get_class_field_names(u_clazz)

      -- Constructor should be incomplete
      eq(incremental.block_status(u_blocks.constructor, field_names), "incomplete",
        "Edge Inc Growing: constructor incomplete after adding email")

      -- All field-tracked blocks should be incomplete
      eq(incremental.block_status(u_blocks.copyWith, field_names), "incomplete",
        "Edge Inc Growing: copyWith incomplete")
      eq(incremental.block_status(u_blocks.toMap, field_names), "incomplete",
        "Edge Inc Growing: toMap incomplete")
      eq(incremental.block_status(u_blocks.toString, field_names), "incomplete",
        "Edge Inc Growing: toString incomplete")
      eq(incremental.block_status(u_blocks.equality, field_names), "incomplete",
        "Edge Inc Growing: equality incomplete")
      eq(incremental.block_status(u_blocks.hashCode, field_names), "incomplete",
        "Edge Inc Growing: hashCode incomplete")

      -- Regenerate all → should produce edits
      local final_lines, final_text, final_edits = generate_all_incremental(u_clazz, updated_lines)
      ok(final_edits > 0, "Edge Inc Growing: update edits produced")

      -- email should now be in constructor (nullable, not required)
      ok(final_text:find("this.email,", 1, true) ~= nil, "Edge Inc Growing: email in constructor")
      ok(final_text:find("required this.email") == nil, "Edge Inc Growing: email NOT required (nullable)")

      -- email in toString
      ok(final_text:find("email: $email", 1, true) ~= nil, "Edge Inc Growing: email in toString")

      -- email in equality
      ok(final_text:find("other.email == email", 1, true) ~= nil, "Edge Inc Growing: email in equality")

      -- email in hashCode
      ok(final_text:find("email.hashCode", 1, true) ~= nil, "Edge Inc Growing: email in hashCode")

      -- Idempotency after update
      verify_idempotent(final_lines, final_text, "Growing")
    end
  end
end

-- ===========================================================================
-- 15. Abstract class: only constructor + toString + equality + hashCode (no copyWith/serialization)
-- ===========================================================================
do
  local text = [[abstract class Animal {
  final String name;
  final int age;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc Animal: parsed")
  if clazz then
    ok(clazz:is_abstract(), "Edge Inc Animal: is_abstract")

    -- Only generate applicable kinds for abstract class
    local kinds = { "constructor", "toString", "equality", "hashCode" }
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines, kinds)
    ok(edit_count > 0, "Edge Inc Animal: edits produced")

    ok(new_text:find("Animal({", 1, true) ~= nil, "Edge Inc Animal: has constructor")
    ok(new_text:find("toString()", 1, true) ~= nil, "Edge Inc Animal: has toString")
    ok(new_text:find("operator ==(", 1, true) ~= nil, "Edge Inc Animal: has equality")
    ok(new_text:find("hashCode", 1, true) ~= nil, "Edge Inc Animal: has hashCode")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "Animal", kinds)
  end
end

-- ===========================================================================
-- 16. Sealed class: constructor + toString + equality + hashCode only
-- ===========================================================================
do
  local text = [[sealed class Shape {
  final String color;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc Shape: parsed")
  if clazz then
    ok(clazz:is_sealed(), "Edge Inc Shape: is_sealed")

    local kinds = { "constructor", "toString", "equality", "hashCode" }
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines, kinds)
    ok(edit_count > 0, "Edge Inc Shape: edits produced")

    ok(new_text:find("const Shape({", 1, true) ~= nil, "Edge Inc Shape: has const constructor")
    ok(new_text:find("toString()", 1, true) ~= nil, "Edge Inc Shape: has toString")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "Shape", kinds)
  end
end

-- ===========================================================================
-- 17. Cross-action safety with nullable + non-nullable mixed
-- ===========================================================================
do
  local text = [[class CrossSafe {
  final String name;
  final int? optionalAge;
  final List<String> items;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc CrossSafe: parsed")
  if clazz then
    -- Step 1: generate constructor only
    local blocks = incremental.detect_blocks(clazz, lines)
    local constr_text = generator.generate_constructor(clazz)
    local edit1 = incremental.build_edit("constructor", clazz, blocks, constr_text)
    ok(edit1 ~= nil, "Edge Inc CrossSafe: constructor edit produced")
    if edit1 then
      lines = incremental.apply_edits(lines, { edit1 })
      local text_after = table.concat(lines, "\n")

      -- Verify constructor has all 3 fields
      ok(text_after:find("required this.name", 1, true) ~= nil, "Edge Inc CrossSafe: constructor has name (required)")
      ok(text_after:find("this.optionalAge,", 1, true) ~= nil, "Edge Inc CrossSafe: constructor has optionalAge (not required)")
      ok(text_after:find("required this.items", 1, true) ~= nil, "Edge Inc CrossSafe: constructor has items (required)")

      -- Step 2: generate toMap
      local clazz2 = parser.parse_classes(text_after)[1]
      if clazz2 then
        local blocks2 = incremental.detect_blocks(clazz2, lines)
        ok(blocks2.constructor ~= nil, "Edge Inc CrossSafe: constructor preserved after re-parse")

        local tomap_text = generator.generate_to_map(clazz2)
        local edit2 = incremental.build_edit("toMap", clazz2, blocks2, tomap_text)
        ok(edit2 ~= nil, "Edge Inc CrossSafe: toMap edit produced")
        if edit2 then
          lines = incremental.apply_edits(lines, { edit2 })
          local final_text = table.concat(lines, "\n")

          -- Constructor still intact
          ok(final_text:find("required this.name", 1, true) ~= nil,
            "Edge Inc CrossSafe: constructor still has name after toMap")
          -- toMap present
          ok(final_text:find("'name': name", 1, true) ~= nil, "Edge Inc CrossSafe: toMap has name")
          ok(final_text:find("'items': items", 1, true) ~= nil, "Edge Inc CrossSafe: toMap has items")
        end
      end
    end
  end
end

-- ===========================================================================
-- 18. Incremental update with field removal detection
-- ===========================================================================
do
  -- Start with 3 fields, generate all, then remove one field
  local text = [[class Shrinking {
  final String a;
  final int b;
  final bool c;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc Shrinking: parsed")
  if clazz then
    local new_lines, new_text, _ = generate_all_incremental(clazz, lines)

    -- Remove field 'b' from source
    local trimmed_lines = {}
    for _, l in ipairs(new_lines) do
      if not l:find("final int b;", 1, true) then
        trimmed_lines[#trimmed_lines + 1] = l
      end
    end
    local trimmed_text = table.concat(trimmed_lines, "\n")

    local t_clazz
    for _, c in ipairs(parser.parse_classes(trimmed_text)) do
      if c.name == "Shrinking" then t_clazz = c; break end
    end
    ok(t_clazz ~= nil, "Edge Inc Shrinking: re-parsed after removing b")

    if t_clazz then
      eq(#t_clazz:gen_properties(), 2, "Edge Inc Shrinking: now 2 fields")

      -- Regenerate → should produce edits (methods still reference 'b')
      local final_lines, final_text, final_edits = generate_all_incremental(t_clazz, trimmed_lines)
      ok(final_edits > 0, "Edge Inc Shrinking: update edits produced after field removal")

      -- 'b' should no longer be in generated methods
      -- (check constructor - should only have a and c)
      local f_clazz = parser.parse_classes(final_text)[1]
      if f_clazz then
        local f_blocks = incremental.detect_blocks(f_clazz, final_lines)
        if f_blocks.constructor then
          local c_fields = f_blocks.constructor.fields
          local has_b = false
          for _, f in ipairs(c_fields) do
            if f == "b" then has_b = true end
          end
          ok(not has_b, "Edge Inc Shrinking: constructor no longer has field b")
        end
      end

      -- Idempotency after field removal
      verify_idempotent(final_lines, final_text, "Shrinking")
    end
  end
end

-- ===========================================================================
-- 19. snake_case JSON key format
-- ===========================================================================
do
  local saved_config = vim.deepcopy(generator.config)
  generator.config.json_key_format = "snake_case"

  local text = [[class SnakeCase {
  final String firstName;
  final int createdAt;
  final bool isActive;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc SnakeCase: parsed")
  if clazz then
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines)
    ok(edit_count > 0, "Edge Inc SnakeCase: edits produced")

    -- toMap should use snake_case keys
    ok(new_text:find("'first_name':", 1, true) ~= nil, "Edge Inc SnakeCase: toMap has first_name key")
    ok(new_text:find("'created_at':", 1, true) ~= nil, "Edge Inc SnakeCase: toMap has created_at key")
    ok(new_text:find("'is_active':", 1, true) ~= nil, "Edge Inc SnakeCase: toMap has is_active key")

    -- fromMap should also use snake_case keys
    ok(new_text:find("map['first_name']", 1, true) ~= nil, "Edge Inc SnakeCase: fromMap has first_name key")
    ok(new_text:find("map['created_at']", 1, true) ~= nil, "Edge Inc SnakeCase: fromMap has created_at key")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "SnakeCase")
  end

  generator.config = saved_config
end

-- ===========================================================================
-- 20. Nested custom type: Comment (User author, User? replyTo)
-- ===========================================================================
do
  local text = [[class Comment {
  final String text;
  final User author;
  final User? replyTo;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge Inc Comment: parsed")
  if clazz then
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines)
    ok(edit_count > 0, "Edge Inc Comment: edits produced")

    -- toMap: custom types use .toMap()
    ok(new_text:find("author.toMap()", 1, true) ~= nil, "Edge Inc Comment: toMap author.toMap()")
    ok(new_text:find("replyTo?.toMap()", 1, true) ~= nil, "Edge Inc Comment: toMap replyTo?.toMap()")

    -- fromMap: custom type from map
    ok(new_text:find("User.fromMap", 1, true) ~= nil, "Edge Inc Comment: fromMap User.fromMap")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "Comment")
  end
end

-- ===========================================================================
-- 21. Subclass: Dog extends Animal (should allow copyWith/serialization)
-- ===========================================================================
do
  local text = [[abstract class Animal {
  final String name;
  final int age;
}

class Dog extends Animal {
  final String breed;
}
]]
  local clazzes = parser.parse_classes(text)
  local dog_clazz
  for _, c in ipairs(clazzes) do
    if c.name == "Dog" then dog_clazz = c; break end
  end
  ok(dog_clazz ~= nil, "Edge Inc Dog: parsed")
  if dog_clazz then
    ok(dog_clazz:has_superclass(), "Edge Inc Dog: has superclass")

    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines + 1] = line
    end

    local new_lines, new_text, edit_count = generate_all_incremental(dog_clazz, lines)
    ok(edit_count > 0, "Edge Inc Dog: edits produced")

    -- Should have copyWith and serialization methods
    ok(new_text:find("copyWith({", 1, true) ~= nil, "Edge Inc Dog: has copyWith")
    ok(new_text:find("toMap()", 1, true) ~= nil, "Edge Inc Dog: has toMap")
    ok(new_text:find("this.breed", 1, true) ~= nil, "Edge Inc Dog: constructor has breed")

    -- Idempotency
    verify_idempotent(new_lines, new_text, "Dog")
  end
end

-- ===========================================================================
-- 22. CROSS-CLASS CONTAMINATION: Two classes in one buffer
--     Generate data class for User, then for Product — verify no cross-leak
-- ===========================================================================
io.write("\n=== Cross-Class Contamination Tests ===\n")
do
  local text = [[class User {
  final String name;
  final int age;
}

class Product {
  final String title;
  final double price;
}
]]

  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local clazzes = parser.parse_classes(text)
  local user_clazz, product_clazz
  for _, c in ipairs(clazzes) do
    if c.name == "User" then user_clazz = c end
    if c.name == "Product" then product_clazz = c end
  end

  ok(user_clazz ~= nil, "CrossClass: User parsed")
  ok(product_clazz ~= nil, "CrossClass: Product parsed")

  if user_clazz and product_clazz then
    -- Step 1: Generate all methods for User
    local user_new_lines, user_new_text, user_edit_count = generate_all_incremental(user_clazz, lines)
    ok(user_edit_count > 0, "CrossClass: User edits produced")

    -- Verify User output references only User fields
    -- Find User class boundaries in the new text
    local user_re_clazzes = parser.parse_classes(user_new_text)
    local user_after
    for _, c in ipairs(user_re_clazzes) do
      if c.name == "User" then user_after = c; break end
    end
    ok(user_after ~= nil, "CrossClass: User re-parsed after generation")

    if user_after then
      -- User class should have name and age but NOT title or price
      local user_class_text = table.concat(user_new_lines, "\n",
        user_after.starts_at_line, user_after.ends_at_line)
      ok(user_class_text:find("this.name", 1, true) ~= nil, "CrossClass: User constructor has name")
      ok(user_class_text:find("this.age", 1, true) ~= nil, "CrossClass: User constructor has age")
      ok(user_class_text:find("this.title", 1, true) == nil, "CrossClass: User does NOT have title")
      ok(user_class_text:find("this.price", 1, true) == nil, "CrossClass: User does NOT have price")
      ok(user_class_text:find("'name'", 1, true) ~= nil, "CrossClass: User toMap has 'name'")
      ok(user_class_text:find("'age'", 1, true) ~= nil, "CrossClass: User toMap has 'age'")
      ok(user_class_text:find("'title'", 1, true) == nil, "CrossClass: User toMap does NOT have 'title'")
      ok(user_class_text:find("'price'", 1, true) == nil, "CrossClass: User toMap does NOT have 'price'")
    end

    -- Step 2: Now generate all methods for Product on the updated buffer
    -- Re-parse the buffer to find Product's new line positions
    local product_after
    for _, c in ipairs(user_re_clazzes) do
      if c.name == "Product" then product_after = c; break end
    end
    ok(product_after ~= nil, "CrossClass: Product re-parsed after User generation")

    if product_after then
      local final_lines, final_text, product_edit_count = generate_all_incremental(product_after, user_new_lines)
      ok(product_edit_count > 0, "CrossClass: Product edits produced")

      -- Re-parse to verify both classes
      local final_clazzes = parser.parse_classes(final_text)
      local final_user, final_product
      for _, c in ipairs(final_clazzes) do
        if c.name == "User" then final_user = c end
        if c.name == "Product" then final_product = c end
      end

      ok(final_user ~= nil, "CrossClass: final User parsed")
      ok(final_product ~= nil, "CrossClass: final Product parsed")

      if final_user and final_product then
        -- Extract text for each class
        local final_user_text = table.concat(final_lines, "\n",
          final_user.starts_at_line, final_user.ends_at_line)
        local final_product_text = table.concat(final_lines, "\n",
          final_product.starts_at_line, final_product.ends_at_line)

        -- User's methods should STILL only reference User fields
        ok(final_user_text:find("this.name", 1, true) ~= nil, "CrossClass Final: User has name")
        ok(final_user_text:find("this.age", 1, true) ~= nil, "CrossClass Final: User has age")
        ok(final_user_text:find("this.title", 1, true) == nil, "CrossClass Final: User NOT have title")
        ok(final_user_text:find("this.price", 1, true) == nil, "CrossClass Final: User NOT have price")

        -- Product's methods should only reference Product fields
        ok(final_product_text:find("this.title", 1, true) ~= nil, "CrossClass Final: Product has title")
        ok(final_product_text:find("this.price", 1, true) ~= nil, "CrossClass Final: Product has price")
        ok(final_product_text:find("this.name", 1, true) == nil, "CrossClass Final: Product NOT have name")
        ok(final_product_text:find("this.age", 1, true) == nil, "CrossClass Final: Product NOT have age")

        -- Product toMap/fromMap should use Product fields only
        ok(final_product_text:find("'title'", 1, true) ~= nil, "CrossClass Final: Product toMap 'title'")
        ok(final_product_text:find("'price'", 1, true) ~= nil, "CrossClass Final: Product toMap 'price'")
        ok(final_product_text:find("'name'", 1, true) == nil, "CrossClass Final: Product toMap NOT 'name'")
        ok(final_product_text:find("'age'", 1, true) == nil, "CrossClass Final: Product toMap NOT 'age'")

        -- User toMap should still have User fields
        ok(final_user_text:find("'name'", 1, true) ~= nil, "CrossClass Final: User toMap 'name'")
        ok(final_user_text:find("'age'", 1, true) ~= nil, "CrossClass Final: User toMap 'age'")

        -- toString checks
        ok(final_user_text:find("User(", 1, true) ~= nil, "CrossClass Final: User toString says User(")
        ok(final_product_text:find("Product(", 1, true) ~= nil, "CrossClass Final: Product toString says Product(")
        ok(final_user_text:find("Product(", 1, true) == nil, "CrossClass Final: User toString NOT Product(")
        ok(final_product_text:find("User(", 1, true) == nil, "CrossClass Final: Product toString NOT User(")

        -- equality: User uses 'other is User', Product uses 'other is Product'
        ok(final_user_text:find("other is User", 1, true) ~= nil or
           final_user_text:find("is! User", 1, true) ~= nil,
           "CrossClass Final: User equality type check")
        ok(final_product_text:find("other is Product", 1, true) ~= nil or
           final_product_text:find("is! Product", 1, true) ~= nil,
           "CrossClass Final: Product equality type check")

        -- copyWith return types
        ok(final_user_text:find("User copyWith(", 1, true) ~= nil, "CrossClass Final: User copyWith returns User")
        ok(final_product_text:find("Product copyWith(", 1, true) ~= nil, "CrossClass Final: Product copyWith returns Product")

        -- fromMap factory uses correct class name
        ok(final_user_text:find("User.fromMap(", 1, true) ~= nil, "CrossClass Final: User.fromMap factory")
        ok(final_product_text:find("Product.fromMap(", 1, true) ~= nil, "CrossClass Final: Product.fromMap factory")

        -- fromJson factory uses correct class name
        ok(final_user_text:find("User.fromJson(", 1, true) ~= nil, "CrossClass Final: User.fromJson factory")
        ok(final_product_text:find("Product.fromJson(", 1, true) ~= nil, "CrossClass Final: Product.fromJson factory")

        -- Idempotency for both classes after both are generated
        verify_idempotent(final_lines, final_text, "User")
        verify_idempotent(final_lines, final_text, "Product")
      end
    end
  end
end

-- ===========================================================================
-- 23. CROSS-CLASS: Three classes, generate in reverse order
-- ===========================================================================
do
  local text = [[class Alpha {
  final String a1;
  final int a2;
}

class Beta {
  final String b1;
  final bool b2;
}

class Gamma {
  final double g1;
  final List<String> g2;
}
]]

  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local clazzes = parser.parse_classes(text)
  -- Collect them by name
  local by_name = {}
  for _, c in ipairs(clazzes) do by_name[c.name] = c end

  ok(by_name.Alpha ~= nil, "CrossClass3: Alpha parsed")
  ok(by_name.Beta ~= nil, "CrossClass3: Beta parsed")
  ok(by_name.Gamma ~= nil, "CrossClass3: Gamma parsed")

  if by_name.Alpha and by_name.Beta and by_name.Gamma then
    -- Generate in REVERSE order: Gamma first, then Beta, then Alpha
    -- This tests that inserting into a later class doesn't corrupt earlier ones

    -- Step 1: Generate Gamma
    local l1, t1, e1 = generate_all_incremental(by_name.Gamma, lines)
    ok(e1 > 0, "CrossClass3: Gamma edits produced")

    -- Re-parse to find Beta at its new position
    local c1 = parser.parse_classes(t1)
    local beta_1
    for _, c in ipairs(c1) do if c.name == "Beta" then beta_1 = c; break end end
    ok(beta_1 ~= nil, "CrossClass3: Beta re-parsed after Gamma")

    -- Step 2: Generate Beta
    local l2, t2, e2 = generate_all_incremental(beta_1, l1)
    ok(e2 > 0, "CrossClass3: Beta edits produced")

    -- Re-parse to find Alpha at its new position
    local c2 = parser.parse_classes(t2)
    local alpha_2
    for _, c in ipairs(c2) do if c.name == "Alpha" then alpha_2 = c; break end end
    ok(alpha_2 ~= nil, "CrossClass3: Alpha re-parsed after Beta")

    -- Step 3: Generate Alpha
    local l3, t3, e3 = generate_all_incremental(alpha_2, l2)
    ok(e3 > 0, "CrossClass3: Alpha edits produced")

    -- Final verification
    local final_clazzes = parser.parse_classes(t3)
    local fa, fb, fg
    for _, c in ipairs(final_clazzes) do
      if c.name == "Alpha" then fa = c end
      if c.name == "Beta" then fb = c end
      if c.name == "Gamma" then fg = c end
    end

    ok(fa ~= nil, "CrossClass3 Final: Alpha parsed")
    ok(fb ~= nil, "CrossClass3 Final: Beta parsed")
    ok(fg ~= nil, "CrossClass3 Final: Gamma parsed")

    if fa and fb and fg then
      local fa_text = table.concat(l3, "\n", fa.starts_at_line, fa.ends_at_line)
      local fb_text = table.concat(l3, "\n", fb.starts_at_line, fb.ends_at_line)
      local fg_text = table.concat(l3, "\n", fg.starts_at_line, fg.ends_at_line)

      -- Alpha should have a1, a2 only
      ok(fa_text:find("this.a1", 1, true) ~= nil, "CrossClass3 Final: Alpha has a1")
      ok(fa_text:find("this.a2", 1, true) ~= nil, "CrossClass3 Final: Alpha has a2")
      ok(fa_text:find("this.b1", 1, true) == nil, "CrossClass3 Final: Alpha NOT b1")
      ok(fa_text:find("this.g1", 1, true) == nil, "CrossClass3 Final: Alpha NOT g1")

      -- Beta should have b1, b2 only
      ok(fb_text:find("this.b1", 1, true) ~= nil, "CrossClass3 Final: Beta has b1")
      ok(fb_text:find("this.b2", 1, true) ~= nil, "CrossClass3 Final: Beta has b2")
      ok(fb_text:find("this.a1", 1, true) == nil, "CrossClass3 Final: Beta NOT a1")
      ok(fb_text:find("this.g1", 1, true) == nil, "CrossClass3 Final: Beta NOT g1")

      -- Gamma should have g1, g2 only
      ok(fg_text:find("this.g1", 1, true) ~= nil, "CrossClass3 Final: Gamma has g1")
      ok(fg_text:find("this.g2", 1, true) ~= nil, "CrossClass3 Final: Gamma has g2")
      ok(fg_text:find("this.a1", 1, true) == nil, "CrossClass3 Final: Gamma NOT a1")
      ok(fg_text:find("this.b1", 1, true) == nil, "CrossClass3 Final: Gamma NOT b1")

      -- toString class names
      ok(fa_text:find("Alpha(", 1, true) ~= nil, "CrossClass3 Final: Alpha toString")
      ok(fb_text:find("Beta(", 1, true) ~= nil, "CrossClass3 Final: Beta toString")
      ok(fg_text:find("Gamma(", 1, true) ~= nil, "CrossClass3 Final: Gamma toString")

      -- Idempotency for all three
      verify_idempotent(l3, t3, "Alpha")
      verify_idempotent(l3, t3, "Beta")
      verify_idempotent(l3, t3, "Gamma")
    end
  end
end

-- ===========================================================================
-- 24. CROSS-CLASS: Simulating actions.apply_incremental flow
--     This mirrors the actual Neovim usage: parse full buffer, find class,
--     generate all for that class, update buffer, repeat for next class.
-- ===========================================================================
do
  local text = [[class Person {
  final String firstName;
  final String lastName;
  final int age;
}

class Address {
  final String street;
  final String city;
  final String zip;
}
]]

  -- Simulate a fake vim buffer (like actions.apply_incremental does)
  local buf_lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    buf_lines[#buf_lines + 1] = line
  end

  -- Simulate: user triggers "Generate data class" on Person
  local clazzes1 = parser.parse_classes(table.concat(buf_lines, "\n"))
  local person1 = parser.find_class_at_line(clazzes1, 1)
  ok(person1 ~= nil, "CrossClassSim: Person found at line 1")

  if person1 then
    local blocks1 = incremental.detect_blocks(person1, buf_lines)
    local edits1 = {}
    local all_kinds = { "constructor", "copyWith", "toMap", "fromMap", "toJson", "fromJson", "toString", "equality", "hashCode" }
    for _, kind in ipairs(all_kinds) do
      local gen_text
      if kind == "constructor" then
        gen_text = generator.generate_constructor(person1)
      elseif kind == "copyWith" then
        gen_text = (generator.generate_copy_with(person1))
      elseif kind == "toMap" then
        gen_text = generator.generate_to_map(person1)
      elseif kind == "fromMap" then
        gen_text = (generator.generate_from_map(person1))
      elseif kind == "toJson" then
        gen_text = (generator.generate_to_json(person1))
      elseif kind == "fromJson" then
        gen_text = (generator.generate_from_json(person1))
      elseif kind == "toString" then
        gen_text = generator.generate_to_string(person1)
      elseif kind == "equality" then
        gen_text = (generator.generate_equality(person1))
      elseif kind == "hashCode" then
        gen_text = (generator.generate_hash_code(person1))
      end
      if gen_text then
        local edit = incremental.build_edit(kind, person1, blocks1, gen_text)
        if edit then edits1[#edits1 + 1] = edit end
      end
    end
    buf_lines = incremental.apply_edits(buf_lines, edits1)
    ok(#edits1 > 0, "CrossClassSim: Person edits produced")

    -- Now simulate: user triggers "Generate data class" on Address
    -- Re-parse the entire buffer (just like apply_incremental does)
    local buf_text = table.concat(buf_lines, "\n")
    local clazzes2 = parser.parse_classes(buf_text)

    -- Find Address. It was originally at line ~7, but Person has grown.
    -- We need to find it by name now (like the actual code does via find_class_at_line
    -- with the original starts_at_line from the action).
    local address2
    for _, c in ipairs(clazzes2) do
      if c.name == "Address" then address2 = c; break end
    end
    ok(address2 ~= nil, "CrossClassSim: Address found after Person generation")

    if address2 then
      local blocks2 = incremental.detect_blocks(address2, buf_lines)
      local edits2 = {}
      for _, kind in ipairs(all_kinds) do
        local gen_text
        if kind == "constructor" then
          gen_text = generator.generate_constructor(address2)
        elseif kind == "copyWith" then
          gen_text = (generator.generate_copy_with(address2))
        elseif kind == "toMap" then
          gen_text = generator.generate_to_map(address2)
        elseif kind == "fromMap" then
          gen_text = (generator.generate_from_map(address2))
        elseif kind == "toJson" then
          gen_text = (generator.generate_to_json(address2))
        elseif kind == "fromJson" then
          gen_text = (generator.generate_from_json(address2))
        elseif kind == "toString" then
          gen_text = generator.generate_to_string(address2)
        elseif kind == "equality" then
          gen_text = (generator.generate_equality(address2))
        elseif kind == "hashCode" then
          gen_text = (generator.generate_hash_code(address2))
        end
        if gen_text then
          local edit = incremental.build_edit(kind, address2, blocks2, gen_text)
          if edit then edits2[#edits2 + 1] = edit end
        end
      end
      buf_lines = incremental.apply_edits(buf_lines, edits2)
      ok(#edits2 > 0, "CrossClassSim: Address edits produced")

      -- Final verification
      local final_text = table.concat(buf_lines, "\n")
      local final_clazzes = parser.parse_classes(final_text)
      local fp, fa
      for _, c in ipairs(final_clazzes) do
        if c.name == "Person" then fp = c end
        if c.name == "Address" then fa = c end
      end

      ok(fp ~= nil, "CrossClassSim Final: Person parsed")
      ok(fa ~= nil, "CrossClassSim Final: Address parsed")

      if fp and fa then
        local fp_text = table.concat(buf_lines, "\n", fp.starts_at_line, fp.ends_at_line)
        local fa_text = table.concat(buf_lines, "\n", fa.starts_at_line, fa.ends_at_line)

        -- Person fields
        ok(fp_text:find("this.firstName", 1, true) ~= nil, "CrossClassSim Final: Person has firstName")
        ok(fp_text:find("this.lastName", 1, true) ~= nil, "CrossClassSim Final: Person has lastName")
        ok(fp_text:find("this.age", 1, true) ~= nil, "CrossClassSim Final: Person has age")

        -- Person does NOT have Address fields
        ok(fp_text:find("this.street", 1, true) == nil, "CrossClassSim Final: Person NOT street")
        ok(fp_text:find("this.city", 1, true) == nil, "CrossClassSim Final: Person NOT city")
        ok(fp_text:find("this.zip", 1, true) == nil, "CrossClassSim Final: Person NOT zip")

        -- Address fields
        ok(fa_text:find("this.street", 1, true) ~= nil, "CrossClassSim Final: Address has street")
        ok(fa_text:find("this.city", 1, true) ~= nil, "CrossClassSim Final: Address has city")
        ok(fa_text:find("this.zip", 1, true) ~= nil, "CrossClassSim Final: Address has zip")

        -- Address does NOT have Person fields
        ok(fa_text:find("this.firstName", 1, true) == nil, "CrossClassSim Final: Address NOT firstName")
        ok(fa_text:find("this.lastName", 1, true) == nil, "CrossClassSim Final: Address NOT lastName")
        ok(fa_text:find("this.age", 1, true) == nil, "CrossClassSim Final: Address NOT age")

        -- Class names in toString
        ok(fp_text:find("Person(", 1, true) ~= nil, "CrossClassSim Final: Person toString")
        ok(fa_text:find("Address(", 1, true) ~= nil, "CrossClassSim Final: Address toString")

        -- toMap keys
        ok(fp_text:find("'firstName'", 1, true) ~= nil or fp_text:find("'first_name'", 1, true) ~= nil,
          "CrossClassSim Final: Person toMap firstName key")
        ok(fa_text:find("'street'", 1, true) ~= nil, "CrossClassSim Final: Address toMap street key")
        ok(fa_text:find("'firstName'", 1, true) == nil and fa_text:find("'first_name'", 1, true) == nil,
          "CrossClassSim Final: Address toMap NOT firstName key")

        -- Equality type checks
        ok(fp_text:find("is Person", 1, true) ~= nil or fp_text:find("is! Person", 1, true) ~= nil,
          "CrossClassSim Final: Person equality check")
        ok(fa_text:find("is Address", 1, true) ~= nil or fa_text:find("is! Address", 1, true) ~= nil,
          "CrossClassSim Final: Address equality check")

        -- Idempotency
        verify_idempotent(buf_lines, final_text, "Person")
        verify_idempotent(buf_lines, final_text, "Address")

        -- Print the final output for debugging if needed
        -- io.write("\n--- FINAL OUTPUT ---\n" .. final_text .. "\n--- END ---\n")
      end
    end
  end
end

-- ===========================================================================
-- 25. FULL ACTIONS INTEGRATION: Simulate actions.apply_incremental with
--     fake vim.api buffer to test the exact code path used in Neovim.
-- ===========================================================================
io.write("\n=== Full Actions Integration Tests (simulated vim.api) ===\n")
do
  local actions_mod = require("dart-class-tools.actions")

  -- Create a fake buffer that mimics vim.api behavior
  local function make_fake_buffer(initial_text)
    local buf_lines = {}
    for line in (initial_text .. "\n"):gmatch("([^\n]*)\n") do
      buf_lines[#buf_lines + 1] = line
    end

    local bufnr = 999 -- fake buffer number
    local notifications = {}

    -- Install fake vim.api functions
    vim.api = vim.api or {}
    vim.notify = function(msg, level)
      notifications[#notifications + 1] = { msg = msg, level = level }
    end

    vim.api.nvim_buf_line_count = function(b)
      if b == bufnr then return #buf_lines end
      return 0
    end

    vim.api.nvim_buf_get_lines = function(b, start_idx, end_idx, strict)
      if b ~= bufnr then return {} end
      local result = {}
      -- 0-indexed API: start_idx is inclusive, end_idx is exclusive
      for i = start_idx + 1, end_idx do
        result[#result + 1] = buf_lines[i] or ""
      end
      return result
    end

    vim.api.nvim_buf_set_lines = function(b, start_idx, end_idx, strict, replacement)
      if b ~= bufnr then return end
      -- 0-indexed API: remove lines from start_idx to end_idx-1, insert replacement
      local new_buf = {}
      for i = 1, start_idx do
        new_buf[#new_buf + 1] = buf_lines[i]
      end
      for _, l in ipairs(replacement) do
        new_buf[#new_buf + 1] = l
      end
      for i = end_idx + 1, #buf_lines do
        new_buf[#new_buf + 1] = buf_lines[i]
      end
      buf_lines = new_buf
    end

    return bufnr, buf_lines, notifications, function() return buf_lines end
  end

  -- Test: Two classes, generate data class for each sequentially
  local initial_text = [[class User {
  final String name;
  final int age;
}

class Product {
  final String title;
  final double price;
}]]

  local bufnr, _, notifications, get_buf = make_fake_buffer(initial_text)

  -- Step 1: Get code actions for User (line 1)
  local user_actions = actions_mod.get_code_actions(bufnr, 1)
  ok(#user_actions > 0, "ActionsInteg: User has code actions")

  -- Find the data class action
  local user_dc_action
  for _, a in ipairs(user_actions) do
    if a.title:find("data class", 1, true) then
      user_dc_action = a
      break
    end
  end
  ok(user_dc_action ~= nil, "ActionsInteg: User has data class action")

  if user_dc_action then
    -- Execute it
    actions_mod.execute_action(user_dc_action)

    local buf_after_user = get_buf()
    local text_after_user = table.concat(buf_after_user, "\n")

    -- Verify User was generated
    ok(text_after_user:find("this.name", 1, true) ~= nil, "ActionsInteg: User generated - has this.name")
    ok(text_after_user:find("this.age", 1, true) ~= nil, "ActionsInteg: User generated - has this.age")

    -- Step 2: Now get code actions for Product (need to find its new line)
    local product_line
    for i, l in ipairs(buf_after_user) do
      if l:match("^class Product") then
        product_line = i
        break
      end
    end
    ok(product_line ~= nil, "ActionsInteg: Product class line found")

    if product_line then
      local product_actions = actions_mod.get_code_actions(bufnr, product_line)
      ok(#product_actions > 0, "ActionsInteg: Product has code actions")

      local product_dc_action
      for _, a in ipairs(product_actions) do
        if a.title:find("data class", 1, true) then
          product_dc_action = a
          break
        end
      end
      ok(product_dc_action ~= nil, "ActionsInteg: Product has data class action")

      if product_dc_action then
        -- Execute it
        actions_mod.execute_action(product_dc_action)

        local buf_final = get_buf()
        local text_final = table.concat(buf_final, "\n")

        -- Re-parse to get class boundaries
        local final_clazzes = parser.parse_classes(text_final)
        local fu, fp
        for _, c in ipairs(final_clazzes) do
          if c.name == "User" then fu = c end
          if c.name == "Product" then fp = c end
        end

        ok(fu ~= nil, "ActionsInteg Final: User parsed")
        ok(fp ~= nil, "ActionsInteg Final: Product parsed")

        if fu and fp then
          local fu_text = table.concat(buf_final, "\n", fu.starts_at_line, fu.ends_at_line)
          local fp_text = table.concat(buf_final, "\n", fp.starts_at_line, fp.ends_at_line)

          -- User should have ONLY User fields
          ok(fu_text:find("this.name", 1, true) ~= nil, "ActionsInteg Final: User has name")
          ok(fu_text:find("this.age", 1, true) ~= nil, "ActionsInteg Final: User has age")
          ok(fu_text:find("this.title", 1, true) == nil, "ActionsInteg Final: User NOT title")
          ok(fu_text:find("this.price", 1, true) == nil, "ActionsInteg Final: User NOT price")
          ok(fu_text:find("User(", 1, true) ~= nil, "ActionsInteg Final: User toString User(")

          -- Product should have ONLY Product fields
          ok(fp_text:find("this.title", 1, true) ~= nil, "ActionsInteg Final: Product has title")
          ok(fp_text:find("this.price", 1, true) ~= nil, "ActionsInteg Final: Product has price")
          ok(fp_text:find("this.name", 1, true) == nil, "ActionsInteg Final: Product NOT name")
          ok(fp_text:find("this.age", 1, true) == nil, "ActionsInteg Final: Product NOT age")
          ok(fp_text:find("Product(", 1, true) ~= nil, "ActionsInteg Final: Product toString Product(")

          -- Cross-check: class names don't leak
          ok(fu_text:find("Product copyWith", 1, true) == nil, "ActionsInteg Final: User NOT Product copyWith")
          ok(fp_text:find("User copyWith", 1, true) == nil, "ActionsInteg Final: Product NOT User copyWith")

          -- Idempotency via actions: re-executing should produce "no changes needed"
          notifications = {}
          actions_mod.execute_action(product_dc_action)
          -- Note: this uses the old product_dc_action which has stale starts_at_line.
          -- The re-parse in apply_incremental should handle this... or should it?
          -- This specifically tests whether stale line numbers cause issues.

          -- Actually let's get fresh actions to test idempotency properly
          local product_actions_2 = actions_mod.get_code_actions(bufnr, fp.starts_at_line)
          -- If truly idempotent, there should be no data class action (all complete)
          local has_dc = false
          for _, a in ipairs(product_actions_2) do
            if a.title:find("data class", 1, true) then
              has_dc = true
              break
            end
          end
          -- NOTE: has_dc might be true if "Regenerate" is shown. Check for "Generate" specifically.
          local has_generate = false
          for _, a in ipairs(product_actions_2) do
            if a.title == "Generate data class" then
              has_generate = true
              break
            end
          end
          ok(not has_generate, "ActionsInteg: Product no 'Generate data class' after generation (idempotent)")
        end
      end
    end
  end

  -- Clean up fake vim.api to not interfere with other tests
  vim.api = nil
  vim.notify = nil
end

-- ===========================================================================
-- 26. STALE LINE NUMBER: Test that stale starts_at_line in action doesn't
--     cause cross-class contamination
-- ===========================================================================
do
  io.write("\n=== Stale Line Number Tests ===\n")

  local initial_text = [[class Foo {
  final String x;
}

class Bar {
  final int y;
}]]

  local lines = {}
  for line in (initial_text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  -- Parse initially
  local clazzes = parser.parse_classes(initial_text)
  local foo_clazz, bar_clazz
  for _, c in ipairs(clazzes) do
    if c.name == "Foo" then foo_clazz = c end
    if c.name == "Bar" then bar_clazz = c end
  end

  ok(foo_clazz ~= nil, "StaleLineNum: Foo parsed")
  ok(bar_clazz ~= nil, "StaleLineNum: Bar parsed")

  if foo_clazz and bar_clazz then
    -- Record Bar's original starts_at_line
    local bar_original_line = bar_clazz.starts_at_line
    ok(bar_original_line ~= nil, "StaleLineNum: Bar starts_at_line recorded = " .. tostring(bar_original_line))

    -- Generate all for Foo (this shifts Bar's position)
    local new_lines, new_text, edits = generate_all_incremental(foo_clazz, lines)
    ok(edits > 0, "StaleLineNum: Foo generation produced edits")

    -- Find Bar's NEW position
    local new_clazzes = parser.parse_classes(new_text)
    local new_bar
    for _, c in ipairs(new_clazzes) do
      if c.name == "Bar" then new_bar = c; break end
    end
    ok(new_bar ~= nil, "StaleLineNum: Bar found after Foo generation")
    if new_bar then
      ok(new_bar.starts_at_line > bar_original_line,
        "StaleLineNum: Bar shifted from " .. bar_original_line .. " to " .. new_bar.starts_at_line)

      -- Now try to find a class at the OLD Bar line number
      -- This should find Foo (which now extends to cover that line)
      local wrong_class = parser.find_class_at_line(new_clazzes, bar_original_line)
      if wrong_class then
        ok(wrong_class.name == "Foo",
          "StaleLineNum: stale line " .. bar_original_line .. " now inside Foo (name=" .. wrong_class.name .. ")")
      else
        ok(true, "StaleLineNum: stale line " .. bar_original_line .. " finds no class")
      end

      -- The correct behavior: if we use Bar's stale line, we'd find Foo and
      -- generate Foo's methods instead of Bar's. This IS the contamination bug.
      -- Let's verify by generating with the stale reference
      local stale_clazz = parser.find_class_at_line(new_clazzes, bar_original_line)
      if stale_clazz and stale_clazz.name ~= "Bar" then
        ok(true, "StaleLineNum: CONFIRMED - stale line resolves to " .. stale_clazz.name .. " instead of Bar")
        -- This proves the contamination mechanism: if an action carries a stale
        -- starts_at_line, apply_incremental will find the WRONG class
      end

      -- VERIFY FIX: find_class_by_name resolves correctly regardless of line shifts
      local correct_bar = parser.find_class_by_name(new_clazzes, "Bar")
      ok(correct_bar ~= nil, "StaleLineNum FIX: find_class_by_name finds Bar")
      if correct_bar then
        eq(correct_bar.name, "Bar", "StaleLineNum FIX: correct class name")
        ok(correct_bar.starts_at_line > bar_original_line,
          "StaleLineNum FIX: Bar at correct shifted position " .. correct_bar.starts_at_line)
      end
    end
  end
end

-- ===========================================================================
-- 27. STALE ACTION VIA ACTIONS MODULE: Simulate the exact scenario where
--     a stale action (with old starts_at_line) is executed after another
--     class was generated. The find_class_by_name fix should prevent
--     contamination.
-- ===========================================================================
do
  io.write("\n=== Stale Action Fix Tests ===\n")

  local actions_mod = require("dart-class-tools.actions")

  local initial_text = [[class First {
  final String a;
  final int b;
}

class Second {
  final String x;
  final double y;
}]]

  -- Create a fake buffer
  local buf_lines = {}
  for line in (initial_text .. "\n"):gmatch("([^\n]*)\n") do
    buf_lines[#buf_lines + 1] = line
  end
  local bufnr = 998
  local notifications = {}

  vim.api = vim.api or {}
  vim.notify = function(msg, level)
    notifications[#notifications + 1] = { msg = msg, level = level }
  end
  vim.api.nvim_buf_line_count = function(b)
    if b == bufnr then return #buf_lines end
    return 0
  end
  vim.api.nvim_buf_get_lines = function(b, start_idx, end_idx, strict)
    if b ~= bufnr then return {} end
    local result = {}
    for i = start_idx + 1, end_idx do
      result[#result + 1] = buf_lines[i] or ""
    end
    return result
  end
  vim.api.nvim_buf_set_lines = function(b, start_idx, end_idx, strict, replacement)
    if b ~= bufnr then return end
    local new_buf = {}
    for i = 1, start_idx do
      new_buf[#new_buf + 1] = buf_lines[i]
    end
    for _, l in ipairs(replacement) do
      new_buf[#new_buf + 1] = l
    end
    for i = end_idx + 1, #buf_lines do
      new_buf[#new_buf + 1] = buf_lines[i]
    end
    buf_lines = new_buf
  end

  -- Step 1: Get code actions for BOTH classes BEFORE any generation
  local first_actions = actions_mod.get_code_actions(bufnr, 1)
  local second_line
  for i, l in ipairs(buf_lines) do
    if l:match("^class Second") then second_line = i; break end
  end
  local second_actions = actions_mod.get_code_actions(bufnr, second_line)

  local first_dc, second_dc
  for _, a in ipairs(first_actions) do
    if a.title:find("data class", 1, true) then first_dc = a; break end
  end
  for _, a in ipairs(second_actions) do
    if a.title:find("data class", 1, true) then second_dc = a; break end
  end

  ok(first_dc ~= nil, "StaleAction: First has data class action")
  ok(second_dc ~= nil, "StaleAction: Second has data class action")

  if first_dc and second_dc then
    -- Record Second's starts_at_line from the action
    local second_stale_line = second_dc.clazz.starts_at_line
    ok(second_stale_line ~= nil, "StaleAction: Second starts_at_line = " .. tostring(second_stale_line))

    -- Step 2: Execute First's action → this expands First and shifts Second
    actions_mod.execute_action(first_dc)
    local text_after_first = table.concat(buf_lines, "\n")
    ok(text_after_first:find("this.a", 1, true) ~= nil, "StaleAction: First generated")

    -- Verify Second shifted
    local new_second_line
    for i, l in ipairs(buf_lines) do
      if l:match("^class Second") then new_second_line = i; break end
    end
    ok(new_second_line ~= nil, "StaleAction: Second still exists")
    if new_second_line then
      ok(new_second_line > second_stale_line,
        "StaleAction: Second shifted from " .. second_stale_line .. " to " .. new_second_line)
    end

    -- Step 3: Execute the STALE second action (with old starts_at_line).
    -- With the find_class_by_name fix, this should still find Second correctly.
    actions_mod.execute_action(second_dc)
    local text_final = table.concat(buf_lines, "\n")

    -- Verify: Second should have its own fields, NOT First's fields
    local final_clazzes = parser.parse_classes(text_final)
    local f_first, f_second
    for _, c in ipairs(final_clazzes) do
      if c.name == "First" then f_first = c end
      if c.name == "Second" then f_second = c end
    end

    ok(f_first ~= nil, "StaleAction Final: First parsed")
    ok(f_second ~= nil, "StaleAction Final: Second parsed")

    if f_first and f_second then
      local first_text = table.concat(buf_lines, "\n", f_first.starts_at_line, f_first.ends_at_line)
      local second_text = table.concat(buf_lines, "\n", f_second.starts_at_line, f_second.ends_at_line)

      -- First should have a, b
      ok(first_text:find("this.a", 1, true) ~= nil, "StaleAction Final: First has a")
      ok(first_text:find("this.b", 1, true) ~= nil, "StaleAction Final: First has b")
      ok(first_text:find("this.x", 1, true) == nil, "StaleAction Final: First NOT x")
      ok(first_text:find("this.y", 1, true) == nil, "StaleAction Final: First NOT y")

      -- Second should have x, y (NOT a, b from First!)
      ok(second_text:find("this.x", 1, true) ~= nil, "StaleAction Final: Second has x")
      ok(second_text:find("this.y", 1, true) ~= nil, "StaleAction Final: Second has y")
      ok(second_text:find("this.a", 1, true) == nil, "StaleAction Final: Second NOT a")
      ok(second_text:find("this.b", 1, true) == nil, "StaleAction Final: Second NOT b")

      -- Class names
      ok(first_text:find("First(", 1, true) ~= nil, "StaleAction Final: First toString")
      ok(second_text:find("Second(", 1, true) ~= nil, "StaleAction Final: Second toString")
      ok(second_text:find("First(", 1, true) == nil, "StaleAction Final: Second NOT First toString")

      -- Idempotency
      local idem_actions = actions_mod.get_code_actions(bufnr, f_second.starts_at_line)
      local has_generate = false
      for _, a in ipairs(idem_actions) do
        if a.title == "Generate data class" then has_generate = true; break end
      end
      ok(not has_generate, "StaleAction Final: Second idempotent (no Generate)")
    end
  end

  -- Clean up
  vim.api = nil
  vim.notify = nil
end

--------------------------------------------------------------------------------
-- MANDATORY CASES A-D: Sequential single-action execution
--
-- These tests verify the user's explicit requirements:
--   Case A: constructor → copyWith: both must be present.
--   Case B: copyWith → constructor: both must be present.
--   Case C: run the same action twice: must be idempotent—update or no-op, no duplicates.
--   Case D: two classes in the same file: each action must modify only the selected class.
--
-- Each action is applied sequentially (not batched) by re-parsing the buffer
-- between actions, exactly as apply_incremental does in practice.
--------------------------------------------------------------------------------
io.write("\n=== Mandatory Cases A-D: Sequential Single-Action ===\n")

--- Helper: apply a SINGLE action to a buffer, re-parsing fresh each time.
--- This simulates what actions.apply_incremental does for one code action.
---@param buf_lines string[] 1-indexed lines
---@param class_name string target class
---@param kind string e.g. "constructor", "copyWith"
---@return string[] new_lines, string new_text, number edit_count
local function apply_single_action(buf_lines, class_name, kind)
  local text = table.concat(buf_lines, "\n")
  local clazzes = parser.parse_classes(text)
  local clazz = parser.find_class_by_name(clazzes, class_name)
  if not clazz then
    error("apply_single_action: could not find class '" .. class_name .. "'")
  end

  local blocks = incremental.detect_blocks(clazz, buf_lines)

  local gen_text
  if kind == "constructor" then
    gen_text = generator.generate_constructor(clazz)
  elseif kind == "copyWith" then
    gen_text = (generator.generate_copy_with(clazz))
  elseif kind == "toMap" then
    gen_text = generator.generate_to_map(clazz)
  elseif kind == "fromMap" then
    gen_text = (generator.generate_from_map(clazz))
  elseif kind == "toJson" then
    gen_text = (generator.generate_to_json(clazz))
  elseif kind == "fromJson" then
    gen_text = (generator.generate_from_json(clazz))
  elseif kind == "toString" then
    gen_text = generator.generate_to_string(clazz)
  elseif kind == "equality" then
    gen_text = (generator.generate_equality(clazz))
  elseif kind == "hashCode" then
    gen_text = (generator.generate_hash_code(clazz))
  elseif kind == "props" then
    gen_text = generator.generate_props(clazz, blocks.props)
  end

  if not gen_text then
    return buf_lines, table.concat(buf_lines, "\n"), 0
  end

  local edit = incremental.build_edit(kind, clazz, blocks, gen_text)
  if not edit then
    return buf_lines, table.concat(buf_lines, "\n"), 0
  end

  local new_lines = incremental.apply_edits(buf_lines, { edit })
  return new_lines, table.concat(new_lines, "\n"), 1
end

-- The exact expected output from the user's specification:
local EXPECTED_USER_OUTPUT = [[class User {
  final String name;

  const User({
    required this.name,
  });

  User copyWith({
    String? name,
  }) {
    return User(
      name: name ?? this.name,
    );
  }
}]]

-- ===========================================================================
-- Case A: constructor → copyWith (both must be present)
-- ===========================================================================
do
  io.write("\n--- Case A: constructor → copyWith ---\n")

  local input = [[class User {
  final String name;
}
]]
  local lines = {}
  for line in (input .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  -- Remove trailing empty line if present (from trailing \n\n)
  while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end

  -- Step 1: Generate constructor
  local lines_after_ctor, text_after_ctor, edits_ctor = apply_single_action(lines, "User", "constructor")
  ok(edits_ctor > 0, "Case A: constructor edit produced")
  ok(text_after_ctor:find("const User({", 1, true) ~= nil, "Case A: constructor present after step 1")
  ok(text_after_ctor:find("required this.name", 1, true) ~= nil, "Case A: constructor has 'required this.name'")
  -- copyWith should NOT be present yet
  ok(text_after_ctor:find("copyWith") == nil, "Case A: no copyWith after step 1")

  -- Step 2: Generate copyWith (re-parses the buffer with constructor already in it)
  local lines_final, text_final, edits_cw = apply_single_action(lines_after_ctor, "User", "copyWith")
  ok(edits_cw > 0, "Case A: copyWith edit produced")

  -- Both must be present
  ok(text_final:find("const User({", 1, true) ~= nil, "Case A: constructor STILL present after copyWith")
  ok(text_final:find("required this.name", 1, true) ~= nil, "Case A: constructor has 'required this.name' after copyWith")
  ok(text_final:find("copyWith({", 1, true) ~= nil, "Case A: copyWith present after step 2")
  ok(text_final:find("name ?? this.name", 1, true) ~= nil, "Case A: copyWith has 'name ?? this.name'")

  -- Verify exact expected output
  -- Trim trailing whitespace/newlines for comparison
  local trimmed_final = text_final:gsub("%s+$", "")
  local trimmed_expected = EXPECTED_USER_OUTPUT:gsub("%s+$", "")
  if trimmed_final == trimmed_expected then
    passed = passed + 1
    io.write("  PASS: Case A: exact output matches user specification\n")
  else
    failed = failed + 1
    local detail = "Case A: exact output does NOT match user specification"
    errors[#errors + 1] = detail
    io.write("  FAIL: " .. detail .. "\n")
    io.write("  --- EXPECTED ---\n")
    io.write(trimmed_expected .. "\n")
    io.write("  --- GOT ---\n")
    io.write(trimmed_final .. "\n")
    io.write("  --- END ---\n")
  end

  -- Verify constructor comes BEFORE copyWith in the output
  local ctor_pos = text_final:find("const User({", 1, true)
  local cw_pos = text_final:find("copyWith({", 1, true)
  ok(ctor_pos ~= nil and cw_pos ~= nil and ctor_pos < cw_pos,
    "Case A: constructor appears before copyWith")
end

-- ===========================================================================
-- Case B: copyWith → constructor (both must be present)
-- ===========================================================================
do
  io.write("\n--- Case B: copyWith → constructor ---\n")

  local input = [[class User {
  final String name;
}
]]
  local lines = {}
  for line in (input .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end

  -- Step 1: Generate copyWith FIRST
  local lines_after_cw, text_after_cw, edits_cw = apply_single_action(lines, "User", "copyWith")
  ok(edits_cw > 0, "Case B: copyWith edit produced")
  ok(text_after_cw:find("copyWith({", 1, true) ~= nil, "Case B: copyWith present after step 1")
  ok(text_after_cw:find("name ?? this.name", 1, true) ~= nil, "Case B: copyWith has 'name ?? this.name'")
  -- Constructor should NOT be present yet (the class had none)
  ok(text_after_cw:find("const User({", 1, true) == nil, "Case B: no constructor after step 1 (only copyWith)")

  -- Step 2: Generate constructor (re-parses the buffer with copyWith already in it)
  local lines_final, text_final, edits_ctor = apply_single_action(lines_after_cw, "User", "constructor")
  ok(edits_ctor > 0, "Case B: constructor edit produced")

  -- Both must be present
  ok(text_final:find("const User({", 1, true) ~= nil, "Case B: constructor present after step 2")
  ok(text_final:find("required this.name", 1, true) ~= nil, "Case B: constructor has 'required this.name'")
  ok(text_final:find("copyWith({", 1, true) ~= nil, "Case B: copyWith STILL present after constructor")
  ok(text_final:find("name ?? this.name", 1, true) ~= nil, "Case B: copyWith has 'name ?? this.name' after constructor")

  -- Verify exact expected output
  local trimmed_final = text_final:gsub("%s+$", "")
  local trimmed_expected = EXPECTED_USER_OUTPUT:gsub("%s+$", "")
  if trimmed_final == trimmed_expected then
    passed = passed + 1
    io.write("  PASS: Case B: exact output matches user specification\n")
  else
    failed = failed + 1
    local detail = "Case B: exact output does NOT match user specification"
    errors[#errors + 1] = detail
    io.write("  FAIL: " .. detail .. "\n")
    io.write("  --- EXPECTED ---\n")
    io.write(trimmed_expected .. "\n")
    io.write("  --- GOT ---\n")
    io.write(trimmed_final .. "\n")
    io.write("  --- END ---\n")
  end

  -- Verify constructor comes BEFORE copyWith in the output
  local ctor_pos = text_final:find("const User({", 1, true)
  local cw_pos = text_final:find("copyWith({", 1, true)
  ok(ctor_pos ~= nil and cw_pos ~= nil and ctor_pos < cw_pos,
    "Case B: constructor appears before copyWith (stable ordering)")
end

-- ===========================================================================
-- Case C: Idempotency — run the same action twice, no duplicates
-- ===========================================================================
do
  io.write("\n--- Case C: Idempotency ---\n")

  local input = [[class User {
  final String name;
}
]]
  local lines = {}
  for line in (input .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end

  -- Step 1: Generate constructor
  local lines1, text1, edits1 = apply_single_action(lines, "User", "constructor")
  ok(edits1 > 0, "Case C: first constructor edit produced")

  -- Step 2: Generate constructor AGAIN (should be a no-op)
  local lines2, text2, edits2 = apply_single_action(lines1, "User", "constructor")
  eq(edits2, 0, "Case C: second constructor run produces 0 edits (idempotent)")
  eq(text1, text2, "Case C: text unchanged after second constructor run")

  -- Step 3: Generate copyWith
  local lines3, text3, edits3 = apply_single_action(lines2, "User", "copyWith")
  ok(edits3 > 0, "Case C: first copyWith edit produced")

  -- Step 4: Generate copyWith AGAIN (should be a no-op)
  local lines4, text4, edits4 = apply_single_action(lines3, "User", "copyWith")
  eq(edits4, 0, "Case C: second copyWith run produces 0 edits (idempotent)")
  eq(text3, text4, "Case C: text unchanged after second copyWith run")

  -- Step 5: Generate constructor AGAIN after copyWith was added (should STILL be idempotent)
  local lines5, text5, edits5 = apply_single_action(lines4, "User", "constructor")
  eq(edits5, 0, "Case C: third constructor run after copyWith produces 0 edits")
  eq(text4, text5, "Case C: text unchanged after third constructor run")

  -- No duplicates: count occurrences of constructor and copyWith
  local _, ctor_count = text5:gsub("const User%({", "")
  eq(ctor_count, 1, "Case C: exactly 1 constructor in final output")
  local _, cw_count = text5:gsub("copyWith%({", "")
  eq(cw_count, 1, "Case C: exactly 1 copyWith in final output")

  -- Verify the final output still matches the expected
  local trimmed_final = text5:gsub("%s+$", "")
  local trimmed_expected = EXPECTED_USER_OUTPUT:gsub("%s+$", "")
  eq(trimmed_final, trimmed_expected, "Case C: final output matches user specification")
end

-- ===========================================================================
-- Case D: Two classes in the same file — each action only modifies its class
-- ===========================================================================
do
  io.write("\n--- Case D: Two classes in same file ---\n")

  local input = [[class User {
  final String name;
}

class Product {
  final String title;
  final double price;
}
]]
  local lines = {}
  for line in (input .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end

  -- Step 1: Generate constructor for User
  local lines1, text1, edits1 = apply_single_action(lines, "User", "constructor")
  ok(edits1 > 0, "Case D: User constructor edit produced")

  -- Product should be UNCHANGED
  local p_clazzes = parser.parse_classes(text1)
  local p_product = parser.find_class_by_name(p_clazzes, "Product")
  ok(p_product ~= nil, "Case D: Product still parseable after User constructor")
  if p_product then
    local product_text = table.concat(lines1, "\n", p_product.starts_at_line, p_product.ends_at_line)
    ok(product_text:find("this.title") == nil, "Case D: Product untouched after User constructor")
    ok(product_text:find("copyWith") == nil, "Case D: Product has no copyWith after User constructor")
  end

  -- User should have constructor
  local u_clazzes = parser.parse_classes(text1)
  local u_user = parser.find_class_by_name(u_clazzes, "User")
  ok(u_user ~= nil, "Case D: User parseable after constructor")
  if u_user then
    local user_text = table.concat(lines1, "\n", u_user.starts_at_line, u_user.ends_at_line)
    ok(user_text:find("const User({", 1, true) ~= nil, "Case D: User has constructor")
    ok(user_text:find("this.name", 1, true) ~= nil, "Case D: User constructor has name field")
  end

  -- Step 2: Generate constructor for Product
  local lines2, text2, edits2 = apply_single_action(lines1, "Product", "constructor")
  ok(edits2 > 0, "Case D: Product constructor edit produced")

  -- User's constructor should still be there unchanged
  local u2_clazzes = parser.parse_classes(text2)
  local u2_user = parser.find_class_by_name(u2_clazzes, "User")
  ok(u2_user ~= nil, "Case D: User parseable after Product constructor")
  if u2_user then
    local user_text = table.concat(lines2, "\n", u2_user.starts_at_line, u2_user.ends_at_line)
    ok(user_text:find("const User({", 1, true) ~= nil, "Case D: User constructor preserved after Product gen")
    -- User should NOT have Product's fields
    ok(user_text:find("this.title") == nil, "Case D: User doesn't have Product's 'title'")
    ok(user_text:find("this.price") == nil, "Case D: User doesn't have Product's 'price'")
  end

  -- Product should have its own constructor
  local p2_product = parser.find_class_by_name(u2_clazzes, "Product")
  ok(p2_product ~= nil, "Case D: Product parseable after its constructor")
  if p2_product then
    local product_text = table.concat(lines2, "\n", p2_product.starts_at_line, p2_product.ends_at_line)
    ok(product_text:find("const Product({", 1, true) ~= nil, "Case D: Product has constructor")
    ok(product_text:find("this.title", 1, true) ~= nil, "Case D: Product constructor has title")
    ok(product_text:find("this.price", 1, true) ~= nil, "Case D: Product constructor has price")
    -- Product should NOT have User's fields
    ok(product_text:find("this.name") == nil, "Case D: Product doesn't have User's 'name'")
  end

  -- Step 3: Generate copyWith for User
  local lines3, text3, edits3 = apply_single_action(lines2, "User", "copyWith")
  ok(edits3 > 0, "Case D: User copyWith edit produced")

  -- Step 4: Generate copyWith for Product
  local lines4, text4, edits4 = apply_single_action(lines3, "Product", "copyWith")
  ok(edits4 > 0, "Case D: Product copyWith edit produced")

  -- Final verification: both classes have both methods, no cross-contamination
  local final_clazzes = parser.parse_classes(text4)
  local final_user = parser.find_class_by_name(final_clazzes, "User")
  local final_product = parser.find_class_by_name(final_clazzes, "Product")

  ok(final_user ~= nil, "Case D Final: User parsed")
  ok(final_product ~= nil, "Case D Final: Product parsed")

  if final_user then
    local user_text = table.concat(lines4, "\n", final_user.starts_at_line, final_user.ends_at_line)
    ok(user_text:find("const User({", 1, true) ~= nil, "Case D Final: User has constructor")
    ok(user_text:find("required this.name", 1, true) ~= nil, "Case D Final: User constructor has name")
    ok(user_text:find("copyWith({", 1, true) ~= nil, "Case D Final: User has copyWith")
    ok(user_text:find("name ?? this.name", 1, true) ~= nil, "Case D Final: User copyWith has name")
    -- No Product fields
    ok(user_text:find("this.title") == nil, "Case D Final: User has no 'title'")
    ok(user_text:find("this.price") == nil, "Case D Final: User has no 'price'")
  end

  if final_product then
    local product_text = table.concat(lines4, "\n", final_product.starts_at_line, final_product.ends_at_line)
    ok(product_text:find("const Product({", 1, true) ~= nil, "Case D Final: Product has constructor")
    ok(product_text:find("required this.title", 1, true) ~= nil, "Case D Final: Product constructor has title")
    ok(product_text:find("required this.price", 1, true) ~= nil, "Case D Final: Product constructor has price")
    ok(product_text:find("copyWith({", 1, true) ~= nil, "Case D Final: Product has copyWith")
    ok(product_text:find("title ?? this.title", 1, true) ~= nil, "Case D Final: Product copyWith has title")
    ok(product_text:find("price ?? this.price", 1, true) ~= nil, "Case D Final: Product copyWith has price")
    -- No User fields
    ok(product_text:find("this.name") == nil, "Case D Final: Product has no 'name' (from User)")
  end

  -- Idempotency for both classes
  local lines5, text5, edits5 = apply_single_action(lines4, "User", "constructor")
  eq(edits5, 0, "Case D Idempotent: User constructor no-op")
  local lines6, text6, edits6 = apply_single_action(lines5, "User", "copyWith")
  eq(edits6, 0, "Case D Idempotent: User copyWith no-op")
  local lines7, text7, edits7 = apply_single_action(lines6, "Product", "constructor")
  eq(edits7, 0, "Case D Idempotent: Product constructor no-op")
  local lines8, text8, edits8 = apply_single_action(lines7, "Product", "copyWith")
  eq(edits8, 0, "Case D Idempotent: Product copyWith no-op")
end

--------------------------------------------------------------------------------
-- "Update existing members" tests
--
-- Tests for the new feature that updates ONLY existing members to match
-- current fields without creating new members.
--------------------------------------------------------------------------------
io.write("\n=== Update Existing Members Tests ===\n")

-- Load actions module for testing get_code_actions / statuses
local actions = require("dart-class-tools.actions")

--- Helper: apply "update existing members" to a class.
--- Only regenerates blocks that already exist and have field mismatches.
--- Never creates new (absent) blocks.
---@param buf_lines string[] 1-indexed lines
---@param class_name string target class
---@return string[] new_lines, string new_text, number edit_count
local function apply_update_existing(buf_lines, class_name)
  local text = table.concat(buf_lines, "\n")
  local clazzes = parser.parse_classes(text)
  local clazz = parser.find_class_by_name(clazzes, class_name)
  if not clazz then
    error("apply_update_existing: could not find class '" .. class_name .. "'")
  end

  local blocks = incremental.detect_blocks(clazz, buf_lines)
  local class_fields = incremental.get_class_field_names(clazz)

  -- Collect kinds that already exist and have field mismatches
  local update_kinds = {}
  local all_kinds = { "constructor", "copyWith", "toMap", "fromMap", "toJson", "fromJson", "toString", "equality", "hashCode", "props" }
  for _, kind in ipairs(all_kinds) do
    local block = blocks[kind]
    if block then
      if kind == "toJson" or kind == "fromJson" then
        -- Wrappers: no field tracking, but include if underlying map method is being updated
        -- (handled below)
      elseif kind == "props" then
        local status = incremental.props_status(block, class_fields)
        if status == "stale" then
          update_kinds[#update_kinds + 1] = kind
        end
      else
        if incremental.has_field_mismatch(block, class_fields) then
          update_kinds[#update_kinds + 1] = kind
        end
      end
    end
  end

  -- Also include toJson/fromJson if toMap/fromMap are being updated and the wrappers exist
  local update_set = {}
  for _, k in ipairs(update_kinds) do update_set[k] = true end
  if update_set.toMap and blocks.toJson then
    if not update_set.toJson then
      update_kinds[#update_kinds + 1] = "toJson"
    end
  end
  if update_set.fromMap and blocks.fromJson then
    if not update_set.fromJson then
      update_kinds[#update_kinds + 1] = "fromJson"
    end
  end

  local edits = {}
  for _, kind in ipairs(update_kinds) do
    local gen_text
    if kind == "constructor" then
      gen_text = generator.generate_constructor(clazz)
    elseif kind == "copyWith" then
      gen_text = (generator.generate_copy_with(clazz))
    elseif kind == "toMap" then
      gen_text = generator.generate_to_map(clazz)
    elseif kind == "fromMap" then
      gen_text = (generator.generate_from_map(clazz))
    elseif kind == "toJson" then
      gen_text = (generator.generate_to_json(clazz))
    elseif kind == "fromJson" then
      gen_text = (generator.generate_from_json(clazz))
    elseif kind == "toString" then
      gen_text = generator.generate_to_string(clazz)
    elseif kind == "equality" then
      gen_text = (generator.generate_equality(clazz))
    elseif kind == "hashCode" then
      gen_text = (generator.generate_hash_code(clazz))
    elseif kind == "props" then
      gen_text = generator.generate_props(clazz, blocks.props)
    end
    if gen_text then
      local edit = incremental.build_edit(kind, clazz, blocks, gen_text)
      if edit then
        edits[#edits + 1] = edit
      end
    end
  end

  local new_lines = incremental.apply_edits(buf_lines, edits)
  return new_lines, table.concat(new_lines, "\n"), #edits
end

-- ===========================================================================
-- Unit tests for orphan_fields and has_field_mismatch
-- ===========================================================================
io.write("\n--- Unit: orphan_fields / has_field_mismatch ---\n")
do
  -- orphan_fields: fields in block but not in class
  local orphans = incremental.orphan_fields({"name", "age"}, {"name", "age", "email"})
  eq(#orphans, 1, "orphan_fields: one orphan when block has extra field")
  eq(orphans[1], "email", "orphan_fields: orphan is 'email'")

  local orphans2 = incremental.orphan_fields({"name", "age"}, {"name", "age"})
  eq(#orphans2, 0, "orphan_fields: no orphans when sets match")

  local orphans3 = incremental.orphan_fields({"name", "age", "birthday"}, {"name", "age"})
  eq(#orphans3, 0, "orphan_fields: no orphans when block is subset of class")

  local orphans4 = incremental.orphan_fields({}, {"name"})
  eq(#orphans4, 1, "orphan_fields: all block fields are orphans when class has no fields")

  -- has_field_mismatch
  local block_complete = { fields = {"name", "age"} }
  eq(incremental.has_field_mismatch(block_complete, {"name", "age"}), false, "has_field_mismatch: no mismatch when matching")

  local block_missing = { fields = {"name"} }
  eq(incremental.has_field_mismatch(block_missing, {"name", "age"}), true, "has_field_mismatch: mismatch when field missing")

  local block_orphan = { fields = {"name", "age", "email"} }
  eq(incremental.has_field_mismatch(block_orphan, {"name", "age"}), true, "has_field_mismatch: mismatch when orphan field")

  eq(incremental.has_field_mismatch(nil, {"name"}), false, "has_field_mismatch: nil block returns false")
end

-- ===========================================================================
-- Unit tests for block_status returning "stale"
-- ===========================================================================
io.write("\n--- Unit: block_status stale detection ---\n")
do
  eq(incremental.block_status(nil, {"name"}), "absent", "block_status: nil block is absent")
  eq(incremental.block_status({ fields = {"name", "age"} }, {"name", "age"}), "complete", "block_status: matching fields is complete")
  eq(incremental.block_status({ fields = {"name"} }, {"name", "age"}), "incomplete", "block_status: missing field is incomplete")
  eq(incremental.block_status({ fields = {"name", "age", "email"} }, {"name", "age"}), "stale", "block_status: orphan field is stale")
  eq(incremental.block_status({ fields = {"name", "email"} }, {"name", "age"}), "stale", "block_status: both orphan and missing is stale")
  eq(incremental.block_status({ fields = {"email"} }, {"name"}), "stale", "block_status: completely different fields is stale")
end

-- ===========================================================================
-- Test 1: Field removed — update constructor and copyWith only (no toMap etc.)
-- ===========================================================================
io.write("\n--- Update Existing: field removed (constructor + copyWith only) ---\n")
do
  local text = [[class User {
  final String name;
  final int age;

  const User({
    required this.name,
    required this.age,
  });

  User copyWith({
    String? name,
    int? age,
  }) {
    return User(
      name: name ?? this.name,
      age: age ?? this.age,
    );
  }
}
]]
  -- Remove 'age' field, keeping only 'name'
  local modified = text:gsub("  final int age;\n", "")
  local lines = {}
  for line in (modified .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  -- Check status
  local clazz = parser.find_class_by_name(parser.parse_classes(modified), "User")
  ok(clazz ~= nil, "Update Existing Field Removed: class parsed")
  local blocks = incremental.detect_blocks(clazz, lines)
  local class_fields = incremental.get_class_field_names(clazz)
  eq(incremental.block_status(blocks.constructor, class_fields), "stale", "Update Existing Field Removed: constructor is stale")
  eq(incremental.block_status(blocks.copyWith, class_fields), "stale", "Update Existing Field Removed: copyWith is stale")

  -- Apply update existing
  local new_lines, new_text, edit_count = apply_update_existing(lines, "User")
  ok(edit_count > 0, "Update Existing Field Removed: edits produced")

  -- Verify constructor updated
  ok(new_text:find("required this.name"), "Update Existing Field Removed: constructor has name")
  ok(not new_text:find("required this.age"), "Update Existing Field Removed: constructor no longer has age")

  -- Verify copyWith updated
  ok(new_text:find("name %?%? this%.name"), "Update Existing Field Removed: copyWith has name")
  ok(not new_text:find("age %?%? this%.age"), "Update Existing Field Removed: copyWith no longer has age")

  -- Verify no toMap, fromMap, etc. were created
  ok(not new_text:find("toMap"), "Update Existing Field Removed: no toMap created")
  ok(not new_text:find("fromMap"), "Update Existing Field Removed: no fromMap created")
  ok(not new_text:find("toString"), "Update Existing Field Removed: no toString created")
  ok(not new_text:find("operator =="), "Update Existing Field Removed: no equality created")
  ok(not new_text:find("hashCode"), "Update Existing Field Removed: no hashCode created")

  -- Idempotency
  local new_lines2, _, edit_count2 = apply_update_existing(new_lines, "User")
  eq(edit_count2, 0, "Update Existing Field Removed: idempotent (0 edits on second run)")
end

-- ===========================================================================
-- Test 2: Field renamed — simulated by removing old + having new field
-- ===========================================================================
io.write("\n--- Update Existing: field renamed (age → birthday) ---\n")
do
  local text = [[class Person {
  final String name;
  final DateTime birthday;

  const Person({
    required this.name,
    required this.age,
  });

  Person copyWith({
    String? name,
    int? age,
  }) {
    return Person(
      name: name ?? this.name,
      age: age ?? this.age,
    );
  }

  @override
  String toString() {
    return 'Person(name: $name, age: $age)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Person && other.name == name && other.age == age;
  }

  @override
  int get hashCode {
    return name.hashCode ^ age.hashCode;
  }
}
]]
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local clazz = parser.find_class_by_name(parser.parse_classes(text), "Person")
  ok(clazz ~= nil, "Update Existing Rename: class parsed")
  local blocks = incremental.detect_blocks(clazz, lines)
  local class_fields = incremental.get_class_field_names(clazz)
  -- Constructor references this.name and this.age, but class has name + birthday
  eq(incremental.block_status(blocks.constructor, class_fields), "stale", "Update Existing Rename: constructor is stale")

  local new_lines, new_text, edit_count = apply_update_existing(lines, "Person")
  ok(edit_count > 0, "Update Existing Rename: edits produced")

  -- Constructor should have birthday, not age
  ok(new_text:find("required this.birthday"), "Update Existing Rename: constructor has birthday")
  ok(not new_text:find("required this.age"), "Update Existing Rename: constructor no longer has age")

  -- copyWith should have birthday, not age
  ok(new_text:find("birthday %?%? this%.birthday"), "Update Existing Rename: copyWith has birthday")
  ok(not new_text:find("age %?%? this%.age"), "Update Existing Rename: copyWith no longer has age")

  -- toString should have birthday, not age
  ok(new_text:find("birthday: %$birthday"), "Update Existing Rename: toString has birthday")
  ok(not new_text:find("age: %$age"), "Update Existing Rename: toString no longer has age")

  -- equality should have birthday, not age
  ok(new_text:find("other%.birthday"), "Update Existing Rename: equality has birthday")
  ok(not new_text:find("other%.age"), "Update Existing Rename: equality no longer has age")

  -- hashCode should have birthday, not age
  ok(new_text:find("birthday%.hashCode"), "Update Existing Rename: hashCode has birthday")
  ok(not new_text:find("age%.hashCode"), "Update Existing Rename: hashCode no longer has age")

  -- Idempotency
  local _, _, edit_count2 = apply_update_existing(new_lines, "Person")
  eq(edit_count2, 0, "Update Existing Rename: idempotent")
end

-- ===========================================================================
-- Test 3: Field added — update existing but don't create absent
-- ===========================================================================
io.write("\n--- Update Existing: field added (only existing members updated) ---\n")
do
  local text = [[class Config {
  final String host;
  final int port;
  final String apiKey;

  const Config({
    required this.host,
    required this.port,
  });

  @override
  String toString() {
    return 'Config(host: $host, port: $port)';
  }
}
]]
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local clazz = parser.find_class_by_name(parser.parse_classes(text), "Config")
  local blocks = incremental.detect_blocks(clazz, lines)
  local class_fields = incremental.get_class_field_names(clazz)

  -- Constructor and toString are incomplete (missing apiKey)
  eq(incremental.block_status(blocks.constructor, class_fields), "incomplete", "Update Existing Add Field: constructor is incomplete")
  eq(incremental.block_status(blocks.toString, class_fields), "incomplete", "Update Existing Add Field: toString is incomplete")

  local new_lines, new_text, edit_count = apply_update_existing(lines, "Config")
  ok(edit_count > 0, "Update Existing Add Field: edits produced")

  -- Constructor should now have apiKey
  ok(new_text:find("required this.apiKey"), "Update Existing Add Field: constructor has apiKey")
  ok(new_text:find("required this.host"), "Update Existing Add Field: constructor still has host")

  -- toString should now have apiKey
  ok(new_text:find("apiKey: %$apiKey"), "Update Existing Add Field: toString has apiKey")

  -- No copyWith, toMap, fromMap, equality, hashCode should be created
  ok(not new_text:find("copyWith"), "Update Existing Add Field: no copyWith created")
  ok(not new_text:find("toMap"), "Update Existing Add Field: no toMap created")
  ok(not new_text:find("fromMap"), "Update Existing Add Field: no fromMap created")
  ok(not new_text:find("operator =="), "Update Existing Add Field: no equality created")
  ok(not new_text:find("hashCode"), "Update Existing Add Field: no hashCode created")

  -- Idempotency
  local _, _, edit_count2 = apply_update_existing(new_lines, "Config")
  eq(edit_count2, 0, "Update Existing Add Field: idempotent")
end

-- ===========================================================================
-- Test 4: Positional constructor style preserved
-- ===========================================================================
io.write("\n--- Update Existing: positional constructor style preserved ---\n")
do
  local text = [[class Point {
  final double x;
  final double y;
  final double z;

  const Point(this.x, this.y);
}
]]
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local clazz = parser.find_class_by_name(parser.parse_classes(text), "Point")
  local blocks = incremental.detect_blocks(clazz, lines)
  local class_fields = incremental.get_class_field_names(clazz)
  -- Constructor has x, y but class has x, y, z => incomplete
  eq(incremental.block_status(blocks.constructor, class_fields), "incomplete", "Update Existing Positional: constructor is incomplete")

  local new_lines, new_text, edit_count = apply_update_existing(lines, "Point")
  ok(edit_count > 0, "Update Existing Positional: edits produced")

  -- Should preserve positional style (no { or [) and add z
  ok(new_text:find("this%.x"), "Update Existing Positional: constructor has x")
  ok(new_text:find("this%.y"), "Update Existing Positional: constructor has y")
  ok(new_text:find("this%.z"), "Update Existing Positional: constructor has z")

  -- Idempotency
  local _, _, edit_count2 = apply_update_existing(new_lines, "Point")
  eq(edit_count2, 0, "Update Existing Positional: idempotent")
end

-- ===========================================================================
-- Test 5: Mixed — field removed + field added (age removed, birthday+gender added)
-- ===========================================================================
io.write("\n--- Update Existing: mixed changes (remove + add fields) ---\n")
do
  local text = [[class User {
  final String name;
  final DateTime birthday;
  final String gender;

  const User(this.name, {required this.age});

  User copyWith({
    String? name,
    int? age,
  }) {
    return User(
      name ?? this.name,
      age: age ?? this.age,
    );
  }
}
]]
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local clazz = parser.find_class_by_name(parser.parse_classes(text), "User")
  ok(clazz ~= nil, "Update Existing Mixed: class parsed")
  local blocks = incremental.detect_blocks(clazz, lines)
  local class_fields = incremental.get_class_field_names(clazz)
  eq(incremental.block_status(blocks.constructor, class_fields), "stale", "Update Existing Mixed: constructor is stale")
  eq(incremental.block_status(blocks.copyWith, class_fields), "stale", "Update Existing Mixed: copyWith is stale")

  local new_lines, new_text, edit_count = apply_update_existing(lines, "User")
  ok(edit_count > 0, "Update Existing Mixed: edits produced")

  -- Constructor should have name, birthday, gender (no age)
  -- Note: mixed bracket style (positional start, named end) is preserved;
  -- generator uses ( ... }) which doesn't add "required" prefix
  ok(new_text:find("this%.name"), "Update Existing Mixed: constructor has name")
  ok(new_text:find("this%.birthday"), "Update Existing Mixed: constructor has birthday")
  ok(new_text:find("this%.gender"), "Update Existing Mixed: constructor has gender")
  ok(not new_text:find("this%.age"), "Update Existing Mixed: constructor no longer has age")

  -- copyWith should have name, birthday, gender (no age)
  ok(new_text:find("name %?%? this%.name"), "Update Existing Mixed: copyWith has name")
  ok(new_text:find("birthday %?%? this%.birthday"), "Update Existing Mixed: copyWith has birthday")
  ok(new_text:find("gender %?%? this%.gender"), "Update Existing Mixed: copyWith has gender")
  ok(not new_text:find("age %?%? this%.age"), "Update Existing Mixed: copyWith no longer has age")

  -- Idempotency
  local _, _, edit_count2 = apply_update_existing(new_lines, "User")
  eq(edit_count2, 0, "Update Existing Mixed: idempotent")
end

-- ===========================================================================
-- Test 6: Full data class with all members — remove a field
-- ===========================================================================
io.write("\n--- Update Existing: full data class, remove field ---\n")
do
  -- First generate a full data class, then remove a field and update existing
  local text = [[class Product {
  final String name;
  final double price;
  final int quantity;
}
]]
  local clazz, lines = parse_class_lines(text)
  -- Generate all members
  local full_lines, full_text, _ = generate_all_incremental(clazz, lines)
  ok(full_text:find("toMap"), "Update Existing Full: toMap generated")
  ok(full_text:find("fromMap"), "Update Existing Full: fromMap generated")
  ok(full_text:find("toJson"), "Update Existing Full: toJson generated")

  -- Now simulate removing 'quantity' field from the class
  local modified = full_text:gsub("  final int quantity;\n", "")
  local mod_lines = {}
  for line in (modified .. "\n"):gmatch("([^\n]*)\n") do
    mod_lines[#mod_lines + 1] = line
  end

  -- Verify status
  local mod_clazz = parser.find_class_by_name(parser.parse_classes(modified), "Product")
  ok(mod_clazz ~= nil, "Update Existing Full Remove: class re-parsed")
  local mod_blocks = incremental.detect_blocks(mod_clazz, mod_lines)
  local mod_fields = incremental.get_class_field_names(mod_clazz)
  eq(incremental.block_status(mod_blocks.constructor, mod_fields), "stale", "Update Existing Full Remove: constructor stale")
  eq(incremental.block_status(mod_blocks.copyWith, mod_fields), "stale", "Update Existing Full Remove: copyWith stale")
  eq(incremental.block_status(mod_blocks.toMap, mod_fields), "stale", "Update Existing Full Remove: toMap stale")
  eq(incremental.block_status(mod_blocks.toString, mod_fields), "stale", "Update Existing Full Remove: toString stale")
  eq(incremental.block_status(mod_blocks.equality, mod_fields), "stale", "Update Existing Full Remove: equality stale")
  eq(incremental.block_status(mod_blocks.hashCode, mod_fields), "stale", "Update Existing Full Remove: hashCode stale")

  -- Apply update existing
  local new_lines, new_text, edit_count = apply_update_existing(mod_lines, "Product")
  ok(edit_count > 0, "Update Existing Full Remove: edits produced")

  -- Verify quantity removed from all members
  ok(not new_text:find("quantity"), "Update Existing Full Remove: 'quantity' removed from everywhere")
  ok(new_text:find("this%.name"), "Update Existing Full Remove: name still in constructor")
  ok(new_text:find("this%.price"), "Update Existing Full Remove: price still in constructor")
  ok(new_text:find("name %?%? this%.name"), "Update Existing Full Remove: name in copyWith")
  ok(new_text:find("price %?%? this%.price"), "Update Existing Full Remove: price in copyWith")

  -- Verify toMap still has name and price
  ok(new_text:find("'name': name"), "Update Existing Full Remove: toMap has name")
  ok(new_text:find("'price': price"), "Update Existing Full Remove: toMap has price")

  -- Idempotency
  verify_idempotent(new_lines, new_text, "Product")
end

-- ===========================================================================
-- Test 7: No existing members — update existing does nothing
-- ===========================================================================
io.write("\n--- Update Existing: no existing members (no-op) ---\n")
do
  local text = [[class Empty {
  final String name;
  final int age;
}
]]
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local _, _, edit_count = apply_update_existing(lines, "Empty")
  eq(edit_count, 0, "Update Existing No Members: 0 edits (nothing to update)")
end

-- ===========================================================================
-- Test 8: All members already in sync — no-op
-- ===========================================================================
io.write("\n--- Update Existing: all members in sync (no-op) ---\n")
do
  local text = [[class Synced {
  final String name;
  final int age;
}
]]
  local clazz, lines = parse_class_lines(text)
  local full_lines, full_text, _ = generate_all_incremental(clazz, lines)

  -- Now run update existing on the already-complete class
  local _, _, edit_count = apply_update_existing(full_lines, "Synced")
  eq(edit_count, 0, "Update Existing All Synced: 0 edits (everything up to date)")
end

-- ===========================================================================
-- Test 9: Only some members exist — update only those, create none
-- ===========================================================================
io.write("\n--- Update Existing: partial members, only existing updated ---\n")
do
  local text = [[class Partial {
  final String name;
  final int age;
  final String email;

  const Partial({
    required this.name,
    required this.age,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'age': age,
    };
  }

  @override
  String toString() {
    return 'Partial(name: $name, age: $age)';
  }
}
]]
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local new_lines, new_text, edit_count = apply_update_existing(lines, "Partial")
  ok(edit_count > 0, "Update Existing Partial: edits produced")

  -- Constructor should now have email
  ok(new_text:find("required this.email"), "Update Existing Partial: constructor has email")
  -- toMap should now have email
  ok(new_text:find("'email': email"), "Update Existing Partial: toMap has email")
  -- toString should now have email
  ok(new_text:find("email: %$email"), "Update Existing Partial: toString has email")

  -- copyWith, fromMap, equality, hashCode should NOT be created
  ok(not new_text:find("copyWith"), "Update Existing Partial: no copyWith created")
  ok(not new_text:find("fromMap"), "Update Existing Partial: no fromMap created")
  ok(not new_text:find("operator =="), "Update Existing Partial: no equality created")
  ok(not new_text:find("get hashCode"), "Update Existing Partial: no hashCode created")

  -- Idempotency
  local _, _, edit_count2 = apply_update_existing(new_lines, "Partial")
  eq(edit_count2, 0, "Update Existing Partial: idempotent")
end

-- ===========================================================================
-- Test 10: toJson/fromJson wrappers updated when toMap/fromMap updated
-- ===========================================================================
io.write("\n--- Update Existing: toJson/fromJson wrappers follow toMap/fromMap ---\n")
do
  local text = [[class Item {
  final String name;
  final double price;
}
]]
  local clazz, lines = parse_class_lines(text)
  -- Generate full data class
  local full_lines, full_text, _ = generate_all_incremental(clazz, lines)
  ok(full_text:find("toJson"), "Update Existing Wrappers: toJson exists")
  ok(full_text:find("fromJson"), "Update Existing Wrappers: fromJson exists")

  -- Remove price field
  local modified = full_text:gsub("  final double price;\n", "")
  local mod_lines = {}
  for line in (modified .. "\n"):gmatch("([^\n]*)\n") do
    mod_lines[#mod_lines + 1] = line
  end

  local new_lines, new_text, edit_count = apply_update_existing(mod_lines, "Item")
  ok(edit_count > 0, "Update Existing Wrappers: edits produced")

  -- price should be gone from all members
  ok(not new_text:find("price"), "Update Existing Wrappers: 'price' removed everywhere")

  -- toJson and fromJson should still exist (they were updated, not removed)
  ok(new_text:find("toJson"), "Update Existing Wrappers: toJson still exists")
  ok(new_text:find("fromJson"), "Update Existing Wrappers: fromJson still exists")

  -- Idempotency
  verify_idempotent(new_lines, new_text, "Item")
end

-- ===========================================================================
-- Test 11: Named optional constructor brackets preserved ([ ])
-- ===========================================================================
io.write("\n--- Update Existing: optional positional brackets preserved ---\n")
do
  local text = [[class Opt {
  final String a;
  final int b;
  final bool c;

  const Opt([this.a = '', this.b = 0]);
}
]]
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local new_lines, new_text, edit_count = apply_update_existing(lines, "Opt")
  ok(edit_count > 0, "Update Existing Optional Positional: edits produced")

  -- Should preserve [ ] optional positional style
  ok(new_text:find("Opt%(%["), "Update Existing Optional Positional: has Opt([")
  ok(new_text:find("this%.a"), "Update Existing Optional Positional: has this.a")
  ok(new_text:find("this%.c"), "Update Existing Optional Positional: has this.c")

  -- Idempotency
  local _, _, edit_count2 = apply_update_existing(new_lines, "Opt")
  eq(edit_count2, 0, "Update Existing Optional Positional: idempotent")
end

-- ===========================================================================
-- Test 12: action_title for stale status
-- ===========================================================================
io.write("\n--- Unit: action_title stale status ---\n")
do
  -- We can't call action_title directly (it's local), but we can test
  -- the statuses via get_all_statuses exported from actions module
  local text = [[class StaleTest {
  final String name;

  const StaleTest({
    required this.name,
    required this.age,
  });
}
]]
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local clazz = parser.find_class_by_name(parser.parse_classes(text), "StaleTest")
  local blocks = incremental.detect_blocks(clazz, lines)
  local statuses = actions.get_all_statuses(clazz, blocks)
  eq(statuses.constructor, "stale", "action_title stale: constructor status is stale")
end

-- ===========================================================================
-- Test 13: Multiple classes — update existing only affects targeted class
-- ===========================================================================
io.write("\n--- Update Existing: multiple classes isolation ---\n")
do
  local text = [[class Alpha {
  final String x;

  const Alpha({required this.x, required this.y});
}

class Beta {
  final int a;
  final int b;

  const Beta({required this.a, required this.b});
}
]]
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  -- Only Alpha is stale (has orphan 'y'), Beta is complete
  local new_lines, new_text, edit_count = apply_update_existing(lines, "Alpha")
  ok(edit_count > 0, "Update Existing Multi-class: Alpha edits produced")

  -- Alpha constructor should no longer have y
  local alpha_clazz = parser.find_class_by_name(parser.parse_classes(new_text), "Alpha")
  local alpha_blocks = incremental.detect_blocks(alpha_clazz, new_lines)
  ok(not alpha_blocks.constructor.text:find("this%.y"), "Update Existing Multi-class: Alpha constructor no longer has y")

  -- Beta should be unchanged
  local beta_clazz = parser.find_class_by_name(parser.parse_classes(new_text), "Beta")
  local beta_blocks = incremental.detect_blocks(beta_clazz, new_lines)
  ok(beta_blocks.constructor.text:find("this%.a"), "Update Existing Multi-class: Beta constructor still has a")
  ok(beta_blocks.constructor.text:find("this%.b"), "Update Existing Multi-class: Beta constructor still has b")
end

--------------------------------------------------------------------------------
io.write("\n=== Equatable / Props Tests ===\n")
--------------------------------------------------------------------------------

-- ===========================================================================
-- 1. Parser: uses_equatable() detection
-- ===========================================================================
io.write("\n--- Parser: uses_equatable() detection ---\n")

-- extends Equatable
do
  local text = [[class Foo extends Equatable {
  final String name;
  final int age;
}
]]
  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]
  ok(clazz ~= nil, "uses_equatable: parsed extends Equatable class")
  if clazz then
    ok(clazz:uses_equatable(), "uses_equatable: extends Equatable returns true")
  end
end

-- with EquatableMixin
do
  local text = [[class Bar with EquatableMixin {
  final String title;
  final double price;
}
]]
  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]
  ok(clazz ~= nil, "uses_equatable: parsed EquatableMixin class")
  if clazz then
    ok(clazz:uses_equatable(), "uses_equatable: with EquatableMixin returns true")
  end
end

-- extends Equatable + other mixins
do
  local text = [[class Baz extends Equatable with SomeMixin {
  final String data;
}
]]
  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]
  ok(clazz ~= nil, "uses_equatable: parsed extends Equatable with mixins")
  if clazz then
    ok(clazz:uses_equatable(), "uses_equatable: extends Equatable with mixins returns true")
  end
end

-- regular class (NOT equatable)
do
  local text = [[class Regular {
  final String name;
}
]]
  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]
  ok(clazz ~= nil, "uses_equatable: parsed regular class")
  if clazz then
    ok(not clazz:uses_equatable(), "uses_equatable: regular class returns false")
  end
end

-- extends something else
do
  local text = [[class Child extends Parent {
  final String name;
}
]]
  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]
  ok(clazz ~= nil, "uses_equatable: parsed extends Parent class")
  if clazz then
    ok(not clazz:uses_equatable(), "uses_equatable: extends Parent returns false")
  end
end

-- ===========================================================================
-- 2. Generator: generate_props() output correctness
-- ===========================================================================
io.write("\n--- Generator: generate_props() ---\n")

-- Basic class with multiple fields
do
  local text = [[class Foo extends Equatable {
  final String name;
  final int age;
  final String? email;
}
]]
  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]
  ok(clazz ~= nil, "generate_props: parsed class")
  if clazz then
    local props_text = generator.generate_props(clazz)
    ok(props_text:find("@override", 1, true) ~= nil, "generate_props: has @override")
    ok(props_text:find("List<Object?> get props", 1, true) ~= nil, "generate_props: has List<Object?> get props")
    ok(props_text:find("[name, age, email]", 1, true) ~= nil, "generate_props: correct field list")
    -- Check exact format
    local expected = "  @override\n  List<Object?> get props => [name, age, email];"
    eq(props_text, expected, "generate_props: exact output matches")
  end
end

-- Single field
do
  local text = [[class Single extends Equatable {
  final String name;
}
]]
  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]
  if clazz then
    local props_text = generator.generate_props(clazz)
    local expected = "  @override\n  List<Object?> get props => [name];"
    eq(props_text, expected, "generate_props: single field")
  end
end

-- No fields (empty props)
do
  local text = [[class Empty extends Equatable {
}
]]
  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]
  if clazz then
    local props_text = generator.generate_props(clazz)
    local expected = "  @override\n  List<Object?> get props => [];"
    eq(props_text, expected, "generate_props: no fields produces empty array")
  end
end

-- Excludes late fields (gen_properties() already does this)
do
  local text = [[class WithLate extends Equatable {
  final String name;
  late String derived;
  final int count;
}
]]
  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]
  if clazz then
    local props_text = generator.generate_props(clazz)
    ok(props_text:find("name", 1, true) ~= nil, "generate_props late: includes name")
    ok(props_text:find("count", 1, true) ~= nil, "generate_props late: includes count")
    ok(props_text:find("derived", 1, true) == nil, "generate_props late: excludes late derived")
  end
end

-- Excludes static fields
do
  local text = [[class WithStatic extends Equatable {
  static const maxAge = 150;
  final String name;
  final int age;
}
]]
  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]
  if clazz then
    local props_text = generator.generate_props(clazz)
    ok(props_text:find("name", 1, true) ~= nil, "generate_props static: includes name")
    ok(props_text:find("age", 1, true) ~= nil, "generate_props static: includes age")
    ok(props_text:find("maxAge", 1, true) == nil, "generate_props static: excludes static maxAge")
  end
end

-- ===========================================================================
-- 3. Incremental: extract_props_fields()
-- ===========================================================================
io.write("\n--- Incremental: extract_props_fields() ---\n")

do
  -- Multiple fields
  local fields = incremental.extract_props_fields("  @override\n  List<Object?> get props => [name, age, email];")
  eq(#fields, 3, "extract_props_fields: 3 fields")
  eq(fields[1], "name", "extract_props_fields: field 1 is name")
  eq(fields[2], "age", "extract_props_fields: field 2 is age")
  eq(fields[3], "email", "extract_props_fields: field 3 is email")

  -- Empty array
  local empty = incremental.extract_props_fields("  @override\n  List<Object?> get props => [];")
  eq(#empty, 0, "extract_props_fields: empty array")

  -- Single field
  local single = incremental.extract_props_fields("  List<Object?> get props => [name];")
  eq(#single, 1, "extract_props_fields: single field")
  eq(single[1], "name", "extract_props_fields: single field is name")

  -- No brackets at all
  local none = incremental.extract_props_fields("some random text")
  eq(#none, 0, "extract_props_fields: no brackets returns empty")

  -- Whitespace inside brackets
  local spaced = incremental.extract_props_fields("get props => [ name , age ];")
  eq(#spaced, 2, "extract_props_fields: whitespace inside brackets")
  eq(spaced[1], "name", "extract_props_fields: spaced field 1")
  eq(spaced[2], "age", "extract_props_fields: spaced field 2")

  -- Duplicate field names (edge case, should deduplicate)
  local duped = incremental.extract_props_fields("get props => [name, name, age];")
  eq(#duped, 2, "extract_props_fields: deduplicates")
  eq(duped[1], "name", "extract_props_fields: dedup field 1")
  eq(duped[2], "age", "extract_props_fields: dedup field 2")
end

-- ===========================================================================
-- 4. Incremental: props block detection in detect_blocks()
-- ===========================================================================
io.write("\n--- Incremental: props block detection ---\n")

-- Detect props in an Equatable class with existing props
do
  local text = [[class Foo extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> get props => [name, age];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "props block detect: parsed class")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "props block detect: found props block")
    if blocks.props then
      eq(blocks.props.kind, "props", "props block detect: kind is 'props'")
      eq(#blocks.props.fields, 2, "props block detect: 2 fields detected")
      eq(blocks.props.fields[1], "name", "props block detect: field 1 is name")
      eq(blocks.props.fields[2], "age", "props block detect: field 2 is age")
      ok(blocks.props.text:find("@override", 1, true) ~= nil, "props block detect: text has @override")
      ok(blocks.props.text:find("get props", 1, true) ~= nil, "props block detect: text has get props")
    end
  end
end

-- Bare Equatable class (no props getter)
do
  local text = [[class Bare extends Equatable {
  final String name;
  final int age;
}
]]
  local clazz, lines = parse_class_lines(text)
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    eq(blocks.props, nil, "props block detect: bare Equatable has no props block")
  end
end

-- Props getter with empty array
do
  local text = [[class EmptyProps extends Equatable {
  @override
  List<Object?> get props => [];
}
]]
  local clazz, lines = parse_class_lines(text)
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "props block detect: found empty props block")
    if blocks.props then
      eq(#blocks.props.fields, 0, "props block detect: empty array has 0 fields")
    end
  end
end

-- ===========================================================================
-- 5. Incremental: props_status() — absent, stale, complete
-- ===========================================================================
io.write("\n--- Incremental: props_status() ---\n")

-- absent
do
  eq(incremental.props_status(nil, {"name", "age"}), "absent", "props_status: nil block = absent")
end

-- complete (exact match, same order)
do
  local block = { fields = {"name", "age", "email"} }
  eq(incremental.props_status(block, {"name", "age", "email"}), "complete", "props_status: same fields same order = complete")
end

-- stale: missing field
do
  local block = { fields = {"name", "age"} }
  eq(incremental.props_status(block, {"name", "age", "email"}), "stale", "props_status: missing field = stale")
end

-- stale: extra field (orphan)
do
  local block = { fields = {"name", "age", "email"} }
  eq(incremental.props_status(block, {"name", "age"}), "stale", "props_status: extra field = stale")
end

-- stale: wrong order (same set)
do
  local block = { fields = {"age", "name"} }
  eq(incremental.props_status(block, {"name", "age"}), "stale", "props_status: wrong order = stale")
end

-- stale: different field entirely
do
  local block = { fields = {"name", "title"} }
  eq(incremental.props_status(block, {"name", "age"}), "stale", "props_status: different field = stale")
end

-- complete: empty class, empty props
do
  local block = { fields = {} }
  eq(incremental.props_status(block, {}), "complete", "props_status: both empty = complete")
end

-- stale: fields in props but no class fields
do
  local block = { fields = {"name"} }
  eq(incremental.props_status(block, {}), "stale", "props_status: props has fields but class empty = stale")
end

-- ===========================================================================
-- 6. Actions: applicable_kinds() for Equatable classes
-- ===========================================================================
io.write("\n--- Actions: applicable_kinds() for Equatable ---\n")

-- Equatable class gets props instead of equality/hashCode
do
  local text = [[class Foo extends Equatable {
  final String name;
  final int age;
}
]]
  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]
  if clazz then
    local kinds = actions.applicable_kinds(clazz)
    ok(kinds.props == true, "applicable_kinds equatable: props = true")
    ok(kinds.equality == nil, "applicable_kinds equatable: equality = nil")
    ok(kinds.hashCode == nil, "applicable_kinds equatable: hashCode = nil")
    ok(kinds.constructor == true, "applicable_kinds equatable: constructor = true")
    ok(kinds.copyWith == true, "applicable_kinds equatable: copyWith = true")
    ok(kinds.toMap == true, "applicable_kinds equatable: toMap = true")
    ok(kinds.fromMap == true, "applicable_kinds equatable: fromMap = true")
    ok(kinds.toJson == true, "applicable_kinds equatable: toJson = true")
    ok(kinds.fromJson == true, "applicable_kinds equatable: fromJson = true")
    ok(kinds.toString == true, "applicable_kinds equatable: toString = true")
  end
end

-- Regular class gets equality/hashCode, NOT props
do
  local text = [[class Bar {
  final String name;
  final int age;
}
]]
  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]
  if clazz then
    local kinds = actions.applicable_kinds(clazz)
    ok(kinds.props == nil, "applicable_kinds regular: props = nil")
    ok(kinds.equality == true, "applicable_kinds regular: equality = true")
    ok(kinds.hashCode == true, "applicable_kinds regular: hashCode = true")
  end
end

-- EquatableMixin class also gets props
do
  local text = [[class Baz with EquatableMixin {
  final String name;
}
]]
  local clazzes = parser.parse_classes(text)
  local clazz = clazzes[1]
  if clazz then
    local kinds = actions.applicable_kinds(clazz)
    ok(kinds.props == true, "applicable_kinds mixin: props = true")
    ok(kinds.equality == nil, "applicable_kinds mixin: equality = nil")
    ok(kinds.hashCode == nil, "applicable_kinds mixin: hashCode = nil")
  end
end

-- ===========================================================================
-- 7. Actions: get_all_statuses() for Equatable class
-- ===========================================================================
io.write("\n--- Actions: get_all_statuses() for Equatable ---\n")

-- Bare Equatable class (nothing generated yet)
do
  local text = [[class Foo extends Equatable {
  final String name;
  final int age;
}
]]
  local clazz, lines = parse_class_lines(text)
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    local statuses = actions.get_all_statuses(clazz, blocks)
    eq(statuses.props, "absent", "get_all_statuses equatable bare: props = absent")
    eq(statuses.constructor, "absent", "get_all_statuses equatable bare: constructor = absent")
  end
end

-- Equatable with complete props
do
  local text = [[class Foo extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> get props => [name, age];
}
]]
  local clazz, lines = parse_class_lines(text)
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    local statuses = actions.get_all_statuses(clazz, blocks)
    eq(statuses.props, "complete", "get_all_statuses equatable complete: props = complete")
  end
end

-- Equatable with stale props (missing field)
do
  local text = [[class Foo extends Equatable {
  final String name;
  final int age;
  final String email;

  @override
  List<Object?> get props => [name, age];
}
]]
  local clazz, lines = parse_class_lines(text)
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    local statuses = actions.get_all_statuses(clazz, blocks)
    eq(statuses.props, "stale", "get_all_statuses equatable stale: props = stale (missing field)")
  end
end

-- Equatable with stale props (wrong order)
do
  local text = [[class Foo extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> get props => [age, name];
}
]]
  local clazz, lines = parse_class_lines(text)
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    local statuses = actions.get_all_statuses(clazz, blocks)
    eq(statuses.props, "stale", "get_all_statuses equatable stale: props = stale (wrong order)")
  end
end

-- ===========================================================================
-- 8. Integration: Generate props for bare Equatable class
-- ===========================================================================
io.write("\n--- Integration: Generate props for bare Equatable ---\n")
do
  local text = [[class Foo extends Equatable {
  final String name;
  final int age;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Integ props: parsed class")
  if clazz then
    -- Generate only props (simulating single action)
    local gen_text = generator.generate_props(clazz)
    local blocks = incremental.detect_blocks(clazz, lines)
    local edit = incremental.build_edit("props", clazz, blocks, gen_text)
    ok(edit ~= nil, "Integ props: edit produced")
    if edit then
      local new_lines = incremental.apply_edits(lines, { edit })
      local new_text = table.concat(new_lines, "\n")
      ok(new_text:find("@override", 1, true) ~= nil, "Integ props: has @override")
      ok(new_text:find("List<Object?> get props => [name, age]", 1, true) ~= nil, "Integ props: has correct props getter")

      -- Verify idempotency: second run should produce 0 edits
      local r2_clazzes = parser.parse_classes(new_text)
      local r2_clazz = parser.find_class_by_name(r2_clazzes, "Foo")
      ok(r2_clazz ~= nil, "Integ props idempotent: re-parsed class")
      if r2_clazz then
        local r2_blocks = incremental.detect_blocks(r2_clazz, new_lines)
        local r2_gen = generator.generate_props(r2_clazz)
        local r2_edit = incremental.build_edit("props", r2_clazz, r2_blocks, r2_gen)
        eq(r2_edit, nil, "Integ props idempotent: second run produces nil edit")
      end
    end
  end
end

-- ===========================================================================
-- 9. Integration: Update props when fields change
-- ===========================================================================
io.write("\n--- Integration: Update props on field change ---\n")

-- Add a field to a class with existing props
do
  local text = [[class Foo extends Equatable {
  final String name;
  final int age;
  final String email;

  @override
  List<Object?> get props => [name, age];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Integ update props add: parsed class")
  if clazz then
    local gen_text = generator.generate_props(clazz)
    local blocks = incremental.detect_blocks(clazz, lines)
    local edit = incremental.build_edit("props", clazz, blocks, gen_text)
    ok(edit ~= nil, "Integ update props add: edit produced")
    if edit then
      local new_lines = incremental.apply_edits(lines, { edit })
      local new_text = table.concat(new_lines, "\n")
      ok(new_text:find("[name, age, email]", 1, true) ~= nil, "Integ update props add: now includes email")

      -- Idempotency
      local r2_clazz = parser.find_class_by_name(parser.parse_classes(new_text), "Foo")
      if r2_clazz then
        local r2_blocks = incremental.detect_blocks(r2_clazz, new_lines)
        local r2_gen = generator.generate_props(r2_clazz)
        local r2_edit = incremental.build_edit("props", r2_clazz, r2_blocks, r2_gen)
        eq(r2_edit, nil, "Integ update props add: idempotent after update")
      end
    end
  end
end

-- Remove a field (props has orphan)
do
  local text = [[class Foo extends Equatable {
  final String name;

  @override
  List<Object?> get props => [name, age];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Integ update props remove: parsed class")
  if clazz then
    local gen_text = generator.generate_props(clazz)
    local blocks = incremental.detect_blocks(clazz, lines)
    local edit = incremental.build_edit("props", clazz, blocks, gen_text)
    ok(edit ~= nil, "Integ update props remove: edit produced")
    if edit then
      local new_lines = incremental.apply_edits(lines, { edit })
      local new_text = table.concat(new_lines, "\n")
      ok(new_text:find("[name]", 1, true) ~= nil, "Integ update props remove: only name remains")
      ok(new_text:find("age") == nil, "Integ update props remove: age is gone")
    end
  end
end

-- Reorder fields
do
  local text = [[class Foo extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> get props => [age, name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Integ update props reorder: parsed class")
  if clazz then
    local gen_text = generator.generate_props(clazz)
    local blocks = incremental.detect_blocks(clazz, lines)
    local edit = incremental.build_edit("props", clazz, blocks, gen_text)
    ok(edit ~= nil, "Integ update props reorder: edit produced")
    if edit then
      local new_lines = incremental.apply_edits(lines, { edit })
      local new_text = table.concat(new_lines, "\n")
      ok(new_text:find("[name, age]", 1, true) ~= nil, "Integ update props reorder: correct order [name, age]")
    end
  end
end

-- ===========================================================================
-- 10. Integration: Equatable + constructor + copyWith + toString + props
-- ===========================================================================
io.write("\n--- Integration: Full Equatable data class generation ---\n")
do
  local text = [[class Person extends Equatable {
  final String name;
  final int age;
  final String? email;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Integ full equatable: parsed class")
  if clazz then
    -- Equatable classes use: constructor, copyWith, toMap, fromMap, toJson, fromJson, toString, props
    -- (NOT equality, hashCode)
    local eq_kinds = { "constructor", "copyWith", "toMap", "fromMap", "toJson", "fromJson", "toString", "props" }
    local blocks = incremental.detect_blocks(clazz, lines)
    local edits = {}
    for _, kind in ipairs(eq_kinds) do
      local gen_text
      if kind == "constructor" then
        gen_text = generator.generate_constructor(clazz)
      elseif kind == "copyWith" then
        gen_text = (generator.generate_copy_with(clazz))
      elseif kind == "toMap" then
        gen_text = generator.generate_to_map(clazz)
      elseif kind == "fromMap" then
        gen_text = (generator.generate_from_map(clazz))
      elseif kind == "toJson" then
        gen_text = (generator.generate_to_json(clazz))
      elseif kind == "fromJson" then
        gen_text = (generator.generate_from_json(clazz))
      elseif kind == "toString" then
        gen_text = generator.generate_to_string(clazz)
      elseif kind == "props" then
        gen_text = generator.generate_props(clazz)
      end
      if gen_text then
        local edit = incremental.build_edit(kind, clazz, blocks, gen_text)
        if edit then
          edits[#edits + 1] = edit
        end
      end
    end
    ok(#edits > 0, "Integ full equatable: edits produced")
    local new_lines = incremental.apply_edits(lines, edits)
    local new_text = table.concat(new_lines, "\n")

    -- Should have constructor, copyWith, toMap, fromMap, toJson, fromJson, toString, props
    ok(new_text:find("const Person({", 1, true) ~= nil, "Integ full equatable: has constructor")
    ok(new_text:find("Person copyWith(", 1, true) ~= nil, "Integ full equatable: has copyWith")
    ok(new_text:find("toMap", 1, true) ~= nil, "Integ full equatable: has toMap")
    ok(new_text:find("fromMap", 1, true) ~= nil, "Integ full equatable: has fromMap")
    ok(new_text:find("toJson", 1, true) ~= nil, "Integ full equatable: has toJson")
    ok(new_text:find("fromJson", 1, true) ~= nil, "Integ full equatable: has fromJson")
    ok(new_text:find("toString()", 1, true) ~= nil, "Integ full equatable: has toString")
    ok(new_text:find("get props => [name, age, email]", 1, true) ~= nil, "Integ full equatable: has props")

    -- Should NOT have equality or hashCode
    ok(new_text:find("operator ==", 1, true) == nil, "Integ full equatable: no operator ==")
    ok(new_text:find("get hashCode", 1, true) == nil, "Integ full equatable: no hashCode")

    -- Verify idempotency
    local r2_clazz = parser.find_class_by_name(parser.parse_classes(new_text), "Person")
    ok(r2_clazz ~= nil, "Integ full equatable idempotent: re-parsed class")
    if r2_clazz then
      local r2_blocks = incremental.detect_blocks(r2_clazz, new_lines)
      local r2_edits = 0
      for _, kind in ipairs(eq_kinds) do
        local gen_text
        if kind == "constructor" then
          gen_text = generator.generate_constructor(r2_clazz)
        elseif kind == "copyWith" then
          gen_text = (generator.generate_copy_with(r2_clazz))
        elseif kind == "toMap" then
          gen_text = generator.generate_to_map(r2_clazz)
        elseif kind == "fromMap" then
          gen_text = (generator.generate_from_map(r2_clazz))
        elseif kind == "toJson" then
          gen_text = (generator.generate_to_json(r2_clazz))
        elseif kind == "fromJson" then
          gen_text = (generator.generate_from_json(r2_clazz))
        elseif kind == "toString" then
          gen_text = generator.generate_to_string(r2_clazz)
        elseif kind == "props" then
          gen_text = generator.generate_props(r2_clazz)
        end
        if gen_text then
          local e = incremental.build_edit(kind, r2_clazz, r2_blocks, gen_text)
          if e then
            r2_edits = r2_edits + 1
            io.write("    [DEBUG] Non-idempotent edit for " .. kind .. " (action=" .. e.action .. ")\n")
          end
        end
      end
      eq(r2_edits, 0, "Integ full equatable idempotent: second run 0 edits")
    end
  end
end

-- ===========================================================================
-- 11. Integration: EquatableMixin full generation
-- ===========================================================================
io.write("\n--- Integration: EquatableMixin full generation ---\n")
do
  local text = [[class Config with EquatableMixin {
  final String key;
  final String value;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Integ mixin: parsed EquatableMixin class")
  if clazz then
    ok(clazz:uses_equatable(), "Integ mixin: uses_equatable returns true")
    local gen_text = generator.generate_props(clazz)
    local blocks = incremental.detect_blocks(clazz, lines)
    local edit = incremental.build_edit("props", clazz, blocks, gen_text)
    ok(edit ~= nil, "Integ mixin: props edit produced")
    if edit then
      local new_lines = incremental.apply_edits(lines, { edit })
      local new_text = table.concat(new_lines, "\n")
      ok(new_text:find("get props => [key, value]", 1, true) ~= nil, "Integ mixin: correct props getter")
    end
  end
end

-- ===========================================================================
-- 12. Full Actions Integration: Equatable data class via simulated vim.api
-- ===========================================================================
io.write("\n--- Actions Integration: Equatable data class ---\n")
do
  -- Create a fake buffer that mimics vim.api behavior
  local function make_fake_buffer_eq(initial_text)
    local buf_lines = {}
    for line in (initial_text .. "\n"):gmatch("([^\n]*)\n") do
      buf_lines[#buf_lines + 1] = line
    end

    local bufnr = 998 -- fake buffer number
    local notifications = {}

    vim.api = vim.api or {}
    vim.notify = function(msg, level)
      notifications[#notifications + 1] = { msg = msg, level = level }
    end

    vim.api.nvim_buf_line_count = function(b)
      if b == bufnr then return #buf_lines end
      return 0
    end

    vim.api.nvim_buf_get_lines = function(b, start_idx, end_idx, strict)
      if b ~= bufnr then return {} end
      local result = {}
      for i = start_idx + 1, end_idx do
        result[#result + 1] = buf_lines[i] or ""
      end
      return result
    end

    vim.api.nvim_buf_set_lines = function(b, start_idx, end_idx, strict, replacement)
      if b ~= bufnr then return end
      local new_buf = {}
      for i = 1, start_idx do
        new_buf[#new_buf + 1] = buf_lines[i]
      end
      for _, l in ipairs(replacement) do
        new_buf[#new_buf + 1] = l
      end
      for i = end_idx + 1, #buf_lines do
        new_buf[#new_buf + 1] = buf_lines[i]
      end
      buf_lines = new_buf
    end

    return bufnr, buf_lines, notifications, function() return buf_lines end
  end

  local initial_text = [[class Person extends Equatable {
  final String name;
  final int age;
}]]

  local bufnr, _, notifications, get_buf = make_fake_buffer_eq(initial_text)

  -- Step 1: Get code actions for the Equatable class
  local person_actions = actions.get_code_actions(bufnr, 1)
  ok(#person_actions > 0, "ActionsInteg Equatable: has code actions")

  -- Should have "data class" action
  local dc_action
  for _, a in ipairs(person_actions) do
    if a.title:find("data class", 1, true) then
      dc_action = a
      break
    end
  end
  ok(dc_action ~= nil, "ActionsInteg Equatable: has data class action")

  -- Should have "Add props" action
  local props_action
  for _, a in ipairs(person_actions) do
    if a.title == "Add props" then
      props_action = a
      break
    end
  end
  ok(props_action ~= nil, "ActionsInteg Equatable: has 'Add props' action")

  -- Should NOT have equality or hashCode actions
  local has_equality, has_hashcode = false, false
  for _, a in ipairs(person_actions) do
    if a.title:find("equality", 1, true) then has_equality = true end
    if a.title:find("hashCode", 1, true) then has_hashcode = true end
  end
  ok(not has_equality, "ActionsInteg Equatable: no equality action")
  ok(not has_hashcode, "ActionsInteg Equatable: no hashCode action")

  -- Should have constructor, copyWith, toString actions
  local has_ctor, has_cw, has_tostr = false, false, false
  for _, a in ipairs(person_actions) do
    if a.title:find("constructor", 1, true) then has_ctor = true end
    if a.title:find("copyWith", 1, true) then has_cw = true end
    if a.title:find("toString", 1, true) then has_tostr = true end
  end
  ok(has_ctor, "ActionsInteg Equatable: has constructor action")
  ok(has_cw, "ActionsInteg Equatable: has copyWith action")
  ok(has_tostr, "ActionsInteg Equatable: has toString action")

  if dc_action then
    -- Execute the data class action
    actions.execute_action(dc_action)

    local buf_after = get_buf()
    local text_after = table.concat(buf_after, "\n")

    -- Should have props getter
    ok(text_after:find("get props => [name, age]", 1, true) ~= nil, "ActionsInteg Equatable: generated props getter")
    -- Should have constructor
    ok(text_after:find("this.name", 1, true) ~= nil, "ActionsInteg Equatable: generated constructor")
    -- Should NOT have equality/hashCode
    ok(text_after:find("operator ==", 1, true) == nil, "ActionsInteg Equatable: no operator ==")
    ok(text_after:find("get hashCode", 1, true) == nil, "ActionsInteg Equatable: no hashCode")

    -- Now add a field and verify "Update props" action appears
    -- Simulate adding email field
    local modified_text = text_after:gsub(
      "  final int age;",
      "  final int age;\n  final String? email;"
    )
    -- Update buf_lines
    local mod_lines = {}
    for line in (modified_text .. "\n"):gmatch("([^\n]*)\n") do
      mod_lines[#mod_lines + 1] = line
    end
    -- Manually set buf_lines
    vim.api.nvim_buf_set_lines(bufnr, 0, #buf_after, false, mod_lines)

    -- Find the Person class line (may have shifted due to imports)
    local mod_buf = get_buf()
    local person_line_2 = 1
    for i, l in ipairs(mod_buf) do
      if l:match("^class Person") then
        person_line_2 = i
        break
      end
    end

    local person_actions_2 = actions.get_code_actions(bufnr, person_line_2)
    local update_props_action
    for _, a in ipairs(person_actions_2) do
      if a.title == "Update props" then
        update_props_action = a
        break
      end
    end
    ok(update_props_action ~= nil, "ActionsInteg Equatable: 'Update props' action after adding field")

    -- Should also have "Update" actions for other stale methods
    local has_update_ctor = false
    for _, a in ipairs(person_actions_2) do
      if a.title:find("Update constructor", 1, true) then has_update_ctor = true end
    end
    ok(has_update_ctor, "ActionsInteg Equatable: 'Update constructor' after adding field")
  end

  -- Clean up
  vim.api = nil
  vim.notify = nil
end

-- ===========================================================================
-- 13. Edge case: Equatable class with no fields
-- ===========================================================================
io.write("\n--- Edge case: Equatable with no fields ---\n")
do
  local text = [[class Marker extends Equatable {
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge empty equatable: parsed class")
  if clazz then
    ok(clazz:uses_equatable(), "Edge empty equatable: uses_equatable true")
    local gen_text = generator.generate_props(clazz)
    local expected = "  @override\n  List<Object?> get props => [];"
    eq(gen_text, expected, "Edge empty equatable: generates empty props")

    local blocks = incremental.detect_blocks(clazz, lines)
    local edit = incremental.build_edit("props", clazz, blocks, gen_text)
    ok(edit ~= nil, "Edge empty equatable: edit produced for empty props")
    if edit then
      local new_lines = incremental.apply_edits(lines, { edit })
      local new_text = table.concat(new_lines, "\n")
      ok(new_text:find("get props => []", 1, true) ~= nil, "Edge empty equatable: empty props inserted")
    end
  end
end

-- ===========================================================================
-- 14. Edge case: props getter ordering within class body
-- ===========================================================================
io.write("\n--- Edge case: props position in class body ---\n")
do
  -- Props should be inserted after toString (which is after hashCode in METHOD_ORDER,
  -- but since Equatable class won't have equality/hashCode, it goes after toString)
  local text = [[class Foo extends Equatable {
  final String name;
  final int age;

  const Foo({
    required this.name,
    required this.age,
  });

  @override
  String toString() =>
      'Foo(name: $name, age: $age)';
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Edge props position: parsed class")
  if clazz then
    local gen_text = generator.generate_props(clazz)
    local blocks = incremental.detect_blocks(clazz, lines)
    local edit = incremental.build_edit("props", clazz, blocks, gen_text)
    ok(edit ~= nil, "Edge props position: edit produced")
    if edit then
      local new_lines = incremental.apply_edits(lines, { edit })
      local new_text = table.concat(new_lines, "\n")
      ok(new_text:find("get props", 1, true) ~= nil, "Edge props position: props present")

      -- Props should be after toString
      local tostr_pos = new_text:find("toString()", 1, true)
      local props_pos = new_text:find("get props", 1, true)
      ok(props_pos > tostr_pos, "Edge props position: props after toString")
    end
  end
end

-- ===========================================================================
-- 15. Equatable + Regular class in same file
-- ===========================================================================
io.write("\n--- Multi-class: Equatable + Regular in same file ---\n")
do
  local text = [[class EqClass extends Equatable {
  final String name;
  final int age;
}

class RegClass {
  final String title;
  final double price;
}
]]
  local clazzes = parser.parse_classes(text)
  local eq_clazz, reg_clazz
  for _, c in ipairs(clazzes) do
    if c.name == "EqClass" then eq_clazz = c end
    if c.name == "RegClass" then reg_clazz = c end
  end

  ok(eq_clazz ~= nil, "Multi eq+reg: parsed EqClass")
  ok(reg_clazz ~= nil, "Multi eq+reg: parsed RegClass")

  if eq_clazz and reg_clazz then
    local eq_kinds = actions.applicable_kinds(eq_clazz)
    local reg_kinds = actions.applicable_kinds(reg_clazz)

    ok(eq_kinds.props == true, "Multi eq+reg: EqClass has props")
    ok(eq_kinds.equality == nil, "Multi eq+reg: EqClass no equality")
    ok(eq_kinds.hashCode == nil, "Multi eq+reg: EqClass no hashCode")

    ok(reg_kinds.props == nil, "Multi eq+reg: RegClass no props")
    ok(reg_kinds.equality == true, "Multi eq+reg: RegClass has equality")
    ok(reg_kinds.hashCode == true, "Multi eq+reg: RegClass has hashCode")
  end
end

-- ===========================================================================
-- 16. Props detection: all forms (getter/field/method, with/without @override)
-- ===========================================================================
io.write("\n--- Props detection: all forms ---\n")

-- 16a. Getter with @override (arrow) — already the default, ensure metadata
do
  local text = [[class A extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> get props => [name, age];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props detect getter+override: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props detect getter+override: detected")
    if blocks.props then
      eq(blocks.props.props_style, "getter", "Props detect getter+override: style=getter")
      eq(blocks.props.has_override, true, "Props detect getter+override: has_override=true")
      eq(#blocks.props.fields, 2, "Props detect getter+override: 2 fields")
      eq(blocks.props.fields[1], "name", "Props detect getter+override: field[1]=name")
      eq(blocks.props.fields[2], "age", "Props detect getter+override: field[2]=age")
    end
  end
end

-- 16b. Getter WITHOUT @override (arrow)
do
  local text = [[class B extends Equatable {
  final String name;

  List<Object?> get props => [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props detect getter no override: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props detect getter no override: detected")
    if blocks.props then
      eq(blocks.props.props_style, "getter", "Props detect getter no override: style=getter")
      eq(blocks.props.has_override, false, "Props detect getter no override: has_override=false")
      eq(#blocks.props.fields, 1, "Props detect getter no override: 1 field")
    end
  end
end

-- 16c. Getter with block body { return [...]; }
do
  local text = [[class C extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> get props {
    return [name, age];
  }
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props detect getter block: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props detect getter block: detected")
    if blocks.props then
      eq(blocks.props.props_style, "getter", "Props detect getter block: style=getter")
      eq(blocks.props.has_override, true, "Props detect getter block: has_override=true")
      eq(#blocks.props.fields, 2, "Props detect getter block: 2 fields")
    end
  end
end

-- 16d. Field: final List<Object?> props = [...];
do
  local text = [[class D extends Equatable {
  final String name;
  final int age;

  @override
  final List<Object?> props = [name, age];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props detect field: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props detect field: detected")
    if blocks.props then
      eq(blocks.props.props_style, "field", "Props detect field: style=field")
      eq(blocks.props.has_override, true, "Props detect field: has_override=true")
      eq(#blocks.props.fields, 2, "Props detect field: 2 fields")
    end
  end
end

-- 16e. Field without @override
do
  local text = [[class E extends Equatable {
  final String name;

  final List<Object?> props = [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props detect field no override: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props detect field no override: detected")
    if blocks.props then
      eq(blocks.props.props_style, "field", "Props detect field no override: style=field")
      eq(blocks.props.has_override, false, "Props detect field no override: has_override=false")
    end
  end
end

-- 16f. Field: final props = [...]; (inferred type)
do
  local text = [[class F extends Equatable {
  final String name;

  final props = [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props detect field inferred type: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props detect field inferred type: detected")
    if blocks.props then
      eq(blocks.props.props_style, "field", "Props detect field inferred type: style=field")
    end
  end
end

-- 16g. Method: List<Object?> props() => [...];
do
  local text = [[class G extends Equatable {
  final String name;

  List<Object?> props() => [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props detect method arrow: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props detect method arrow: detected")
    if blocks.props then
      eq(blocks.props.props_style, "method", "Props detect method arrow: style=method")
      eq(blocks.props.has_override, false, "Props detect method arrow: has_override=false")
    end
  end
end

-- 16h. Method with block body
do
  local text = [[class H extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> props() {
    return [name, age];
  }
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props detect method block: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props detect method block: detected")
    if blocks.props then
      eq(blocks.props.props_style, "method", "Props detect method block: style=method")
      eq(blocks.props.has_override, true, "Props detect method block: has_override=true")
      eq(#blocks.props.fields, 2, "Props detect method block: 2 fields")
    end
  end
end

-- 16i. Method: props() => [...]; (no return type)
do
  local text = [[class I extends Equatable {
  final String name;

  props() => [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props detect method no return type: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props detect method no return type: detected")
    if blocks.props then
      eq(blocks.props.props_style, "method", "Props detect method no return type: style=method")
    end
  end
end

-- ===========================================================================
-- 17. Style-preserving update: existing props get [...] replaced in-place
-- ===========================================================================
io.write("\n--- Style-preserving props update ---\n")

-- 17a. Getter arrow: update by replacing [...] content
do
  local text = [[class PA extends Equatable {
  final String name;
  final int age;
  final String email;

  @override
  List<Object?> get props => [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props update getter arrow: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props update getter arrow: block detected")
    local gen_text = generator.generate_props(clazz, blocks.props)
    ok(gen_text:find("@override", 1, true) ~= nil, "Props update getter arrow: preserved @override")
    ok(gen_text:find("get props =>", 1, true) ~= nil, "Props update getter arrow: preserved getter arrow")
    ok(gen_text:find("[name, age, email]", 1, true) ~= nil, "Props update getter arrow: updated fields")
    -- Should NOT contain duplicate @override or get props
    local _, count = gen_text:gsub("@override", "@override")
    eq(count, 1, "Props update getter arrow: single @override")
  end
end

-- 17b. Getter arrow WITHOUT @override: update preserves no-@override
do
  local text = [[class PB extends Equatable {
  final String name;
  final int age;

  List<Object?> get props => [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props update getter no override: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props update getter no override: block detected")
    local gen_text = generator.generate_props(clazz, blocks.props)
    ok(gen_text:find("@override") == nil, "Props update getter no override: no @override added")
    ok(gen_text:find("get props =>", 1, true) ~= nil, "Props update getter no override: preserved getter")
    ok(gen_text:find("[name, age]", 1, true) ~= nil, "Props update getter no override: updated fields")
  end
end

-- 17c. Getter block body: update replaces [...]
do
  local text = [[class PC extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> get props {
    return [name];
  }
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props update getter block: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props update getter block: block detected")
    local gen_text = generator.generate_props(clazz, blocks.props)
    ok(gen_text:find("@override", 1, true) ~= nil, "Props update getter block: preserved @override")
    ok(gen_text:find("get props", 1, true) ~= nil, "Props update getter block: preserved getter")
    ok(gen_text:find("return %[name, age%]") ~= nil, "Props update getter block: updated fields")
    -- Should NOT have =>
    ok(gen_text:find("=>") == nil, "Props update getter block: no arrow")
  end
end

-- 17d. Field with @override: update replaces [...] content
do
  local text = [[class PD extends Equatable {
  final String name;
  final int age;

  @override
  final List<Object?> props = [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props update field: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props update field: block detected")
    local gen_text = generator.generate_props(clazz, blocks.props)
    ok(gen_text:find("@override", 1, true) ~= nil, "Props update field: preserved @override")
    ok(gen_text:find("final List<Object%?> props = ", 1, false) ~= nil, "Props update field: preserved field syntax")
    ok(gen_text:find("[name, age]", 1, true) ~= nil, "Props update field: updated fields")
  end
end

-- 17e. Method arrow: update replaces [...] content
do
  local text = [[class PE extends Equatable {
  final String name;
  final int age;

  List<Object?> props() => [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props update method arrow: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props update method arrow: block detected")
    local gen_text = generator.generate_props(clazz, blocks.props)
    ok(gen_text:find("props%(%) =>", 1, false) ~= nil, "Props update method arrow: preserved method arrow")
    ok(gen_text:find("[name, age]", 1, true) ~= nil, "Props update method arrow: updated fields")
  end
end

-- 17f. Method block: update replaces [...] content
do
  local text = [[class PF extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> props() {
    return [name];
  }
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props update method block: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props update method block: block detected")
    local gen_text = generator.generate_props(clazz, blocks.props)
    ok(gen_text:find("@override", 1, true) ~= nil, "Props update method block: preserved @override")
    ok(gen_text:find("props%(%)", 1, false) ~= nil, "Props update method block: preserved method")
    ok(gen_text:find("return %[name, age%]") ~= nil, "Props update method block: updated fields")
  end
end

-- ===========================================================================
-- 18. Idempotency for all styles: running update twice produces no edits
-- ===========================================================================
io.write("\n--- Idempotency for all props styles ---\n")

-- 18a. Getter arrow (default) — add then verify idempotent
do
  local text = [[class IA extends Equatable {
  final String name;
  final int age;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Idempotent getter arrow: parsed")
  if clazz then
    local kinds = { "constructor", "toString", "props" }
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines, kinds)
    ok(edit_count > 0, "Idempotent getter arrow: edits produced")
    ok(new_text:find("get props =>", 1, true) ~= nil, "Idempotent getter arrow: props generated")
    verify_idempotent(new_lines, new_text, "IA", kinds)
  end
end

-- 18b. Getter arrow existing — update then verify idempotent
do
  local text = [[class IB extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> get props => [name, age];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Idempotent getter arrow existing: parsed")
  if clazz then
    local kinds = { "props" }
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines, kinds)
    eq(edit_count, 0, "Idempotent getter arrow existing: no edits (already up to date)")
    verify_idempotent(new_lines, new_text, "IB", kinds)
  end
end

-- 18c. Getter block — update stale then verify idempotent
do
  local text = [[class IC extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> get props {
    return [name];
  }
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Idempotent getter block: parsed")
  if clazz then
    local kinds = { "props" }
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines, kinds)
    ok(edit_count > 0, "Idempotent getter block: edits produced (stale)")
    ok(new_text:find("return %[name, age%]") ~= nil, "Idempotent getter block: updated fields")
    verify_idempotent(new_lines, new_text, "IC", kinds)
  end
end

-- 18d. Field style — update stale then verify idempotent
do
  local text = [[class ID extends Equatable {
  final String name;
  final int age;

  @override
  final List<Object?> props = [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Idempotent field: parsed")
  if clazz then
    local kinds = { "props" }
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines, kinds)
    ok(edit_count > 0, "Idempotent field: edits produced (stale)")
    ok(new_text:find("[name, age]", 1, true) ~= nil, "Idempotent field: updated fields")
    verify_idempotent(new_lines, new_text, "ID", kinds)
  end
end

-- 18e. Method arrow — update stale then verify idempotent
do
  local text = [[class IE extends Equatable {
  final String name;
  final int age;

  List<Object?> props() => [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Idempotent method arrow: parsed")
  if clazz then
    local kinds = { "props" }
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines, kinds)
    ok(edit_count > 0, "Idempotent method arrow: edits produced (stale)")
    verify_idempotent(new_lines, new_text, "IE", kinds)
  end
end

-- 18f. Method block — update stale then verify idempotent
do
  local text = [[class IF extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> props() {
    return [name];
  }
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Idempotent method block: parsed")
  if clazz then
    local kinds = { "props" }
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines, kinds)
    ok(edit_count > 0, "Idempotent method block: edits produced (stale)")
    verify_idempotent(new_lines, new_text, "IF", kinds)
  end
end

-- ===========================================================================
-- 19. "Add props" vs "Update props" action title based on detection
-- ===========================================================================
io.write("\n--- Add vs Update props based on detection ---\n")

-- 19a. No props exists → action title = "Add props"
do
  local text = [[class NoProps extends Equatable {
  final String name;
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Add vs Update: no props parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props == nil, "Add vs Update: no props block detected")
    local class_fields = incremental.get_class_field_names(clazz)
    local status = incremental.props_status(blocks.props, class_fields)
    eq(status, "absent", "Add vs Update: status is absent")
    eq(actions.action_title("props", status), "Add props", "Add vs Update: title is 'Add props'")
  end
end

-- 19b. Props exists as field → action title = "Update props"
do
  local text = [[class HasFieldProps extends Equatable {
  final String name;
  final int age;

  @override
  final List<Object?> props = [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Add vs Update: field props parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Add vs Update: field props detected")
    local class_fields = incremental.get_class_field_names(clazz)
    local status = incremental.props_status(blocks.props, class_fields)
    eq(status, "stale", "Add vs Update: field status is stale")
    eq(actions.action_title("props", status), "Update props", "Add vs Update: title is 'Update props'")
  end
end

-- 19c. Props exists as method → action title = "Update props"
do
  local text = [[class HasMethodProps extends Equatable {
  final String name;
  final int age;

  List<Object?> props() => [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Add vs Update: method props parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Add vs Update: method props detected")
    local class_fields = incremental.get_class_field_names(clazz)
    local status = incremental.props_status(blocks.props, class_fields)
    eq(status, "stale", "Add vs Update: method status is stale")
    eq(actions.action_title("props", status), "Update props", "Add vs Update: title is 'Update props'")
  end
end

-- 19d. Props complete (all fields match) → still "Update props" (not "Add")
do
  local text = [[class HasCompleteProps extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> get props => [name, age];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Add vs Update: complete props parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Add vs Update: complete props detected")
    local class_fields = incremental.get_class_field_names(clazz)
    local status = incremental.props_status(blocks.props, class_fields)
    eq(status, "complete", "Add vs Update: status is complete")
    eq(actions.action_title("props", status), "Update props", "Add vs Update: title is 'Update props' for complete")
  end
end

-- ===========================================================================
-- 20. apply_single_action for props: all styles
-- ===========================================================================
io.write("\n--- apply_single_action for props ---\n")

-- 20a. Add props to class with no props
do
  local text = [[class AddProps extends Equatable {
  final String name;
  final int age;
}
]]
  local _, lines = parse_class_lines(text)
  local new_lines, new_text, edits = apply_single_action(lines, "AddProps", "props")
  ok(edits > 0, "apply_single props add: edits produced")
  ok(new_text:find("@override", 1, true) ~= nil, "apply_single props add: has @override")
  ok(new_text:find("get props =>", 1, true) ~= nil, "apply_single props add: has getter")
  ok(new_text:find("[name, age]", 1, true) ~= nil, "apply_single props add: correct fields")
  -- Idempotent
  local new_lines2, _, edits2 = apply_single_action(new_lines, "AddProps", "props")
  eq(edits2, 0, "apply_single props add: idempotent")
end

-- 20b. Update existing getter arrow
do
  local text = [[class UpdateGetter extends Equatable {
  final String name;
  final int age;
  final String email;

  @override
  List<Object?> get props => [name];
}
]]
  local _, lines = parse_class_lines(text)
  local new_lines, new_text, edits = apply_single_action(lines, "UpdateGetter", "props")
  ok(edits > 0, "apply_single props update getter: edits produced")
  ok(new_text:find("[name, age, email]", 1, true) ~= nil, "apply_single props update getter: all fields")
  ok(new_text:find("get props =>", 1, true) ~= nil, "apply_single props update getter: still getter arrow")
  -- Idempotent
  local _, _, edits2 = apply_single_action(new_lines, "UpdateGetter", "props")
  eq(edits2, 0, "apply_single props update getter: idempotent")
end

-- 20c. Update existing field
do
  local text = [[class UpdateField extends Equatable {
  final String name;
  final int age;

  @override
  final List<Object?> props = [name];
}
]]
  local _, lines = parse_class_lines(text)
  local new_lines, new_text, edits = apply_single_action(lines, "UpdateField", "props")
  ok(edits > 0, "apply_single props update field: edits produced")
  ok(new_text:find("[name, age]", 1, true) ~= nil, "apply_single props update field: all fields")
  ok(new_text:find("final List<Object%?> props = ") ~= nil, "apply_single props update field: still field")
  -- Idempotent
  local _, _, edits2 = apply_single_action(new_lines, "UpdateField", "props")
  eq(edits2, 0, "apply_single props update field: idempotent")
end

-- 20d. Update existing method arrow
do
  local text = [[class UpdateMethod extends Equatable {
  final String name;
  final int age;

  List<Object?> props() => [name];
}
]]
  local _, lines = parse_class_lines(text)
  local new_lines, new_text, edits = apply_single_action(lines, "UpdateMethod", "props")
  ok(edits > 0, "apply_single props update method: edits produced")
  ok(new_text:find("[name, age]", 1, true) ~= nil, "apply_single props update method: all fields")
  ok(new_text:find("props%(%) =>", 1, false) ~= nil, "apply_single props update method: still method arrow")
  -- Idempotent
  local _, _, edits2 = apply_single_action(new_lines, "UpdateMethod", "props")
  eq(edits2, 0, "apply_single props update method: idempotent")
end

-- 20e. Update existing method block
do
  local text = [[class UpdateMethodBlock extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> props() {
    return [name];
  }
}
]]
  local _, lines = parse_class_lines(text)
  local new_lines, new_text, edits = apply_single_action(lines, "UpdateMethodBlock", "props")
  ok(edits > 0, "apply_single props update method block: edits produced")
  ok(new_text:find("return %[name, age%]") ~= nil, "apply_single props update method block: updated fields")
  ok(new_text:find("@override", 1, true) ~= nil, "apply_single props update method block: preserved @override")
  -- Idempotent
  local _, _, edits2 = apply_single_action(new_lines, "UpdateMethodBlock", "props")
  eq(edits2, 0, "apply_single props update method block: idempotent")
end

-- ===========================================================================
-- 21. apply_update_existing for props: update stale field/method/getter
-- ===========================================================================
io.write("\n--- apply_update_existing for props ---\n")

-- 21a. Stale getter → updated
do
  local text = [[class UGetter extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> get props => [name];
}
]]
  local _, lines = parse_class_lines(text)
  local new_lines, new_text, edit_count = apply_update_existing(lines, "UGetter")
  ok(edit_count > 0, "apply_update_existing getter: edits produced")
  ok(new_text:find("[name, age]", 1, true) ~= nil, "apply_update_existing getter: fields updated")
  -- Idempotent
  local _, _, edit_count2 = apply_update_existing(new_lines, "UGetter")
  eq(edit_count2, 0, "apply_update_existing getter: idempotent")
end

-- 21b. Stale field → updated
do
  local text = [[class UField extends Equatable {
  final String name;
  final int age;

  @override
  final List<Object?> props = [name];
}
]]
  local _, lines = parse_class_lines(text)
  local new_lines, new_text, edit_count = apply_update_existing(lines, "UField")
  ok(edit_count > 0, "apply_update_existing field: edits produced")
  ok(new_text:find("[name, age]", 1, true) ~= nil, "apply_update_existing field: fields updated")
  local _, _, edit_count2 = apply_update_existing(new_lines, "UField")
  eq(edit_count2, 0, "apply_update_existing field: idempotent")
end

-- 21c. Stale method arrow → updated
do
  local text = [[class UMethodArrow extends Equatable {
  final String name;
  final int age;

  List<Object?> props() => [name];
}
]]
  local _, lines = parse_class_lines(text)
  local new_lines, new_text, edit_count = apply_update_existing(lines, "UMethodArrow")
  ok(edit_count > 0, "apply_update_existing method arrow: edits produced")
  ok(new_text:find("[name, age]", 1, true) ~= nil, "apply_update_existing method arrow: fields updated")
  local _, _, edit_count2 = apply_update_existing(new_lines, "UMethodArrow")
  eq(edit_count2, 0, "apply_update_existing method arrow: idempotent")
end

-- 21d. Stale method block → updated
do
  local text = [[class UMethodBlock extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> props() {
    return [name];
  }
}
]]
  local _, lines = parse_class_lines(text)
  local new_lines, new_text, edit_count = apply_update_existing(lines, "UMethodBlock")
  ok(edit_count > 0, "apply_update_existing method block: edits produced")
  ok(new_text:find("return %[name, age%]") ~= nil, "apply_update_existing method block: fields updated")
  local _, _, edit_count2 = apply_update_existing(new_lines, "UMethodBlock")
  eq(edit_count2, 0, "apply_update_existing method block: idempotent")
end

-- ===========================================================================
-- 22. No duplicate props: ensure a second props is NEVER created
-- ===========================================================================
io.write("\n--- No duplicate props ---\n")

-- 22a. Class with existing field props → generate_all_incremental with "props" kind should update, not add
do
  local text = [[class NoDup extends Equatable {
  final String name;
  final int age;

  final List<Object?> props = [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "No dup props field: parsed")
  if clazz then
    local kinds = { "constructor", "toString", "props" }
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines, kinds)
    ok(edit_count > 0, "No dup props field: edits produced")
    -- Count how many times "props" appears as a member (not in field declarations)
    local count = 0
    for _ in new_text:gmatch("props%s*=") do count = count + 1 end
    for _ in new_text:gmatch("get%s+props") do count = count + 1 end
    for _ in new_text:gmatch("props%(%)") do count = count + 1 end
    eq(count, 1, "No dup props field: exactly one props member")
  end
end

-- 22b. Class with method props → props kind should update, not add a second
do
  local text = [[class NoDupMethod extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> props() => [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "No dup props method: parsed")
  if clazz then
    local kinds = { "constructor", "toString", "props" }
    local new_lines, new_text, edit_count = generate_all_incremental(clazz, lines, kinds)
    ok(edit_count > 0, "No dup props method: edits produced")
    local count = 0
    for _ in new_text:gmatch("props%s*=") do count = count + 1 end
    for _ in new_text:gmatch("get%s+props") do count = count + 1 end
    for _ in new_text:gmatch("props%(%)") do count = count + 1 end
    eq(count, 1, "No dup props method: exactly one props member")
  end
end

-- ===========================================================================
-- 23. Field removal: orphan fields removed when class field is deleted
-- ===========================================================================
io.write("\n--- Props field removal (orphans) ---\n")
do
  -- Start with 3 fields, props has all 3
  local text = [[class Orphan extends Equatable {
  final String name;
  final int age;

  @override
  List<Object?> get props => [name, age, email];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Props orphan removal: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Props orphan removal: block detected")
    local class_fields = incremental.get_class_field_names(clazz)
    local status = incremental.props_status(blocks.props, class_fields)
    eq(status, "stale", "Props orphan removal: status is stale (orphan email)")

    -- Generate updated props — should only have name and age (email is orphan)
    local gen_text = generator.generate_props(clazz, blocks.props)
    ok(gen_text:find("[name, age]", 1, true) ~= nil, "Props orphan removal: email removed")
    ok(gen_text:find("email") == nil, "Props orphan removal: no email in output")
  end
end

-- ===========================================================================
-- 24. Getter without explicit type: "get props => ..." shorthand
-- ===========================================================================
io.write("\n--- Getter shorthand detection ---\n")
do
  local text = [[class Short extends Equatable {
  final String name;

  @override
  get props => [name];
}
]]
  local clazz, lines = parse_class_lines(text)
  ok(clazz ~= nil, "Getter shorthand: parsed")
  if clazz then
    local blocks = incremental.detect_blocks(clazz, lines)
    ok(blocks.props ~= nil, "Getter shorthand: detected")
    if blocks.props then
      eq(blocks.props.props_style, "getter", "Getter shorthand: style=getter")
    end
  end
end
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
