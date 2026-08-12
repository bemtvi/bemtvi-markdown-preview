-- The mount's request layer: which buffers count as markdown, and how a single
-- `on_request(req, respond)` routes into the three endpoints the page talks to.
--
-- Everything here is a PURE function of the editor state (`btv.buf.*`) plus `req` — the
-- lifecycle (binding the mount, opening the browser) lives in init.lua. That split is
-- what lets `test/*_spec.lua` drive `handle` with a fake `req`/`respond` and never need
-- a real socket: the mount is plumbing, the routing is the behaviour under test.

local page = require("bemtvi-markdown-preview.page")

local M = {}

-- Extensions that mark a buffer as markdown when its `filetype` has not been set (a
-- freshly-listed but never-entered buffer has no `filetype` yet). Lower-cased match.
-- Keep this in step with the page's own `MD_RE`: the page decides which links to
-- navigate, `/file` decides which paths it will serve, and a disagreement between the
-- two is a link that navigates to a 403.
local MD_EXT = {
  md = true,
  markdown = true,
  mdown = true,
  mkd = true,
  mkdn = true,
  mdx = true,
}

-- The image types `/asset` will hand to the page, and the `content-type` each is served
-- with. A closed list, not a general static-file server: the route exists so an image
-- committed next to a document renders, and every name outside this table is refused.
-- Sniffing the bytes is deliberately NOT done — the extension decides, and the response
-- carries `nosniff` so the browser does not second-guess it either.
local IMG_TYPE = {
  png = "image/png",
  apng = "image/apng",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  avif = "image/avif",
  bmp = "image/bmp",
  ico = "image/x-icon",
  svg = "image/svg+xml",
}

-- The basename of a path, or `"[No Name]"` for an unnamed buffer — the label the
-- sidebar shows. Never the full path: a preview picker wants the filename.
local function basename(name)
  if name == nil or name == "" then
    return "[No Name]"
  end
  return name:match("[^/]+$") or name
end

-- A buffer's name made ABSOLUTE. `btv.buf.name` returns the name AS OPENED — often relative
-- (`:edit README.md` -> `"README.md"`), which the page must not use as a link base or it
-- resolves `docs/x.md` against `/README.md`. `":p"` joins it onto the cwd; an unnamed
-- buffer stays `""` (never the bare cwd `":p"` would hand back for an empty name).
local function abspath(name)
  if name == nil or name == "" then
    return ""
  end
  return btv.fname.modify(name, ":p")
end

-- Does this path *look* like markdown (by extension)? The classifier for a file the
-- page links to but that is not (yet) an open buffer — so it has no `filetype`.
--
-- Only the LAST dot-component counts. A greedy `[%w.]+` would read `README.en.md` as the
-- extension `"en.md"` and call a perfectly ordinary markdown file something else — and
-- the page's own `MD_RE` (anchored to the final extension) would disagree, so the link it
-- offered to navigate would come back 403 from `/file`.
local function md_ext(name)
  local ext = tostring(name):lower():match("%.(%w+)$")
  return ext ~= nil and MD_EXT[ext] == true
end

-- The `content-type` for an image path, or nil when the name is not an image `/asset`
-- serves. Same last-dot-component rule as `md_ext`, so `logo.dark.png` is a png.
local function img_type(name)
  local ext = tostring(name):lower():match("%.(%w+)$")
  return ext ~= nil and IMG_TYPE[ext] or nil
end

-- Is `buf` a markdown *document* the preview should offer?
--
-- `'buftype'` first: it is `""` for exactly the file-backed buffers a user edits, and
-- anything else (`nofile`, `help`, `terminal`, `quickfix`, `prompt`) is a scratch surface
-- — an LSP hover float, a rendered doc panel, a plugin dashboard. Plenty of those carry
-- `filetype=markdown`, and none is a document to preview; `'buftype'` is the canonical
-- signal for that distinction, so gate on it rather than sniffing names.
--
-- Then `filetype == "markdown"` (the user set it, or the editor derived it), with the
-- extension as the fallback for a listed buffer that has never been entered and so has no
-- filetype yet.
local function is_markdown(buf)
  if not btv.buf.is_valid(buf) then
    return false
  end
  if (btv.buf.get_option(buf, "buftype") or "") ~= "" then
    return false
  end
  if btv.buf.get_option(buf, "filetype") == "markdown" then
    return true
  end
  return md_ext(btv.buf.name(buf))
