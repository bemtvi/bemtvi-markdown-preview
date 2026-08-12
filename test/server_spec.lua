-- The request layer: buffer discovery and the on_request routing. Driven directly with
-- a fake `req`/`respond` — the routing is pure over editor state, so no socket, no real
-- HTTP, no browser. Run with `bemtvi --test-plugin .`.

local server = require("bemtvi-markdown-preview.server")

-- Drive the mount handler and return the response table. Awaits, because some routes
-- (`/file`) respond only after an async disk read; the sync routes resolve immediately.
local function request(path, query)
  return btv.await(btv.promise.new(function(resolve)
    server.handle(
      { method = "GET", path = path, query = query or {}, name = "bemtvi-markdown-preview" },
      resolve
    )
  end))
end

-- Open `path` in a fresh buffer with `lines` as its contents, and return its bufnr.
local function open(t, path, lines)
  t:cmd("edit " .. path)
  btv.await(btv.buf.set_lines(0, 0, -1, false, lines)) -- set_lines is async; await it landing
  return btv.buf.current()
end

-- Find the entry for bufnr `id` in a `M.buffers().list`, or nil.
local function entry_for(list, id)
  for _, e in ipairs(list) do
    if e.id == id then
      return e
    end
  end
  return nil
end

-- A real 2x1 png, byte for byte — header, IHDR, a deflated IDAT, IEND. A genuine binary
-- fixture rather than a text file called `.png`, because what `/asset` has to get right is
-- carrying bytes through unharmed: half of these are invalid UTF-8, so a route that decoded
-- them as text (or a transport that did) would mangle or reject them and the assertion on
-- the exact bytes below would catch it.
local PNG = table.concat({
  "\137\80\78\71\13\10\26\10",
  "\0\0\0\13\73\72\68\82\0\0\0\2\0\0\0\1\8\2\0\0\0\123\64\232\221",
  "\0\0\0\15\73\68\65\84\120\156\99\248\207\192\192\192\240\31\0\7\0\1\255\126\8\177\208",
  "\0\0\0\0\73\69\78\68\174\66\96\130",
})

