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
    nx.test.expect(html).to_contain('pre class="mermaid"')
  end)

  nx.test.it("syntax-highlights code fences with highlight.js", function()
    local html = page.html()
    nx.test.expect(html).to_contain("cdn.jsdelivr.net/npm/highlight.js")
    -- By the fence's language when known (hljs.highlight), else auto-detected.
    nx.test.expect(html).to_contain("hljs.getLanguage")
    nx.test.expect(html).to_contain("hljs.highlightAuto")
    -- The token themes are loaded (one per colour scheme).
    nx.test.expect(html).to_contain("styles/github.min.css")
    nx.test.expect(html).to_contain("styles/github-dark.min.css")
  end)

  nx.test.it("polls the mount's own relative endpoints", function()
    local html = page.html()
    -- Relative (no leading slash), so it works under the mount prefix on any origin.
    nx.test.expect(html).to_contain('fetch("buffers"')
    nx.test.expect(html).to_contain('"source?buf="')
    -- Links to closed files navigate through /file.
    nx.test.expect(html).to_contain('"file?path="')
  end)

  nx.test.it("navigates markdown links and pins them in the URL hash", function()
    local html = page.html()
    nx.test.expect(html).to_contain("MD_RE")
    nx.test.expect(html).to_contain('"f:" + encodeURIComponent')
    -- External links open in a new tab rather than navigating the preview.
    nx.test.expect(html).to_contain('a.target = "_blank"')
  end)

  nx.test.it("scrolls to the top when the document switches, not on a live edit", function()
    local html = page.html()
    nx.test.expect(html).to_contain("scrollTo(0, 0)")
    -- Gated on a real switch (key change), so an edit to the same doc keeps the position.
    nx.test.expect(html).to_contain("if (switched)")
  end)

  nx.test.it("headers set the content type and a CSP", function()
    local h = page.headers()
    nx.test.expect(h["content-type"]).to_contain("text/html")
    nx.test.expect(h["content-security-policy"]).to_contain("cdn.jsdelivr.net")
  end)
end)
