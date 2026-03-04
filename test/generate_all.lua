-- Generate full Dart output for all classes and print to stdout
-- Usage: lua test/generate_all.lua > /tmp/dart_test_output.dart

package.path = "lua/?.lua;" .. package.path

-- Stub vim for running outside Neovim
if not vim then
  _G.vim = {
    deepcopy = function(tbl)
      local copy = {}
      for k, v in pairs(tbl) do
        if type(v) == "table" then
          copy[k] = _G.vim.deepcopy(v)
        else
          copy[k] = v
        end
      end
      return copy
    end,
    fn = { getcwd = function() return "." end },
    log = { levels = { WARN = 2, INFO = 1 } },
    notify = function() end,
  }
end

local parser = require("dart-class-tools.parser")
local generator = require("dart-class-tools.generator")

-- Read the input file
local f = io.open("test/fixtures/input_class.dart", "r")
if not f then
  io.stderr:write("Cannot open input_class.dart\n")
  os.exit(1)
end
local text = f:read("*a")
f:close()

local clazzes = parser.parse_classes(text)

-- Split input text into lines
local buf_lines = {}
for line in (text .. "\n"):gmatch("([^\n]*)\n") do
  buf_lines[#buf_lines + 1] = line
end

-- Collect all imports
local all_imports = {}
local all_class_outputs = {}

for _, clazz in ipairs(clazzes) do
  local result = generator.generate(clazz, nil)
  if result then
    local new_lines, imports = generator.build_class_text(buf_lines, clazz, result)
    if imports then
      for _, imp in ipairs(imports) do
        local found = false
        for _, existing in ipairs(all_imports) do
          if existing == imp then found = true; break end
        end
        if not found then
          all_imports[#all_imports + 1] = imp
        end
      end
    end
    all_class_outputs[#all_class_outputs + 1] = table.concat(new_lines, "\n")
  else
    -- Output the raw class lines (e.g., enums without fields that generate nothing)
    local raw_lines = {}
    for i = clazz.starts_at_line, clazz.ends_at_line do
      raw_lines[#raw_lines + 1] = buf_lines[i]
    end
    all_class_outputs[#all_class_outputs + 1] = table.concat(raw_lines, "\n")
  end
end

-- Print imports
for _, imp in ipairs(all_imports) do
  print("import '" .. imp .. "';")
end
if #all_imports > 0 then
  print("")
end

-- Print enum declarations that have no properties (Status) as-is
-- and all class/enum outputs
for i, output in ipairs(all_class_outputs) do
  print(output)
  if i < #all_class_outputs then
    print("")
  end
end
