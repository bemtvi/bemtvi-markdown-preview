-- The one spec that goes through a REAL mount. `server_spec` drives `handle` directly
-- with a fake `req`/`respond`, which is the right shape for testing the routing — but it
-- proves nothing about the plumbing either side of it. This binds an actual mount, fetches
-- every route over HTTP, and checks what comes back off the wire, so a change that breaks
-- the mount contract (a header a transport drops, a status that never leaves the handler)
-- is caught here rather than in a browser. Run with `bemtvi --test-plugin .`.

local server = require("bemtvi-markdown-preview.server")

btv.test.describe("bemtvi-markdown-preview over a real mount", function()
  btv.test.it("serves every route over HTTP", function(t)
    local dir = btv.test.tempdir()
    t:cmd("cd " .. dir)
    -- A multi-part name, which is the shape a naive extension match gets wrong.
    t:cmd("edit " .. dir .. "/README.en.md")
    btv.await(btv.buf.set_lines(0, 0, -1, false, { "# Hello", "", "body" }))
    local buf = btv.buf.current()
    btv.await(btv.fs.write(dir .. "/linked.md", "# Linked\n"))

    local mount = btv.await(btv.http.mount({ name = "mdprev-e2e", on_request = server.handle }))
    local url = mount:url()

    -- "/" — the page shell, with the CSP the browser will actually enforce.
    local root = btv.await(btv.http.fetch(url))
    btv.test.expect(root.status).to_be(200)
    btv.test.expect(root.body).to_contain("<!doctype html>")
    btv.test
      .expect(root.headers["content-security-policy"])
      .to_contain("img-src 'self' data: https:")

    -- "/buffers" — the open markdown buffers and which one is active.
    local data = btv.json.decode(btv.await(btv.http.fetch(url .. "buffers")).body)
    btv.test.expect(data.active).to_be(buf)
    local found
    for _, e in ipairs(data.list) do
      if e.id == buf then
        found = e
      end
    end
    btv.test.expect(found).to_be_truthy()
    btv.test.expect(found.label).to_be("README.en.md")

    -- "/source" — the live buffer text …
    btv.test
      .expect(btv.await(btv.http.fetch(url .. "source?buf=" .. buf)).body)
      .to_be("# Hello\n\nbody")
    -- … and "/file" — a markdown file that is only on disk.
    btv.test
      .expect(btv.await(btv.http.fetch(url .. "file?path=" .. dir .. "/linked.md")).body)
      .to_contain("# Linked")

    -- "/asset" — an image's raw bytes. Over the wire is where a binary body has to survive
    -- a transport that might otherwise treat it as text, so assert the exact bytes back.
    local png = "\137\80\78\71\13\10\26\10\0\0\0\13\73\72\68\82"
    btv.await(btv.fs.write(dir .. "/logo.png", png))
    local asset = btv.await(btv.http.fetch(url .. "asset?path=" .. dir .. "/logo.png"))
    btv.test.expect(asset.headers["content-type"]).to_be("image/png")
    btv.test.expect(asset.body).to_be(png)
    -- A non-image inside the workspace is refused, so /asset is not a static file server.
    btv.test
      .expect(btv.await(btv.http.fetch(url .. "asset?path=" .. dir .. "/linked.md")).status)
      .to_be(403)

    -- Every route reads, so a write method is refused rather than served as a GET.
    btv.test.expect(btv.await(btv.http.fetch(url .. "buffers", { method = "POST" })).status).to_be(405)
    -- And a bufnr the page was never told about is not addressable (0 = "the current
    -- buffer" inside btv.buf.*, so it is the one that must not slip through).
    btv.test.expect(btv.await(btv.http.fetch(url .. "source?buf=0")).status).to_be(404)

    mount:close()
    btv.test.expect(mount:is_open()).to_be_falsy()
  end)
end)