end

-- The workspace root that bounds `/file`: the editor's cwd (a `--workspace` launch cds
-- here at boot; a daemon session cds on the remote). `/file` serves markdown UNDER this
-- and nothing else, so a link cannot walk the mount out to arbitrary disk.
local function root()
  return vim.fn.getcwd()
end

-- Is `canon` (an already-canonical path) inside `root_canon`? Plain prefix test, correct
-- only because BOTH sides came through `btv.fs.realpath` — symlinks and `..` resolved — so
-- `/var/folders/...` vs its `/private/var/...` real path cannot disagree. A root of `/`
-- is its own case: appending the separator would ask for the prefix `"//"`, which no
-- canonical path has, so an editor launched at the filesystem root would refuse every
-- file instead of allowing them all.
local function contains(root_canon, canon)
  if root_canon == "/" then
    return canon:sub(1, 1) == "/"
  end
  return canon == root_canon or canon:sub(1, #root_canon + 1) == root_canon .. "/"
end

-- `M.buffers()` -> `{ active, cursor, root, list = { { id, name, label }, ... } }`
--
-- Every open markdown buffer, ascending, plus which one the editor currently shows
-- (`active`, nil when the current buffer is not markdown), the 1-based `cursor` line in
-- that active buffer (nil when there is none), and the workspace `root` (so the page can
-- label a linked disk file relative to it). The page renders `active` in follow mode,
-- lists `list` in the sidebar, and marks the `cursor` line when it is showing `active`.
function M.buffers()
  local list = {}
  for _, id in ipairs(btv.buf.list()) do
    if is_markdown(id) then
      local name = abspath(btv.buf.name(id))
      list[#list + 1] = { id = id, name = name, label = basename(name) }
    end
  end
  local cur = btv.buf.current()
  local active = is_markdown(cur) and cur or nil
  -- The cursor belongs to the current window; report its line only when that current
  -- buffer is the markdown one on show, so the page never marks a line in the wrong doc.
  local cursor = active and btv.cursor.get()[1] or nil
  return { active = active, cursor = cursor, root = root(), list = list }
end

-- The raw markdown text of `buf`, or nil when it is not a live markdown buffer. The
-- membership check matters: `/source?buf=` takes a number off the wire, so it is bounded
-- to the buffers the page was told about rather than reading whatever bufnr was asked
-- for. `is_markdown` IS that bound — it starts with `btv.buf.is_valid`, which is exactly
-- "this handle is one of the open buffers", and `M.buffers()` filters on nothing else.
-- (Going through `M.buffers()` would absolutize every open buffer's name to answer a
-- question about one, on a route the page polls twice a second.)
--
-- `0` and negatives are rejected up front: `btv.buf.*` reads `0` as "the current buffer",
-- so a bare `?buf=0` off the wire would otherwise address whatever is focused.
local function source_of(buf)
  if type(buf) ~= "number" or buf < 1 or buf % 1 ~= 0 then
    return nil
  end
  if not is_markdown(buf) then
    return nil
  end
  return table.concat(btv.buf.lines(buf, 0, -1), "\n")
end

local JSON =
  { ["content-type"] = "application/json; charset=utf-8", ["cache-control"] = "no-store" }
local TEXT = { ["content-type"] = "text/plain; charset=utf-8", ["cache-control"] = "no-store" }

-- The workspace gate every DISK route goes through. Canonicalizes `path` alongside the
-- root, and either hands the CANONICAL path to `read` (whose promise it returns) or answers
-- `respond` itself: 403 when the path escapes the workspace (a `..` walk, or a symlink
-- pointing out), 404 when nothing along the way resolves or reads.
--
-- One gate, shared, because `/file` and `/asset` differ only in what they do with the bytes
-- — and a second copy of a containment check is a second chance to get it subtly wrong.
-- `read` is handed `canon` rather than `path` because `canon` is what the check proved;
-- reading anything else re-opens the gap it closed.
local function serve_bounded(path, respond, read)
  btv.fs
    .realpath(root())
    :next(function(root_canon)
      return btv.fs.realpath(path):next(function(canon)
        if not contains(root_canon, canon) then
          respond({ status = 403, headers = TEXT, body = "outside the workspace\n" })
        else
          return read(canon)
        end
      end)
    end)
    :catch(function()
      respond({ status = 404, headers = TEXT, body = "cannot read: " .. tostring(path) .. "\n" })
    end)
end

-- Serve a markdown file by absolute `path`, read from DISK — for a link to a file that is
-- not open as a buffer. Bounded to markdown inside the workspace, so a request off the wire
-- cannot reach arbitrary disk; a non-markdown name is refused (403) before any disk read.
local function serve_file(path, respond)
  if type(path) ~= "string" or not md_ext(path) then
    respond({ status = 403, headers = TEXT, body = "not a markdown file\n" })
    return
  end
  serve_bounded(path, respond, function(canon)
    return btv.fs.read_text(canon):next(function(text)
      respond({ headers = TEXT, body = text })
    end)
  end)
end

-- Serve an IMAGE by absolute `path`, read from DISK as raw bytes — for a `![](img/x.png)`
-- in the document. The browser has no filesystem, so an image beside the file it is
-- rendering can only reach the page through the mount; without this route every relative
-- image in a document renders broken.
--
-- Bounded exactly like `/file`: inside the workspace, and only the names in `IMG_TYPE`
-- (403 otherwise) — so this is an image route, not a general static-file server that would
-- hand any byte under the cwd to whatever asked.
local function serve_asset(path, respond)
  local ctype = type(path) == "string" and img_type(path) or nil
  if not ctype then
    respond({ status = 403, headers = TEXT, body = "not an image file\n" })
    return
  end
  serve_bounded(path, respond, function(canon)
    -- `read`, not `read_text`: these are bytes, and decoding them as text would both
    -- corrupt them and reject (EILSEQ) on the first non-UTF-8 byte of any real png.
    return btv.fs.read(canon):next(function(bytes)
      respond({
        headers = {
          ["content-type"] = ctype,
          ["cache-control"] = "no-store",
          -- The extension chose the type; don't let the browser choose a different one.
          ["x-content-type-options"] = "nosniff",
          -- An SVG is the one image format that is also a document: inside an `<img>` its
          -- scripts never run, but a browser pointed straight at this URL would render it
          -- as a page ON THE MOUNT'S ORIGIN, where script could then read `/source`. This
          -- CSP is ignored when the response is used as an image and denies everything
          -- when it is used as a document, which closes that without costing the `<img>`
          -- anything.
          ["content-security-policy"] = "default-src 'none'; sandbox",
        },
        body = bytes,
      })
    end)
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
--   "/asset"     ?path=<abs> — an image's raw bytes read from DISK, for a relative
--                `![](…)` in the document. Bounded to images under `root()`.
--
-- Anything else is the plugin's own 404 (the editor only 404s a name that is not
-- mounted at all). Every route READS — nothing here mutates the editor — so anything but
-- a GET/HEAD is a 405 rather than being quietly served as if it were a GET.
function M.handle(req, respond)
  local method = req.method or "GET"
  if method ~= "GET" and method ~= "HEAD" then
    respond({
      status = 405,
      headers = {
        ["content-type"] = "text/plain; charset=utf-8",
        ["cache-control"] = "no-store",
        ["allow"] = "GET, HEAD",
      },
      body = "the preview is read-only: GET or HEAD\n",
    })
    return
  end

  local path = req.path or "/"
  if path == "/" then
    respond({ headers = page.headers(), body = page.html() })
  elseif path == "/buffers" then
    respond({ headers = JSON, body = btv.json.encode(M.buffers()) })
  elseif path == "/source" then
    local text = source_of(tonumber(req.query and req.query.buf))
    if text == nil then
      respond({ status = 404, headers = TEXT, body = "no such markdown buffer\n" })
    else
      respond({ headers = TEXT, body = text })
    end
  elseif path == "/file" then
    serve_file(req.query and req.query.path, respond)
  elseif path == "/asset" then
    serve_asset(req.query and req.query.path, respond)
  else
    respond({ status = 404, headers = TEXT, body = "no such page: " .. path .. "\n" })
  end
end

-- Exposed for the specs (pure helpers otherwise local to routing).
M._is_markdown = is_markdown
M._basename = basename
M._md_ext = md_ext
M._img_type = img_type
M._contains = contains

return M