btv.test.describe("bemtvi-markdown-preview.server", function()
  local DIR

  btv.test.before_each(function()
    DIR = btv.test.tempdir()
  end)

  btv.test.it("classifies markdown by extension and by filetype, not others", function(t)
    local md = open(t, DIR .. "/a.md", { "# hi" })
    btv.test.expect(server._is_markdown(md)).to_be_truthy()

    -- No .md extension, but filetype=markdown still counts.
    local ft = open(t, DIR .. "/notes", { "x" })
    btv.bo.filetype = "markdown"
    btv.test.expect(server._is_markdown(ft)).to_be_truthy()

    -- A plain text buffer is not markdown.
    local txt = open(t, DIR .. "/b.txt", { "plain" })
    btv.test.expect(server._is_markdown(txt)).to_be_falsy()
  end)

  btv.test.it("/buffers lists markdown buffers with labels and marks the active one", function(t)
    local md = open(t, DIR .. "/doc.md", { "# doc" })
    open(t, DIR .. "/plain.txt", { "not md" }) -- must NOT appear

    local res = request("/buffers")
    btv.test.expect(res.status or 200).to_be(200)
    btv.test.expect(res.headers["content-type"]).to_contain("application/json")

    local data = btv.json.decode(res.body)
    local e = entry_for(data.list, md)
    btv.test.expect(e).to_be_truthy()
    btv.test.expect(e.label).to_be("doc.md")
    btv.test.expect(e.name).to_contain("doc.md")
    -- The .txt buffer is absent.
    local txt = btv.buf.nr(DIR .. "/plain.txt")
    btv.test.expect(entry_for(data.list, txt)).to_be_nil()
  end)

  btv.test.it("active is the current buffer when markdown, absent otherwise", function(t)
    local md = open(t, DIR .. "/live.md", { "hello" })
    btv.test.expect(btv.json.decode(request("/buffers").body).active).to_be(md)

    -- Switch to a non-markdown buffer: active drops to nil (JSON: the key is absent).
    open(t, DIR .. "/x.txt", { "y" })
    btv.test.expect(btv.json.decode(request("/buffers").body).active).to_be_nil()
  end)

  btv.test.it("reports the 1-based cursor line of the active markdown buffer", function(t)
    open(t, DIR .. "/cur.md", { "# one", "para two", "para three", "para four" })
    t:feed("3G") -- move the cursor to line 3
    btv.test.expect(btv.json.decode(request("/buffers").body).cursor).to_be(3)

    -- No cursor line when the current buffer is not markdown.
    open(t, DIR .. "/plain.txt", { "a", "b" })
    btv.test.expect(btv.json.decode(request("/buffers").body).cursor).to_be_nil()
  end)

  btv.test.it("reports buffer names as ABSOLUTE paths, even when opened relatively", function(t)
    -- Opened by a RELATIVE name — btv.buf.name would return "rel.md", which the page must
    -- not use as a link base (it would resolve docs/x.md against /rel.md).
    t:cmd("cd " .. DIR)
    t:cmd("edit rel.md")
    btv.await(btv.buf.set_lines(0, 0, -1, false, { "# rel" }))

    local e = entry_for(btv.json.decode(request("/buffers").body).list, btv.buf.current())
    btv.test.expect(e).to_be_truthy()
    btv.test.expect(e.name:sub(1, 1)).to_be("/") -- absolute, not "rel.md"
    btv.test.expect(e.name).to_contain("/rel.md")
    btv.test.expect(e.label).to_be("rel.md")
  end)

  btv.test.it("/source returns the buffer's current text, no-store", function(t)
    local md = open(t, DIR .. "/edit.md", { "line one", "line two" })
    local res = request("/source", { buf = tostring(md) })
    btv.test.expect(res.status or 200).to_be(200)
    btv.test.expect(res.body).to_be("line one\nline two")
    btv.test.expect(res.headers["cache-control"]).to_be("no-store")

    -- It reflects a live edit on the next request (this is what makes the poll live).
    btv.await(btv.buf.set_lines(0, 0, -1, false, { "changed" }))
    btv.test.expect(request("/source", { buf = tostring(md) }).body).to_be("changed")
  end)

  btv.test.it("/source 404s an unknown or non-markdown buffer, and a missing buf", function(t)
    open(t, DIR .. "/real.md", { "x" })
    btv.test.expect(request("/source", { buf = "99999" }).status).to_be(404)
    btv.test.expect(request("/source", {}).status).to_be(404)

    -- A real buffer that is not markdown is not addressable through /source either.
    local txt = open(t, DIR .. "/no.txt", { "x" })
    btv.test.expect(request("/source", { buf = tostring(txt) }).status).to_be(404)
  end)

  btv.test.it("excludes scratch surfaces that only look like markdown", function(t)
    -- An LSP hover float, a rendered doc panel, a plugin dashboard: `nofile` buffers
    -- carrying markdown content and often a markdown-ish name, none of them a document
    -- to preview. `btv.view` mints exactly that shape, and 'buftype' is what tells them
    -- apart from a file — not the name, and not the filetype.
    local md = open(t, DIR .. "/real.md", { "# real" })
    local view = btv.view.create({ name = "notes.md", filetype = "markdown" })
    local scratch = btv.await(btv.wait_for(function()
      return view:bufnr()
    end, { tries = 50, interval = 10, message = "view buffer never appeared" }))

    -- Both signals the classifier would otherwise trust say "markdown" here.
    btv.test.expect(btv.bo[scratch].filetype).to_be("markdown")
    btv.test.expect(btv.bo[scratch].buftype).to_be("nofile")
    btv.test.expect(server._is_markdown(scratch)).to_be_falsy()

    -- It is absent from /buffers, while the file-backed buffer is there …
    local data = btv.json.decode(request("/buffers").body)
    btv.test.expect(entry_for(data.list, scratch)).to_be_nil()
    btv.test.expect(entry_for(data.list, md)).to_be_truthy()
    -- … and it is not addressable through /source either.
    btv.test.expect(request("/source", { buf = tostring(scratch) }).status).to_be(404)
  end)

  btv.test.it("/source refuses buf=0, which would mean 'whatever is focused'", function(t)
    open(t, DIR .. "/focused.md", { "# secret-ish" })
    -- `btv.buf.*` reads 0 as the current buffer, so an unbounded ?buf=0 off the wire would
    -- serve whatever the editor happens to be showing.
    btv.test.expect(request("/source", { buf = "0" }).status).to_be(404)
    btv.test.expect(request("/source", { buf = "-1" }).status).to_be(404)
    btv.test.expect(request("/source", { buf = "1.5" }).status).to_be(404)
    btv.test.expect(request("/source", { buf = "not-a-number" }).status).to_be(404)
  end)

  btv.test.it(
    "classifies a path as markdown by extension alone (for links to closed files)",
    function()
      btv.test.expect(server._md_ext("/repo/docs/guide.md")).to_be_truthy()
      btv.test.expect(server._md_ext("/repo/README.markdown")).to_be_truthy()
      btv.test.expect(server._md_ext("/repo/notes.txt")).to_be_falsy()
      btv.test.expect(server._md_ext("/repo/Makefile")).to_be_falsy()
      -- Only the LAST dot-component is the extension. Reading "en.md" as the extension
      -- would call an ordinary markdown file something else — and disagree with the
      -- page's own MD_RE, so the link it offers would come back 403 from /file.
      btv.test.expect(server._md_ext("/repo/README.en.md")).to_be_truthy()
      btv.test.expect(server._md_ext("/repo/CHANGELOG.v2.md")).to_be_truthy()
      btv.test.expect(server._md_ext("/repo/archive.tar.gz")).to_be_falsy()
    end
  )

  btv.test.it("previews a multi-part name like README.en.md end to end", function(t)
    local md = open(t, DIR .. "/README.en.md", { "# hi" })
    btv.test.expect(entry_for(btv.json.decode(request("/buffers").body).list, md)).to_be_truthy()
    btv.test.expect(request("/source", { buf = tostring(md) }).body).to_be("# hi")

    -- And /file serves one that is only on disk (the page links to these).
    t:cmd("cd " .. DIR)
    btv.await(btv.fs.write(DIR .. "/GUIDE.v2.md", "# guide\n"))
    btv.test.expect(request("/file", { path = DIR .. "/GUIDE.v2.md" }).body).to_contain("# guide")
  end)

  btv.test.it("bounds a workspace root of / to everything, not nothing", function()
    -- The prefix test appends the separator, so a root of "/" would ask for "//" — no
    -- canonical path starts that way, and an editor launched at the filesystem root
    -- would refuse every file instead of allowing them all.
    btv.test.expect(server._contains("/", "/etc/x.md")).to_be_truthy()
    btv.test.expect(server._contains("/repo", "/repo/x.md")).to_be_truthy()
    btv.test.expect(server._contains("/repo", "/repo")).to_be_truthy()
    -- A sibling that merely shares the prefix is still out of bounds.
    btv.test.expect(server._contains("/repo", "/repository/x.md")).to_be_falsy()
  end)

  btv.test.it("answers a non-GET with 405 rather than serving it", function(t)
    open(t, DIR .. "/a.md", { "# a" })
    local res = btv.await(btv.promise.new(function(resolve)
      server.handle({ method = "POST", path = "/buffers", query = {} }, resolve)
    end))
    btv.test.expect(res.status).to_be(405)
    btv.test.expect(res.headers["allow"]).to_contain("GET")
  end)

  btv.test.it("/file reads a markdown file from disk, even with no buffer open", function(t)
    -- A file on disk that is NOT opened as a buffer, in a subdir of the workspace.
    btv.await(btv.fs.mkdir(DIR .. "/docs"))
    local path = DIR .. "/docs/linked.md"
    btv.await(btv.fs.write(path, "# Linked\n\nfrom disk\n"))
    t:cmd("cd " .. DIR) -- point the workspace root at DIR so the file is in-bounds

    local res = request("/file", { path = path })
    btv.test.expect(res.status or 200).to_be(200)
    btv.test.expect(res.body).to_contain("# Linked")
    btv.test.expect(res.headers["cache-control"]).to_be("no-store")
  end)

  btv.test.it("/file refuses a non-markdown file, an escape, and a missing path", function(t)
    t:cmd("cd " .. DIR)
    btv.await(btv.fs.write(DIR .. "/notes.txt", "secret"))
    -- Non-markdown extension: refused before any disk read.
    btv.test.expect(request("/file", { path = DIR .. "/notes.txt" }).status).to_be(403)
    -- Missing / non-string path.
    btv.test.expect(request("/file", {}).status).to_be(403)
    -- A real markdown file OUTSIDE the workspace: it resolves (so this exercises the
    -- containment check, not a read miss) but is refused. Canonicalizing both sides is
    -- what stops /var vs /private/var from fooling the bound.
    local outside = btv.test.tempdir() .. "/elsewhere.md"
    btv.await(btv.fs.write(outside, "# not yours\n"))
    btv.test.expect(request("/file", { path = outside }).status).to_be(403)
    -- In-bounds name but no such file: a 404, not a 200.
    btv.test.expect(request("/file", { path = DIR .. "/nope.md" }).status).to_be(404)
  end)

  btv.test.it("/asset serves an image's raw bytes from disk", function(t)
    t:cmd("cd " .. DIR)
    btv.await(btv.fs.mkdir(DIR .. "/img"))
    btv.await(btv.fs.write(DIR .. "/img/logo.dark.png", PNG))

    local res = request("/asset", { path = DIR .. "/img/logo.dark.png" })
    btv.test.expect(res.status or 200).to_be(200)
    -- The extension picks the type, and the browser is told not to re-guess it.
    btv.test.expect(res.headers["content-type"]).to_be("image/png")
    btv.test.expect(res.headers["x-content-type-options"]).to_be("nosniff")
    -- Byte-for-byte: not decoded, not re-encoded, not truncated at the first NUL.
    btv.test.expect(#res.body).to_be(#PNG)
    btv.test.expect(res.body).to_be(PNG)
  end)

  btv.test.it("/asset denies everything when an image is opened AS a document", function(t)
    -- An SVG is also a document. In an `<img>` its script never runs, but a browser pointed
    -- straight at this URL renders it as a page on the MOUNT'S origin, where script could
    -- read `/source`. The CSP is inert for the `<img>` case and denies all for the other.
    t:cmd("cd " .. DIR)
    btv.await(btv.fs.write(DIR .. "/d.svg", '<svg xmlns="http://www.w3.org/2000/svg"/>'))
    local res = request("/asset", { path = DIR .. "/d.svg" })
    btv.test.expect(res.headers["content-type"]).to_be("image/svg+xml")
    btv.test.expect(res.headers["content-security-policy"]).to_be("default-src 'none'; sandbox")
  end)

  btv.test.it("maps an image extension to its content type, last component only", function()
    btv.test.expect(server._img_type("/w/a.png")).to_be("image/png")
    btv.test.expect(server._img_type("/w/a.JPG")).to_be("image/jpeg")
    btv.test.expect(server._img_type("/w/a.jpeg")).to_be("image/jpeg")
    btv.test.expect(server._img_type("/w/logo.dark.svg")).to_be("image/svg+xml")
    -- Not an image, so not something /asset will hand out.
    btv.test.expect(server._img_type("/w/notes.md")).to_be_nil()
    btv.test.expect(server._img_type("/w/secrets.env")).to_be_nil()
    btv.test.expect(server._img_type("/w/Makefile")).to_be_nil()
  end)

  btv.test.it("/asset is an image route, not a static file server", function(t)
    t:cmd("cd " .. DIR)
    btv.await(btv.fs.write(DIR .. "/secrets.env", "TOKEN=hunter2"))
    -- A readable file inside the workspace that simply is not an image: refused before any
    -- disk read, so the route cannot be used to walk the repo for arbitrary content.
    btv.test.expect(request("/asset", { path = DIR .. "/secrets.env" }).status).to_be(403)
    btv.test.expect(request("/asset", {}).status).to_be(403)

    -- A real image OUTSIDE the workspace resolves but is still out of bounds …
    local outside = btv.test.tempdir() .. "/elsewhere.png"
    btv.await(btv.fs.write(outside, PNG))
    btv.test.expect(request("/asset", { path = outside }).status).to_be(403)
    -- … and so is a `..` walk out of the workspace onto a file that really is there
    -- (which is what makes this exercise the containment check rather than a read miss).
    local up = DIR:match("^(.*)/[^/]+$") .. "/escaped.png"
    btv.await(btv.fs.write(up, PNG))
    btv.test.expect(request("/asset", { path = DIR .. "/../escaped.png" }).status).to_be(403)
    -- In-bounds image name but no such file: a 404, not a 200.
    btv.test.expect(request("/asset", { path = DIR .. "/nope.png" }).status).to_be(404)
  end)

  btv.test.it("/ serves the HTML page with a CSP, and unknown paths 404", function()
    local root = request("/")
    btv.test.expect(root.status or 200).to_be(200)
    btv.test.expect(root.headers["content-type"]).to_contain("text/html")
    btv.test.expect(root.headers["content-security-policy"]).to_be_truthy()
    btv.test.expect(root.body).to_contain("<!doctype html>")

    btv.test.expect(request("/nope").status).to_be(404)
  end)
end)
