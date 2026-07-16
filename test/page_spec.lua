-- The preview page is a static asset, but a few invariants keep the plugin honest: it
-- loads its renderer (marked + mermaid) client-side, talks to the mount's own relative
-- endpoints, and carries the CSP. Run with `nxvim --test-plugin .`.

local page = require("nxvim-markdown-preview.page")

nx.test.describe("nxvim-markdown-preview.page", function()
  nx.test.it("renders markdown client-side with marked and mermaid", function()
    local html = page.html()
    nx.test.expect(html).to_contain("cdn.jsdelivr.net/npm/marked")
    nx.test.expect(html).to_contain("mermaid")
    nx.test.expect(html).to_contain("marked.parse")
    -- Code blocks fall back to marked's escaping renderer (return false), not a hand-rolled escape.
    nx.test.expect(html).to_contain('pre class="mermaid"')
  end)

  nx.test.it("polls the mount's own relative endpoints", function()
    local html = page.html()
    -- Relative (no leading slash), so it works under the mount prefix on any origin.
    nx.test.expect(html).to_contain('fetch("buffers"')
    nx.test.expect(html).to_contain('fetch("source?buf=')
  end)

  nx.test.it("headers set the content type and a CSP", function()
    local h = page.headers()
    nx.test.expect(h["content-type"]).to_contain("text/html")
    nx.test.expect(h["content-security-policy"]).to_contain("cdn.jsdelivr.net")
  end)
end)
