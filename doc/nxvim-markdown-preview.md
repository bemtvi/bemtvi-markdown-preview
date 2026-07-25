<!-- DO NOT EDIT doc/nxvim-markdown-preview.txt BY HAND. It is generated from this file
by panvimdoc — run `scripts/gen-vimdoc.sh` after editing. -->

A live, in-browser markdown preview for nxvim — an optional first-party plugin built entirely on
the native `nx.*` plugin API (ADR 0002): no core changes.

The editor serves your open buffers over a single `nx.http.mount`; the browser renders them (marked
for markdown, highlight.js for code-fence syntax highlighting across ~190 languages, mermaid for
diagrams). Because it is a mount (a subroute on the editor's one origin) and not a bound port, the
identical plugin runs on the web build too — a Service Worker satisfies the same routes. One page
previews EVERY open markdown buffer — a sidebar switches between them, and with nothing pinned the
page follows the editor's active buffer.

```
:MarkdownPreview        Mount (lazily) and open the preview in your browser.
:MarkdownPreviewStop    Retire the mount (open tabs show "editor gone").
:MarkdownPreviewToggle  Open if stopped, stop if open.
```

<!-- Passed through verbatim so `:help nxvim-markdown-preview` lands on this page
     (panvimdoc derives per-section tags but no bare project tag). -->
```vimdoc
                            *nxvim-markdown-preview* *markdown-preview-intro*
```

# Usage

- `:MarkdownPreview` — bind the mount if it is not up yet (nothing opens a port before this), then
  open the preview in your browser. The page follows the current buffer, so it works from whichever
  markdown file is focused. Reusing the command re-opens the browser at the same stable URL.
- `:MarkdownPreviewStop` — close the mount. The URL starts 404ing and open tabs show "editor gone".
  Reopening rebinds under the same name.
- `:MarkdownPreviewToggle` — open the preview if it is stopped, stop it if open.

In the browser: the left sidebar lists the open markdown buffers — click one to pin it. "Follow
editor" (top of the sidebar) clears the pin so the page tracks whichever buffer is active in the
editor. Edits appear on the next poll (~500 ms); no `:write` is needed. Rendering is the browser's
job; the editor only serves bytes.

A poll re-renders only what you changed: the page compares the document's top-level blocks against
what is on screen and rebuilds just the ones whose source moved, so typing in a long document does
not re-parse and re-highlight the whole thing twice a second — and the code fences and mermaid
diagrams you did not touch keep the pixels they already have instead of flickering on every
keystroke. A diagram the renderer cannot parse (a fence you are halfway through typing) leaves that
one block as source text; the rest of the page carries on.

The block under the editor's cursor is highlighted in the preview. The "follow cursor" toggle at the
bottom of the sidebar (remembered across reloads) also scrolls that block into view as the cursor
moves; turn it off to keep the preview where you left it. The highlight and the scroll only apply
while the page is showing the editor's active buffer.

Clicking a markdown link inside the preview navigates to that file — even one that is not open,
which is read straight from disk (no buffer needed); if it is open, the live buffer is shown
instead. Relative and `../` links resolve against the file they appear in, and a leading `/` against
the workspace root (what `/docs/guide.md` means when you write it in a repo); external links open in
a new tab. Files read from disk are bounded to markdown inside the workspace (`getcwd()`), so a link
browses the repo, not the whole disk.

Images render too, wherever they come from. An image with a relative path (`![](img/logo.png)`, or a
`/img/logo.png` against the workspace root) is read off disk and served by the mount, so a screenshot
committed next to the document shows up in the preview; an `https:` or `data:` src is passed through
to the browser untouched. Only image files are served this way, and only from inside the workspace
(the bounding is described under "The mount" below).

A buffer counts as markdown when it is a real file buffer (`'buftype'` is empty) AND either its
`filetype` is `markdown` or its name ends in a markdown extension (`.md`, `.markdown`, `.mdown`,
`.mkd`, `.mkdn`, `.mdx`). Only the last dot-component is read as the extension, so `README.en.md`
and `CHANGELOG.v2.md` are markdown like any other. The `'buftype'` gate is what keeps the sidebar to
your documents: an LSP hover popup, a rendered help page, a plugin dashboard are all scratch buffers
that often carry `filetype=markdown`, and none of them is a file you are editing.

# Options

WHERE the preview listens is your call, not the plugin's — the `'httphost'` and `'httpport'`
options, read when the mount binds. The default is an ephemeral loopback port (`127.0.0.1`,
`'httpport'` = 0). Pin a stable, bookmarkable one:

```lua
nx.o.httpport = 8080          -- 0 (default) picks a free port
-- nx.o.httphost = "0.0.0.0"  -- careful: exposes it to your LAN
```

# Setup

With `:Plugins` the plugin is on the runtimepath and `setup()` runs automatically (from
`plugin/nxvim-markdown-preview.lua`), so the commands exist out of the box. Calling it yourself is
harmless — it only registers the commands, it never binds a mount:

```lua
require("nxvim-markdown-preview").setup()
```

A leader map, if you like:

```lua
nx.keymap.set("n", "<leader>mp", "<cmd>MarkdownPreview<cr>", { desc = "Markdown preview" })
```

# The mount

The plugin is two small modules over the mount — `server.lua` (which buffers are markdown, and the
`on_request` routing, pure over editor state) and `page.lua` (the self-contained preview page:
marked + highlight.js + mermaid, client-side). Five endpoints, all mount-relative so they work
under any origin — and the page derives its own base from the URL it was served at, so it polls the
right place whether or not the address ends in a slash:

```
GET /            the page shell (marked + highlight.js + mermaid render client-side)
GET /buffers     JSON { active, cursor, root, list } — the open markdown buffers
GET /source?buf= that buffer's raw text, polled and rendered by the page
GET /file?path=  a markdown file's text read from disk, for a link to a closed file
GET /asset?path= an image's raw bytes read from disk, for a relative ![](…) in the document
```

`/file` and `/asset` are both bounded to the workspace (`getcwd()`): the requested path and the root
are both canonicalized (`nx.fs.realpath`, so a `..` walk or a symlink that escapes is refused, and
`/var` vs `/private/var` can't fool the check), the read is of the canonicalized path, and an
out-of-tree path is a 403. They differ only in what they will serve — `/file` markdown, `/asset` a
closed list of image types (`.png`, `.apng`, `.jpg`, `.jpeg`, `.gif`, `.webp`, `.avif`, `.bmp`,
`.ico`, `.svg`) — and anything else is refused before any disk read. So the preview can show your
repo's documents and images, and nothing else on the disk: `/asset` is an image route, not a static
file server.

`/asset` serves raw bytes with the `content-type` the extension implies, plus `nosniff` so the
browser does not pick a different one, and `Content-Security-Policy: default-src 'none'; sandbox`.
That last one matters for SVG, the one image format that is also a document: inside an `<img>` its
script never runs, but a browser pointed straight at the URL would render it as a page *on the
mount's origin*, where script could then read `/source`. The header is ignored when the response is
used as an image and denies everything when it is used as a document.

Because the page reuses the DOM of blocks it has not re-rendered, an image is fetched when its block
is built and not on every poll — but by the same token, replacing the image *file* on disk does not
refresh it until something in that block changes, or you reload the page.

`/source?buf=` is bounded the same way: the bufnr arrives off the wire, so it is re-checked against
the open markdown buffers rather than read as given (`?buf=0`, which inside `nx.buf.*` would mean
"whatever is focused", is a 404 like any other unknown handle).

Every route reads — nothing here mutates the editor — so the mount answers `GET` and `HEAD` and
refuses anything else with a 405.

# Notes

marked, highlight.js, and mermaid load from the jsDelivr CDN, so the preview page needs internet for
those libraries. It renders your local buffers but pulls the renderer from a CDN; the mount's CSP
confines scripts and styles to `'self'` plus jsDelivr.

Images are the one thing the CSP lets in from further afield. `'self'` covers the mount's own
`/asset` route (a relative image read off disk), `data:` an inline one, and `https:` a README's
badges and hosted screenshots — which would otherwise all render broken. An image is inert, so this
widens what the page can *display*, not what it can run; plain `http:` images are still blocked.

Escaping is the library's job almost everywhere: highlight.js returns escaped markup, the page's
code-block renderer falls back to marked's own (HTML-escaping) renderer, and every dynamic value
(buffer labels, error text) is written through `textContent`. The single exception is a `mermaid`
fence, whose source has to go back into the page as text for mermaid to read — that one insertion
the page escapes itself.

Security: `nx.http.mount` mounts share one origin, so the same-origin policy does not isolate one
mount from another — a mount is a trust boundary between the editor and the network, not between
plugins. The preview renders content you are actively editing (your own buffers); marked does not
sanitize, so raw HTML in a buffer renders, as expected for a preview of your own documents.
