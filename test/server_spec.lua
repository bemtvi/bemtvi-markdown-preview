-- The request layer: buffer discovery and the on_request routing. Driven directly with
-- a fake `req`/`respond` — the routing is pure over editor state, so no socket, no real
-- HTTP, no browser. Run with `nxvim --test-plugin .`.

local server = require("nxvim-markdown-preview.server")

-- Drive the mount handler and return the response table. Awaits, because some routes
-- (`/file`) respond only after an async disk read; the sync routes resolve immediately.
local function request(path, query)
  return nx.await(nx.promise.new(function(resolve)
    server.handle(
      { method = "GET", path = path, query = query or {}, name = "nxvim-markdown-preview" },
      resolve
    )
  end))
end

-- Open `path` in a fresh buffer with `lines` as its contents, and return its bufnr.
local function open(t, path, lines)
  t:cmd("edit " .. path)
  nx.await(nx.buf.set_lines(0, 0, -1, false, lines)) -- set_lines is async; await it landing
  return nx.buf.current()
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

nx.test.describe("nxvim-markdown-preview.server", function()
  local DIR

  nx.test.before_each(function()
    DIR = nx.test.tempdir()
  end)

  nx.test.it("classifies markdown by extension and by filetype, not others", function(t)
    local md = open(t, DIR .. "/a.md", { "# hi" })
    nx.test.expect(server._is_markdown(md)).to_be_truthy()

    -- No .md extension, but filetype=markdown still counts.
    local ft = open(t, DIR .. "/notes", { "x" })
    nx.bo.filetype = "markdown"
    nx.test.expect(server._is_markdown(ft)).to_be_truthy()

    -- A plain text buffer is not markdown.
    local txt = open(t, DIR .. "/b.txt", { "plain" })
    nx.test.expect(server._is_markdown(txt)).to_be_falsy()
  end)

  nx.test.it("/buffers lists markdown buffers with labels and marks the active one", function(t)
    local md = open(t, DIR .. "/doc.md", { "# doc" })
    open(t, DIR .. "/plain.txt", { "not md" }) -- must NOT appear

    local res = request("/buffers")
    nx.test.expect(res.status or 200).to_be(200)
    nx.test.expect(res.headers["content-type"]).to_contain("application/json")

    local data = nx.json.decode(res.body)
    local e = entry_for(data.list, md)
    nx.test.expect(e).to_be_truthy()
    nx.test.expect(e.label).to_be("doc.md")
    nx.test.expect(e.name).to_contain("doc.md")
    -- The .txt buffer is absent.
    local txt = nx.buf.nr(DIR .. "/plain.txt")
    nx.test.expect(entry_for(data.list, txt)).to_be_nil()
  end)

  nx.test.it("active is the current buffer when markdown, absent otherwise", function(t)
    local md = open(t, DIR .. "/live.md", { "hello" })
    nx.test.expect(nx.json.decode(request("/buffers").body).active).to_be(md)

    -- Switch to a non-markdown buffer: active drops to nil (JSON: the key is absent).
    open(t, DIR .. "/x.txt", { "y" })
    nx.test.expect(nx.json.decode(request("/buffers").body).active).to_be_nil()
  end)

  nx.test.it("reports buffer names as ABSOLUTE paths, even when opened relatively", function(t)
    -- Opened by a RELATIVE name — nx.buf.name would return "rel.md", which the page must
    -- not use as a link base (it would resolve docs/x.md against /rel.md).
    t:cmd("cd " .. DIR)
    t:cmd("edit rel.md")
    nx.await(nx.buf.set_lines(0, 0, -1, false, { "# rel" }))

    local e = entry_for(nx.json.decode(request("/buffers").body).list, nx.buf.current())
    nx.test.expect(e).to_be_truthy()
    nx.test.expect(e.name:sub(1, 1)).to_be("/") -- absolute, not "rel.md"
    nx.test.expect(e.name).to_contain("/rel.md")
    nx.test.expect(e.label).to_be("rel.md")
  end)

  nx.test.it("/source returns the buffer's current text, no-store", function(t)
    local md = open(t, DIR .. "/edit.md", { "line one", "line two" })
    local res = request("/source", { buf = tostring(md) })
    nx.test.expect(res.status or 200).to_be(200)
    nx.test.expect(res.body).to_be("line one\nline two")
    nx.test.expect(res.headers["cache-control"]).to_be("no-store")

    -- It reflects a live edit on the next request (this is what makes the poll live).
    nx.await(nx.buf.set_lines(0, 0, -1, false, { "changed" }))
    nx.test.expect(request("/source", { buf = tostring(md) }).body).to_be("changed")
  end)

  nx.test.it("/source 404s an unknown or non-markdown buffer, and a missing buf", function(t)
    open(t, DIR .. "/real.md", { "x" })
    nx.test.expect(request("/source", { buf = "99999" }).status).to_be(404)
    nx.test.expect(request("/source", {}).status).to_be(404)

    -- A real buffer that is not markdown is not addressable through /source either.
    local txt = open(t, DIR .. "/no.txt", { "x" })
    nx.test.expect(request("/source", { buf = tostring(txt) }).status).to_be(404)
  end)

  nx.test.it(
    "classifies a path as markdown by extension alone (for links to closed files)",
    function()
      nx.test.expect(server._md_ext("/repo/docs/guide.md")).to_be_truthy()
      nx.test.expect(server._md_ext("/repo/README.markdown")).to_be_truthy()
      nx.test.expect(server._md_ext("/repo/notes.txt")).to_be_falsy()
      nx.test.expect(server._md_ext("/repo/Makefile")).to_be_falsy()
    end
  )

  nx.test.it("/file reads a markdown file from disk, even with no buffer open", function(t)
    -- A file on disk that is NOT opened as a buffer, in a subdir of the workspace.
    nx.await(nx.fs.mkdir(DIR .. "/docs"))
    local path = DIR .. "/docs/linked.md"
    nx.await(nx.fs.write(path, "# Linked\n\nfrom disk\n"))
    t:cmd("cd " .. DIR) -- point the workspace root at DIR so the file is in-bounds

    local res = request("/file", { path = path })
    nx.test.expect(res.status or 200).to_be(200)
    nx.test.expect(res.body).to_contain("# Linked")
    nx.test.expect(res.headers["cache-control"]).to_be("no-store")
  end)

  nx.test.it("/file refuses a non-markdown file, an escape, and a missing path", function(t)
    t:cmd("cd " .. DIR)
    nx.await(nx.fs.write(DIR .. "/notes.txt", "secret"))
    -- Non-markdown extension: refused before any disk read.
    nx.test.expect(request("/file", { path = DIR .. "/notes.txt" }).status).to_be(403)
    -- Missing / non-string path.
    nx.test.expect(request("/file", {}).status).to_be(403)
    -- A real markdown file OUTSIDE the workspace: it resolves (so this exercises the
    -- containment check, not a read miss) but is refused. Canonicalizing both sides is
    -- what stops /var vs /private/var from fooling the bound.
    local outside = nx.test.tempdir() .. "/elsewhere.md"
    nx.await(nx.fs.write(outside, "# not yours\n"))
    nx.test.expect(request("/file", { path = outside }).status).to_be(403)
    -- In-bounds name but no such file: a 404, not a 200.
    nx.test.expect(request("/file", { path = DIR .. "/nope.md" }).status).to_be(404)
  end)

  nx.test.it("/ serves the HTML page with a CSP, and unknown paths 404", function()
    local root = request("/")
    nx.test.expect(root.status or 200).to_be(200)
    nx.test.expect(root.headers["content-type"]).to_contain("text/html")
    nx.test.expect(root.headers["content-security-policy"]).to_be_truthy()
    nx.test.expect(root.body).to_contain("<!doctype html>")

    nx.test.expect(request("/nope").status).to_be(404)
  end)
end)
