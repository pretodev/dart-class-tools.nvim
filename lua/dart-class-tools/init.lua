local actions = require("dart-class-tools.actions")
local generator = require("dart-class-tools.generator")

local M = {}

--- Default configuration.
local defaults = {
  -- Code generation options
  use_equatable = false,
  use_as_cast = true,
  use_default_values = false,
  use_jenkins_hash = false,
  use_value_getter = false,
  constructor_default_values = false,
  json_key_format = "variable", -- "variable" | "snake_case" | "camelCase"

  -- Keymaps (set to false to disable)
  keymaps = {
    -- Run code action picker on <leader>dc
    code_action = "<leader>dc",
  },
}

--- Setup the plugin.
---@param opts? table
function M.setup(opts)
  opts = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Apply config to generator
  generator.config = {
    use_equatable = opts.use_equatable,
    use_as_cast = opts.use_as_cast,
    use_default_values = opts.use_default_values,
    use_jenkins_hash = opts.use_jenkins_hash,
    use_value_getter = opts.use_value_getter,
    constructor_default_values = opts.constructor_default_values,
    json_key_format = opts.json_key_format,
  }

  -- Register code action source for Dart files
  M._register_code_action_source()

  -- Set up user commands
  vim.api.nvim_create_user_command("DartClassGenerate", function()
    M.show_code_actions()
  end, { desc = "Generate Dart data class methods" })

  -- Set up keymaps for Dart files
  if opts.keymaps then
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "dart",
      callback = function(ev)
        if opts.keymaps.code_action then
          vim.keymap.set("n", opts.keymaps.code_action, function()
            M.show_code_actions()
          end, { buffer = ev.buf, desc = "Dart class tools: code actions" })
        end
      end,
    })
  end
end

--- Show code actions via vim.ui.select.
function M.show_code_actions()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]

  local code_actions = actions.get_code_actions(bufnr, cursor_line)

  if #code_actions == 0 then
    vim.notify("dart-class-tools: no code actions available at cursor position", vim.log.levels.INFO)
    return
  end

  vim.ui.select(code_actions, {
    prompt = "Dart Class Tools",
    format_item = function(item)
      return item.title
    end,
  }, function(choice)
    if choice then
      actions.execute_action(choice)
    end
  end)
end

--- Register a code action source using null-ls style approach
--- or native Neovim code actions via textDocument/codeAction.
function M._register_code_action_source()
  -- Use a custom code action handler that hooks into vim.lsp.buf.code_action
  -- We register an autocmd that provides our actions alongside LSP actions

  local group = vim.api.nvim_create_augroup("DartClassTools", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "dart",
    callback = function(ev)
      -- Register our code action source for this buffer
      M._attach_code_actions(ev.buf)
    end,
  })
end

--- Attach code action capability to a buffer.
---@param bufnr number
function M._attach_code_actions(bufnr)
  -- Create a fake LSP client that provides code actions
  -- This integrates with vim.lsp.buf.code_action() seamlessly

  local client_id = M._ensure_client()
  if client_id then
    -- Attach client to buffer if not already attached
    local attached = false
    for _, id in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
      if id.id == client_id then
        attached = true
        break
      end
    end
    if not attached then
      pcall(vim.lsp.buf_attach_client, bufnr, client_id)
    end
  end
end

--- Ensure our virtual LSP client exists and return its ID.
---@return number|nil
function M._ensure_client()
  if M._client_id then
    -- Check if client still exists
    local client = vim.lsp.get_client_by_id(M._client_id)
    if client then return M._client_id end
  end

  -- Use vim.lsp.start to create a minimal LSP client
  local client_id = vim.lsp.start({
    name = "dart-class-tools",
    cmd = function(dispatchers)
      -- This is a virtual client - no real server process
      local closing = false
      return {
        request = function(method, params, callback, notify_reply_callback)
          if method == "textDocument/codeAction" then
            -- Handle code action request
            local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
            local cursor_line = params.range.start.line + 1 -- Convert 0-indexed to 1-indexed

            local raw_actions = actions.get_code_actions(bufnr, cursor_line)
            local lsp_actions = {}

            for _, action in ipairs(raw_actions) do
              lsp_actions[#lsp_actions + 1] = {
                title = action.title,
                kind = vim.lsp.protocol.CodeActionKind.QuickFix,
                command = {
                  title = action.title,
                  command = "dart-class-tools.execute",
                  arguments = { action },
                },
              }
            end

            callback(nil, lsp_actions)
            return true, 1
          elseif method == "initialize" then
            callback(nil, {
              capabilities = {
                codeActionProvider = true,
              },
            })
            return true, 1
          elseif method == "shutdown" then
            callback(nil, nil)
            return true, 1
          end
          return true, 1
        end,
        notify = function(method, params)
          if method == "exit" then
            closing = true
          end
          return true
        end,
        is_closing = function()
          return closing
        end,
        terminate = function()
          closing = true
        end,
      }
    end,
    filetypes = { "dart" },
    root_dir = vim.fn.getcwd(),
    handlers = {
      ["workspace/executeCommand"] = function(err, result, ctx)
        if ctx.params and ctx.params.command == "dart-class-tools.execute" then
          local action = ctx.params.arguments[1]
          if action then
            actions.execute_action(action)
          end
        end
      end,
    },
    commands = {
      ["dart-class-tools.execute"] = function(cmd, ctx)
        local action = cmd.arguments[1]
        if action then
          actions.execute_action(action)
        end
      end,
    },
    on_init = function(client, _)
      client.server_capabilities = client.server_capabilities or {}
      client.server_capabilities.codeActionProvider = true
    end,
  }, { bufnr = vim.api.nvim_get_current_buf() })

  M._client_id = client_id
  return client_id
end

return M
