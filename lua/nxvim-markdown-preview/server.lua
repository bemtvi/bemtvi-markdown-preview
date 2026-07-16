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

-- A buffer's name made ABSOLUTE. `nx.buf.name` returns the name AS OPENED — often relative
-- (`:edit README.md` -> `"README.md"`), which the page must not use as a link base or it
-- resolves `docs/x.md` against `/README.md`. `":p"` joins it onto the cwd; an unnamed
-- buffer stays `""` (never the bare cwd `":p"` would hand back for an empty name).
local function abspath(name)
  if name == nil or name == "" then
    return ""
  end
  return vim.fn.fnamemodify(name, ":p")
end

-- Does this path *look* like markdown (by extension)? The classifier for a file the
-- page links to but that is not (yet) an open buffer — so it has no `filetype`.
local function md_ext(name)
  local ext = tostring(name):lower():match("%.([%w.]+)$")
  return ext ~= nil and MD_EXT[ext] == true
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
  return md_ext(nx.buf.name(buf))
end

-- The workspace root that bounds `/file`: the editor's cwd (a `--workspace` launch cds
-- here at boot; a daemon session cds on the remote). `/file` serves markdown UNDER this
-- and nothing else, so a link cannot walk the mount out to arbitrary disk.
local function root()
  return vim.fn.getcwd()
end

-- Is `canon` (an already-canonical path) inside `root_canon`? Plain prefix test, correct
-- only because BOTH sides came through `nx.fs.realpath` — symlinks and `..` resolved — so
-- `/var/folders/...` vs its `/private/var/...` real path cannot disagree.
local function contains(root_canon, canon)
  return canon == root_canon or canon:sub(1, #root_canon + 1) == root_canon .. "/"
end

-- `M.buffers()` -> `{ active = <bufnr|nil>, root = <cwd>, list = { { id, name, label }, ... } }`
--
-- Every open markdown buffer, ascending, plus which one the editor currently shows
-- (`active`, nil when the current buffer is not markdown) and the workspace `root` (so
-- the page can label a linked disk file relative to it). The page renders `active` in
-- follow mode and lists `list` in the sidebar.
function M.buffers()
  local list = {}
  for _, id in ipairs(nx.buf.list()) do
    if is_markdown(id) then
      local name = abspath(nx.buf.name(id))
      list[#list + 1] = { id = id, name = name, label = basename(name) }
    end
  end
  local cur = nx.buf.current()
  return { active = is_markdown(cur) and cur or nil, root = root(), list = list }
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

-- Serve a markdown file by absolute `path`, read from DISK — for a link to a file that is
-- not open as a buffer. Bounded to markdown inside the workspace: a non-markdown name is
-- refused up front (403), and the path is canonicalized alongside the root and checked for
-- containment (403 when it escapes — a `..` walk or a symlink pointing out), so a request
-- off the wire cannot reach arbitrary disk. A path that cannot be read is a 404.
local function serve_file(path, respond)
  if type(path) ~= "string" or not md_ext(path) then
    respond({ status = 403, headers = TEXT, body = "not a markdown file\n" })
    return
  end
  nx.fs
    .realpath(root())
    :next(function(root_canon)
      return nx.fs.realpath(path):next(function(canon)
        if not contains(root_canon, canon) then
          respond({ status = 403, headers = TEXT, body = "outside the workspace\n" })
        else
          return nx.fs.read_text(path):next(function(text)
            respond({ headers = TEXT, body = text })
          end)
        end
      end)
    end)
    :catch(function()
      respond({ status = 404, headers = TEXT, body = "cannot read: " .. tostring(path) .. "\n" })
    end)
end

-- `M.handle(req, respond)` — the mount's `on_request`. Routes on `req.path`, which is
-- MOUNT-RELATIVE (a GET of `/plugin/<name>/source` arrives here as `"/source"`), so the
-- same routing works under any origin — the native port and the web Service Worker
-- alike.
--
--   "/"          the page shell (marked + mermaid render client-side)
--   "/buffers"   JSON { active, root, list } — the open markdown buffers, polled by the page
--   "/source"    ?buf=<n> — that buffer's raw text, polled and rendered by the page
--   "/file"      ?path=<abs> — a markdown file's text read from DISK, for a link to a
--                file that is not open as a buffer. Bounded to markdown under `root()`.
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
  elseif req.path == "/file" then
    serve_file(req.query and req.query.path, respond)
  else
    respond({ status = 404, headers = TEXT, body = "no such page: " .. req.path .. "\n" })
  end
end

-- Exposed for the specs (pure helpers otherwise local to routing).
M._is_markdown = is_markdown
M._basename = basename
M._md_ext = md_ext

return M
