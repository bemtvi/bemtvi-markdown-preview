-- The preview page is a static asset, but a few invariants keep the plugin honest: it
-- loads its renderer (marked + mermaid) client-side, talks to the mount's own relative
-- endpoints, and carries the CSP. Run with `nxvim --test-plugin .`.

local page = require("nxvim-markdown-preview.page")

nx.test.describe("nxvim-markdown-preview.page", function()
  nx.test.it("renders markdown client-side with marked and mermaid", function()
    local html = page.html()
    nx.test.expect(html).to_contain("cdn.jsdelivr.net/npm/marked")
    nx.test.expect(html).to_contain("mermaid")
    nx.test.expect(html).to_contain("marked.parser")
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
    -- Relative to the mount's own base, so it works under the mount prefix on any origin.
    nx.test.expect(html).to_contain('fetch(BASE + "buffers"')
    nx.test.expect(html).to_contain('BASE + "source?buf="')
    -- Links to closed files navigate through /file.
    nx.test.expect(html).to_contain('BASE + "file?path="')
  end)

  nx.test.it("routes a relative image through the mount's /asset", function()
    local html = page.html()
    nx.test.expect(html).to_contain("function localizeImages(el)")
    nx.test.expect(html).to_contain('BASE + "asset?path="')
    -- An src that already names its own scheme (https:, data:) or is protocol-relative is
    -- left exactly as the author wrote it.
    nx.test.expect(html).to_contain('src.startsWith("//") || /^[a-z][a-z0-9+.-]*:/i.test(src)')
    -- Rewritten as the block renders, so an unchanged image block is never refetched.
    nx.test.expect(html).to_contain("localizeImages(el);")
  end)

  nx.test.it("resolves a leading-slash target against the workspace root", function()
    local html = page.html()
    -- `/img/logo.png` in a document means repo-root, not filesystem-root.
    nx.test.expect(html).to_contain('const base = href.startsWith("/") ? docRoot : baseDir;')
    nx.test.expect(html).to_contain('docRoot = data.root || "";')
  end)

  nx.test.it("derives its base path instead of trusting a trailing slash", function()
    local html = page.html()
    -- A URL bookmarked without the trailing slash serves the same page; a bare relative
    -- "buffers" would then resolve one level up, out of the mount.
    nx.test.expect(html).to_contain('location.pathname.endsWith("/")')
  end)

  nx.test.it("escapes the one value it inserts by hand — the mermaid fence", function()
    local html = page.html()
    -- Everything else is escaped by a library; mermaid's source goes back in as text.
    nx.test.expect(html).to_contain('<pre class="mermaid">${esc(text)}</pre>')
    nx.test.expect(html).to_contain('"&": "&amp;"')
  end)

  nx.test.it("re-renders incrementally, reusing the DOM of unchanged blocks", function()
    local html = page.html()
    nx.test.expect(html).to_contain("function reconcile(md)")
    -- Blocks are matched by their raw source and their elements reused …
    nx.test.expect(html).to_contain("reusable.get(b.raw)")
    -- … and only the freshly-built ones get handed to mermaid.
    nx.test.expect(html).to_contain("runMermaid(reconcile(md))")
  end)

  nx.test.it("contains a mermaid failure instead of reporting the editor gone", function()
    local html = page.html()
    nx.test.expect(html).to_contain("suppressErrors: true")
    nx.test.expect(html).to_contain("async function runMermaid(els)")
  end)

  nx.test.it("polls single-flight, re-arming only after a tick settles", function()
    local html = page.html()
    -- No setInterval: a render slower than the interval would otherwise overlap itself.
    nx.test.expect(html).to_contain("if (ticking) { again = true; return; }")
    nx.test.expect(html).to_contain("schedule(immediate ? 0 : POLL_MS)")
    nx.test.expect(html:find("setInterval", 1, true)).to_be_nil()
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

  nx.test.it("maps the editor cursor line to a rendered block and highlights it", function()
    local html = page.html()
    -- Blocks carry their source-line range …
    nx.test.expect(html).to_contain("function lexBlocks(md)")
    nx.test.expect(html).to_contain("marked.lexer")
    -- … and applyCursor marks the one containing the line, only for the active buffer.
    nx.test.expect(html).to_contain("cursor-here")
    nx.test.expect(html).to_contain("target.buf === data.active ? data.cursor : null")
  end)

  nx.test.it("offers a cursor-follow auto-scroll toggle, persisted and default on", function()
    local html = page.html()
    nx.test.expect(html).to_contain('id="cursorfollow"')
    -- Remembered across reloads; default on (only "0" disables). Through `store`, which
    -- survives a context where localStorage itself throws.
    nx.test.expect(html).to_contain('store.get("nxmp.autoscroll") !== "0"')
    nx.test.expect(html).to_contain('store.set("nxmp.autoscroll"')
    nx.test.expect(html).to_contain("try { return localStorage.getItem(k); } catch")
    -- Scrolls the cursor block into view, gated on the toggle and a real line change.
    nx.test.expect(html).to_contain("hit.scrollIntoView")
    nx.test.expect(html).to_contain("autoScroll && hit && line !== lastCursorLine")
  end)

  nx.test.it("headers set the content type and a CSP", function()
    local h = page.headers()
    nx.test.expect(h["content-type"]).to_contain("text/html")
    nx.test.expect(h["content-security-policy"]).to_contain("cdn.jsdelivr.net")
    -- Scripts stay confined to the two origins; images are content, so https: is allowed
    -- (a README's badges and hosted screenshots would otherwise all render broken).
    nx.test.expect(h["content-security-policy"]).to_contain("img-src 'self' data: https:")
    nx.test.expect(h["content-security-policy"]).to_contain("default-src 'self'")
  end)
end)
