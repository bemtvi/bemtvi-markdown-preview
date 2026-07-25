-- nxvim-markdown-preview — a live, browser-based markdown preview for nxvim, built
-- entirely on the native `nx.*` plugin API (ADR 0002): no core changes.
--
-- The editor serves bytes over a single `nx.http.mount`; the browser renders. The page
-- polls the mount, so a live edit shows up on the next poll with no server push, and one
-- page previews EVERY open markdown buffer — a sidebar to switch, plus a follow-the-
-- editor mode. Because it is a mount (not a bound port), the identical plugin runs on the
-- web build too, where a Service Worker satisfies the same routes.
--
-- Module map:
--   server.lua   which buffers are markdown + the on_request routing (pure, testable)
--   page.lua     the self-contained preview page (marked + mermaid, client-side)
--
-- Quick start (init.lua): require("nxvim-markdown-preview").setup() — then :MarkdownPreview.

local server = require("nxvim-markdown-preview.server")

local M = {}

-- The one live mount handle for the session, or nil before the first preview. The mount
-- is bound lazily (nothing opens a port until the user asks) and then REUSED: a second
-- :MarkdownPreview just re-opens the browser at the same stable URL.
local mount = nil
-- A mount is a one-shot promise; while it is settling, hold the promise so two quick
-- :MarkdownPreview calls chain onto ONE bind instead of racing two `on_request` names.
local pending = nil

local function notify(msg, level)
  nx.notify("nxvim-markdown-preview: " .. msg, level)
end

-- A rejection handler for a chain whose failure is already reported elsewhere.
local function ignore() end

-- Bind the mount if it is not up yet, resolving with the handle either way. Idempotent:
-- returns the live handle, or the in-flight bind, or starts one.
local function ensure_mount()
  if mount and mount:is_open() then
    return nx.promise.resolve(mount)
  end
  if pending then
    return pending
  end
  pending = nx.http
    .mount({ name = "nxvim-markdown-preview", on_request = server.handle })
    :next(function(m)
      mount = m
      pending = nil
      return m
    end)
    :catch(function(err)
      pending = nil
      -- A bind failure (the port is taken) or a duplicate name REJECTS — never a silent
      -- fallback to another port. Re-raise so :MarkdownPreview surfaces it.
      error(err)
    end)
  return pending
end

-- :MarkdownPreview — mount (lazily) and open the preview in the real browser. The page
-- follows the current buffer, so this Just Works from whichever markdown file is focused.
function M.open()
  ensure_mount()
    :next(function(m)
      -- A :MarkdownPreviewStop that landed while this bind was in flight retires the
      -- mount the moment it comes up. Say so rather than opening a browser tab on a URL
      -- that is already 404ing; running :MarkdownPreview again binds a fresh one.
      if not m:is_open() then
        return notify("the preview was stopped before it finished starting")
      end
      nx.ui.open(m:url())
      notify("preview open at " .. m:url())
    end)
    :catch(function(err)
      local msg = type(err) == "table" and err.message or err
      notify("could not mount the preview: " .. tostring(msg), nx.log.levels.ERROR)
    end)
end

-- :MarkdownPreviewStop — retire the mount. The URL starts 404ing; open tabs show
-- "editor gone". Reopening rebinds under the same name (a stable, bookmarkable URL).
function M.stop()
  -- A bind still in flight has no handle to close yet, and reporting "no preview is
  -- running" would be a lie that leaves a mount coming up behind the user's back. Chain
  -- the close onto the bind instead, so the stop lands whenever the mount does.
  if pending then
    -- A bind that never came up is already reported by whoever asked to open it, so this
    -- chain — which only ever has a mount to close — swallows that same rejection.
    pending
      :next(function(m)
        if mount == m then
          mount = nil
        end
        m:close()
      end)
      :catch(ignore)
    return notify("preview stopped (it was still starting)")
  end
  if not (mount and mount:is_open()) then
    return notify("no preview is running")
  end
  mount:close()
  mount = nil
  notify("preview stopped")
end

-- `M.url()` -> the mount's URL, or nil when nothing is mounted. For scripting / a
-- statusline segment that wants to show where the preview lives.
function M.url()
  return (mount and mount:is_open()) and mount:url() or nil
end

local registered = false

-- setup() — register the user commands. Idempotent (safe to call from `plugin/` AND from
-- a user's init.lua). It does NOT bind the mount: nothing opens a port until
-- :MarkdownPreview.
function M.setup()
  if registered then
    return
  end
  registered = true

  nx.user_command.create("MarkdownPreview", function()
    M.open()
  end, { desc = "Open a live markdown preview in the browser" })

  nx.user_command.create("MarkdownPreviewStop", function()
    M.stop()
  end, { desc = "Stop the markdown preview mount" })

  nx.user_command.create("MarkdownPreviewToggle", function()
    if M.url() then
      M.stop()
    else
      M.open()
    end
  end, { desc = "Toggle the markdown preview" })
end

return M
