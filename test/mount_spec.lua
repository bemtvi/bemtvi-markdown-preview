-- The one spec that goes through a REAL mount. `server_spec` drives `handle` directly
-- with a fake `req`/`respond`, which is the right shape for testing the routing — but it
-- proves nothing about the plumbing either side of it. This binds an actual mount, fetches
-- every route over HTTP, and checks what comes back off the wire, so a change that breaks
-- the mount contract (a header a transport drops, a status that never leaves the handler)
-- is caught here rather than in a browser. Run with `nxvim --test-plugin .`.

local server = require("nxvim-markdown-preview.server")

nx.test.describe("nxvim-markdown-preview over a real mount", function()
  nx.test.it("serves every route over HTTP", function(t)
    local dir = nx.test.tempdir()
    t:cmd("cd " .. dir)
    -- A multi-part name, which is the shape a naive extension match gets wrong.
    t:cmd("edit " .. dir .. "/README.en.md")
    nx.await(nx.buf.set_lines(0, 0, -1, false, { "# Hello", "", "body" }))
    local buf = nx.buf.current()
    nx.await(nx.fs.write(dir .. "/linked.md", "# Linked\n"))

    local mount = nx.await(nx.http.mount({ name = "mdprev-e2e", on_request = server.handle }))
    local url = mount:url()

    -- "/" — the page shell, with the CSP the browser will actually enforce.
    local root = nx.await(nx.http.fetch(url))
    nx.test.expect(root.status).to_be(200)
    nx.test.expect(root.body).to_contain("<!doctype html>")
    nx.test
      .expect(root.headers["content-security-policy"])
      .to_contain("img-src 'self' data: https:")

    -- "/buffers" — the open markdown buffers and which one is active.
    local data = nx.json.decode(nx.await(nx.http.fetch(url .. "buffers")).body)
    nx.test.expect(data.active).to_be(buf)
    local found
    for _, e in ipairs(data.list) do
      if e.id == buf then
        found = e
      end
    end
    nx.test.expect(found).to_be_truthy()
    nx.test.expect(found.label).to_be("README.en.md")

    -- "/source" — the live buffer text …
    nx.test
      .expect(nx.await(nx.http.fetch(url .. "source?buf=" .. buf)).body)
      .to_be("# Hello\n\nbody")
    -- … and "/file" — a markdown file that is only on disk.
    nx.test
      .expect(nx.await(nx.http.fetch(url .. "file?path=" .. dir .. "/linked.md")).body)
      .to_contain("# Linked")

    -- "/asset" — an image's raw bytes. Over the wire is where a binary body has to survive
    -- a transport that might otherwise treat it as text, so assert the exact bytes back.
    local png = "\137\80\78\71\13\10\26\10\0\0\0\13\73\72\68\82"
    nx.await(nx.fs.write(dir .. "/logo.png", png))
    local asset = nx.await(nx.http.fetch(url .. "asset?path=" .. dir .. "/logo.png"))
    nx.test.expect(asset.headers["content-type"]).to_be("image/png")
    nx.test.expect(asset.body).to_be(png)
    -- A non-image inside the workspace is refused, so /asset is not a static file server.
    nx.test
      .expect(nx.await(nx.http.fetch(url .. "asset?path=" .. dir .. "/linked.md")).status)
      .to_be(403)

    -- Every route reads, so a write method is refused rather than served as a GET.
    nx.test.expect(nx.await(nx.http.fetch(url .. "buffers", { method = "POST" })).status).to_be(405)
    -- And a bufnr the page was never told about is not addressable (0 = "the current
    -- buffer" inside nx.buf.*, so it is the one that must not slip through).
    nx.test.expect(nx.await(nx.http.fetch(url .. "source?buf=0")).status).to_be(404)

    mount:close()
    nx.test.expect(mount:is_open()).to_be_falsy()
  end)
end)
