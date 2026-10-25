-- The preview page is a static asset, but a few invariants keep the plugin honest: it
-- loads its renderer (marked + mermaid) client-side, talks to the mount's own relative
-- endpoints, and carries the CSP. Run with `bemtvi --test-plugin .`.

local page = require("bemtvi-markdown-preview.page")

btv.test.describe("bemtvi-markdown-preview.page", function()
  btv.test.it("renders markdown client-side with marked and mermaid", function()
    local html = page.html()
    btv.test.expect(html).to_contain("cdn.jsdelivr.net/npm/marked")
    btv.test.expect(html).to_contain("mermaid")
    btv.test.expect(html).to_contain("marked.parser")
    btv.test.expect(html).to_contain('pre class="mermaid"')
  end)

  btv.test.it("syntax-highlights code fences with highlight.js", function()
    local html = page.html()
    btv.test.expect(html).to_contain("cdn.jsdelivr.net/npm/highlight.js")
    -- By the fence's language when known (hljs.highlight), else auto-detected.
    btv.test.expect(html).to_contain("hljs.getLanguage")
    btv.test.expect(html).to_contain("hljs.highlightAuto")
    -- The token themes are loaded (one per colour scheme).
    btv.test.expect(html).to_contain("styles/github.min.css")
    btv.test.expect(html).to_contain("styles/github-dark.min.css")
  end)

  btv.test.it("polls the mount's own relative endpoints", function()
    local html = page.html()
    -- Relative to the mount's own base, so it works under the mount prefix on any origin.
    btv.test.expect(html).to_contain('fetch(BASE + "buffers"')
    btv.test.expect(html).to_contain('BASE + "source?buf="')
    -- Links to closed files navigate through /file.
    btv.test.expect(html).to_contain('BASE + "file?path="')
  end)

  btv.test.it("routes a relative image through the mount's /asset", function()
    local html = page.html()
    btv.test.expect(html).to_contain("function localizeImages(el)")
    btv.test.expect(html).to_contain('BASE + "asset?path="')
    -- An src that already names its own scheme (https:, data:) or is protocol-relative is
    -- left exactly as the author wrote it.
    btv.test.expect(html).to_contain('src.startsWith("//") || /^[a-z][a-z0-9+.-]*:/i.test(src)')
    -- Rewritten as the block renders, so an unchanged image block is never refetched.
    btv.test.expect(html).to_contain("localizeImages(el);")
  end)

  btv.test.it("resolves a leading-slash target against the workspace root", function()
    local html = page.html()
    -- `/img/logo.png` in a document means repo-root, not filesystem-root.
    btv.test.expect(html).to_contain('const base = href.startsWith("/") ? docRoot : baseDir;')
    btv.test.expect(html).to_contain('docRoot = data.root || "";')
  end)

  btv.test.it("derives its base path instead of trusting a trailing slash", function()
    local html = page.html()
    -- A URL bookmarked without the trailing slash serves the same page; a bare relative
    -- "buffers" would then resolve one level up, out of the mount.
    btv.test.expect(html).to_contain('location.pathname.endsWith("/")')
  end)

  btv.test.it("escapes the one value it inserts by hand — the mermaid fence", function()
    local html = page.html()
    -- Everything else is escaped by a library; mermaid's source goes back in as text.
    btv.test.expect(html).to_contain('<pre class="mermaid">${esc(text)}</pre>')
    btv.test.expect(html).to_contain('"&": "&amp;"')
  end)

  btv.test.it("re-renders incrementally, reusing the DOM of unchanged blocks", function()
    local html = page.html()
    btv.test.expect(html).to_contain("async function reconcile(md, reset)")
    -- Blocks are matched by their raw source and their ids reused, so only fresh blocks
    -- are sent to the frame …
    btv.test.expect(html).to_contain("reusable.get(b.raw)")
    btv.test
      .expect(html)
      .to_contain('post({ t: "render", order: next.map((n) => n.id), add, reset })')
    -- … and only the freshly-built ones get handed to mermaid there.
    btv.test.expect(html).to_contain("runMermaid(fresh)")
  end)

  btv.test.it("contains a mermaid failure instead of reporting the editor gone", function()
    local html = page.html()
    btv.test.expect(html).to_contain("suppressErrors: true")
    btv.test.expect(html).to_contain("async function runMermaid(els)")
  end)

  btv.test.it("polls single-flight, re-arming only after a tick settles", function()
    local html = page.html()
    -- No setInterval: a render slower than the interval would otherwise overlap itself.
    btv.test.expect(html).to_contain("if (ticking) { again = true; return; }")
    btv.test.expect(html).to_contain("schedule(immediate ? 0 : POLL_MS)")
    btv.test.expect(html:find("setInterval", 1, true)).to_be_nil()
  end)

  btv.test.it("navigates markdown links and pins them in the URL hash", function()
    local html = page.html()
    btv.test.expect(html).to_contain("MD_RE")
    btv.test.expect(html).to_contain('"f:" + encodeURIComponent')
    -- External links open in a new tab rather than navigating the preview — and only
    -- http(s)/mailto ones: the href comes out of the document.
    btv.test.expect(html).to_contain('window.open(href, "_blank", "noopener")')
    btv.test.expect(html).to_contain("/^(https?|mailto):/i.test(href)")
  end)

  btv.test.it("scrolls to the top when the document switches, not on a live edit", function()
    local html = page.html()
    btv.test.expect(html).to_contain("scrollTo(0, 0)")
    -- Gated on a real switch (key change), so an edit to the same doc keeps the position.
    btv.test.expect(html).to_contain("if (switched)")
  end)

  btv.test.it("maps the editor cursor line to a rendered block and highlights it", function()
    local html = page.html()
    -- Blocks carry their source-line range …
    btv.test.expect(html).to_contain("function lexBlocks(md)")
    btv.test.expect(html).to_contain("marked.lexer")
    -- … and applyCursor marks the one containing the line, only for the active buffer.
    btv.test.expect(html).to_contain("cursor-here")
    btv.test.expect(html).to_contain("target.buf === data.active ? data.cursor : null")
  end)

  btv.test.it("offers a cursor-follow auto-scroll toggle, persisted and default on", function()
    local html = page.html()
    btv.test.expect(html).to_contain('id="cursorfollow"')
    -- Remembered across reloads; default on (only "0" disables). Through `store`, which
    -- survives a context where localStorage itself throws.
    btv.test.expect(html).to_contain('store.get("btvmp.autoscroll") !== "0"')
    btv.test.expect(html).to_contain('store.set("btvmp.autoscroll"')
    btv.test.expect(html).to_contain("try { return localStorage.getItem(k); } catch")
    -- Scrolls the cursor block into view, gated on the toggle and a real line change.
    btv.test.expect(html).to_contain("hit.scrollIntoView")
    btv.test.expect(html).to_contain("autoScroll && hit && line !== lastCursorLine")
  end)

  btv.test.it("headers set the content type and a CSP", function()
    local h = page.headers()
    btv.test.expect(h["content-type"]).to_contain("text/html")
    btv.test.expect(h["content-security-policy"]).to_contain("cdn.jsdelivr.net")
    -- Scripts stay confined to the two origins; images are content, so https: is allowed
    -- (a README's badges and hosted screenshots would otherwise all render broken).
    btv.test.expect(h["content-security-policy"]).to_contain("img-src 'self' data: https:")
    btv.test.expect(h["content-security-policy"]).to_contain("default-src 'self'")
  end)

  -- A rendered document is untrusted (marked does not sanitize; a README from a repo under
  -- review can carry any HTML). It must land in an opaque-origin frame that runs only the
  -- page's own nonced agent — never in the shell, which can reach the mount.
  btv.test.it("renders documents into a sandboxed, script-locked frame", function()
    local html = page.html()
    local attr = html:match('<iframe id="doc" sandbox="([^"]*)"')
    btv.test.expect(attr).to_be("allow-scripts")
    btv.test.expect(attr:find("allow-same-origin", 1, true)).to_be_nil()
    btv.test.expect(html).to_contain("frameEl.srcdoc = FRAME_HTML")
    -- The frame's own CSP: only the per-load nonce (and mermaid's pinned path) may run,
    -- and no network beyond images.
    btv.test.expect(html).to_contain("\"default-src 'none'\"")
    btv.test.expect(html).to_contain("`script-src 'nonce-${NONCE}' ${MERMAID}`")
    btv.test.expect(html).to_contain("crypto.getRandomValues")
    btv.test.expect(html).to_contain('<script nonce="${NONCE}">')
    -- Rendered HTML is parsed only into an inert template and serialized back out; the
    -- shell never inserts it into its own DOM.
    btv.test.expect(html).to_contain('document.createElement("template")')
    btv.test.expect(html).to_contain("return tpl.innerHTML;")
    btv.test.expect(html:find("mainEl.innerHTML", 1, true)).to_be_nil()
    -- Images are inlined by the shell, since the frame cannot reach the mount.
    btv.test.expect(html).to_contain("fr.readAsDataURL(blob)")
    -- The only message the shell takes from the frame is from THAT frame.
    btv.test.expect(html).to_contain("e.source !== frameEl.contentWindow")
  end)
end)
