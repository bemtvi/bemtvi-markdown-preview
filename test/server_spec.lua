-- The request layer: buffer discovery and the on_request routing. Driven directly with
-- a fake `req`/`respond` — the routing is pure over editor state, so no socket, no real
-- HTTP, no browser. Run with `nxvim --test-plugin .`.

local server = require("nxvim-markdown-preview.server")

-- Call the mount handler synchronously and return the response table it produced.
-- `server.handle` calls `respond` inline for every route, so the capture is set on return.
local function request(path, query)
  local res
  server.handle(
    { method = "GET", path = path, query = query or {}, name = "nxvim-markdown-preview" },
    function(r)
      res = r
    end
  )
  return res
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

  nx.test.it("/ serves the HTML page with a CSP, and unknown paths 404", function()
    local root = request("/")
    nx.test.expect(root.status or 200).to_be(200)
    nx.test.expect(root.headers["content-type"]).to_contain("text/html")
    nx.test.expect(root.headers["content-security-policy"]).to_be_truthy()
    nx.test.expect(root.body).to_contain("<!doctype html>")

    nx.test.expect(request("/nope").status).to_be(404)
  end)
end)
