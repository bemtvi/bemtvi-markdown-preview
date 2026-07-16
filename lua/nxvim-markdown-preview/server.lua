-- The mount's request layer: which buffers count as markdown, and how a single
-- `on_request(req, respond)` routes into the three endpoints the page talks to.
--
-- Everything here is a PURE function of the editor state (`nx.buf.*`) plus `req` — the
-- lifecycle (binding the mount, opening the browser) lives in init.lua. That split is
-- what lets `test/*_spec.lua` drive `handle` with a fake `req`/`respond` and never need
-- a real socket: the mount is plumbing, the routing is the behaviour under test.

local page = require("nxvim-markdown-preview.page")

local M = {}

-- Extensions that mark a buffer as markdown when its `filetype` has not been set (a
-- freshly-listed but never-entered buffer has no `filetype` yet). Lower-cased match.
local MD_EXT = {
  md = true,
  markdown = true,
  mdown = true,
  mkd = true,
  mkdn = true,
  mdx = true,
  ["markdown.mdx"] = true,
}

-- The basename of a path, or `"[No Name]"` for an unnamed buffer — the label the
-- sidebar shows. Never the full path: a preview picker wants the filename.
local function basename(name)
  if name == nil or name == "" then
    return "[No Name]"
  end
  return name:match("[^/]+$") or name
end

-- Is `buf` a markdown buffer? `filetype == "markdown"` is the primary signal (the user
-- set it, or the editor derived it); the extension is the fallback for a listed buffer
-- that has never been entered and so has no filetype yet.
local function is_markdown(buf)
  if not nx.buf.is_valid(buf) then
    return false
  end
  if nx.buf.get_option(buf, "filetype") == "markdown" then
    return true
  end
  local ext = nx.buf.name(buf):lower():match("%.([%w.]+)$")
  return ext ~= nil and MD_EXT[ext] == true
end

-- `M.buffers()` -> `{ active = <bufnr|nil>, list = { { id, name, label }, ... } }`
--
-- Every open markdown buffer, ascending, plus which one the editor currently shows
-- (`active`, nil when the current buffer is not markdown). The page renders `active` in
-- follow mode and lists `list` in the sidebar.
function M.buffers()
  local list = {}
  for _, id in ipairs(nx.buf.list()) do
    if is_markdown(id) then
      local name = nx.buf.name(id)
      list[#list + 1] = { id = id, name = name, label = basename(name) }
    end
  end
  local cur = nx.buf.current()
  return { active = is_markdown(cur) and cur or nil, list = list }
end

-- The raw markdown text of `buf`, or nil when it is not a listed markdown buffer. The
-- membership check matters: `/source?buf=` takes a number off the wire, so it is bounded
-- to the buffers the page was told about rather than reading whatever bufnr was asked
-- for.
local function source_of(buf)
  for _, entry in ipairs(M.buffers().list) do
    if entry.id == buf then
      return table.concat(nx.buf.lines(buf, 0, -1), "\n")
    end
  end
  return nil
end

local JSON =
  { ["content-type"] = "application/json; charset=utf-8", ["cache-control"] = "no-store" }
local TEXT = { ["content-type"] = "text/plain; charset=utf-8", ["cache-control"] = "no-store" }

-- `M.handle(req, respond)` — the mount's `on_request`. Routes on `req.path`, which is
-- MOUNT-RELATIVE (a GET of `/plugin/<name>/source` arrives here as `"/source"`), so the
-- same routing works under any origin — the native port and the web Service Worker
-- alike.
--
--   "/"          the page shell (marked + mermaid render client-side)
--   "/buffers"   JSON { active, list } — the open markdown buffers, polled by the page
--   "/source"    ?buf=<n> — that buffer's raw text, polled and rendered by the page
--
-- Anything else is the plugin's own 404 (the editor only 404s a name that is not
-- mounted at all).
function M.handle(req, respond)
  if req.path == "/" then
    respond({ headers = page.headers(), body = page.html() })
  elseif req.path == "/buffers" then
    respond({ headers = JSON, body = nx.json.encode(M.buffers()) })
  elseif req.path == "/source" then
    local buf = tonumber(req.query and req.query.buf)
    local text = buf and source_of(buf) or nil
    if text == nil then
      respond({ status = 404, headers = TEXT, body = "no such markdown buffer\n" })
    else
      respond({ headers = TEXT, body = text })
    end
  else
    respond({ status = 404, headers = TEXT, body = "no such page: " .. req.path .. "\n" })
  end
end

-- Exposed for the specs (pure helpers otherwise local to routing).
M._is_markdown = is_markdown
M._basename = basename

return M
