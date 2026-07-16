# nxvim-markdown-preview

A live, in-browser **markdown preview** for [nxvim](https://github.com/davidrios/nxvim) —
an optional first-party plugin built entirely on the native `nx.*` plugin API
([ADR 0002](https://github.com/davidrios/nxvim)): no core changes.

The editor serves your buffers over a single [`nx.http.mount`](https://github.com/davidrios/nxvim);
the **browser** renders them ([marked](https://marked.js.org) for markdown,
[mermaid](https://mermaid.js.org) for diagrams). Because it is a *mount* (a subroute on
the editor's one origin) and not a bound port, the identical plugin runs on the web build
too — a Service Worker satisfies the same routes.

```
:MarkdownPreview        mount (lazily) and open the preview in your browser
:MarkdownPreviewStop    retire the mount (open tabs show "editor gone")
:MarkdownPreviewToggle  open if stopped, stop if open
```

## What it does

- **Live.** The page polls the mount, so an edit shows up on the next poll (~500 ms) —
  no `:w` needed. Rendering is the browser's job; the editor only serves bytes.
- **Multi-buffer.** One page previews **every** open markdown buffer. A sidebar lists
  them; click to switch. With nothing pinned it **follows** the editor's active buffer;
  "⟳ follow editor" clears a pin.
- **GFM + mermaid.** Tables, task lists, fenced code, and ` ```mermaid ` diagram blocks,
  all rendered client-side.
- **Lazy.** Nothing opens a port until `:MarkdownPreview` — a config that installs this
  plugin but never previews binds no listener.

A buffer counts as markdown when its `filetype` is `markdown`, or its name ends in a
markdown extension (`.md`, `.markdown`, `.mdown`, `.mkd`, `.mdx`, …).

> **Network note:** marked and mermaid load from the jsDelivr CDN, so the preview page
> needs internet for those two libraries (it renders your *local* buffers, but pulls the
> *renderer* from a CDN). The mount's CSP confines the page to `'self'` plus jsDelivr.

## Install

Put the plugin on the runtimepath and call `setup()` (it registers the commands; it does
**not** bind a mount):

```lua
require("nxvim-markdown-preview").setup()
```

With `:Plugins` the plugin is already on the runtimepath, so `setup()` runs from
`plugin/nxvim-markdown-preview.lua` automatically — the commands exist out of the box.

A leader map, if you like:

```lua
nx.keymap.set("n", "<leader>mp", "<cmd>MarkdownPreview<cr>", { desc = "Markdown preview" })
```

## Where it listens

`:MarkdownPreview` binds on the editor's chosen HTTP address — the **user's** call, not
the plugin's — via the `'httphost'` / `'httpport'` options. The default is an ephemeral
loopback port (`127.0.0.1`, `httpport = 0`). Pin a stable, bookmarkable one:

```lua
nx.o.httpport = 8080          -- 0 (default) picks a free port
-- nx.o.httphost = "0.0.0.0"  -- careful: exposes the preview to your LAN
```

## Try it

```sh
NXVIM_CONFIG=examples cargo run -p nxvim -- SOME_FILE.md   # from the nxvim repo
```

Then `:MarkdownPreview` (or `\p`), open more markdown files with `:e`, and switch between
them from the sidebar. See [`examples/init.lua`](examples/init.lua).

## Design

The plugin is two small modules over the mount:

| module       | responsibility                                                                    |
|--------------|-----------------------------------------------------------------------------------|
| `server.lua` | which buffers are markdown, and the `on_request` routing (pure over editor state) |
| `page.lua`   | the self-contained preview page (marked + mermaid, client-side)                   |

Three endpoints, all mount-relative so they work under any origin:

```
GET /            the page shell (marked + mermaid render client-side)
GET /buffers     JSON { active, list } — the open markdown buffers, polled by the page
GET /source?buf= that buffer's raw text, polled and rendered by the page
```

Escaping is the library's job, never the plugin's: the page's code-block renderer returns
`false` to fall back to marked's own (HTML-escaping) renderer, and every dynamic value
(buffer labels, error text) is written through `textContent`.

> **Security.** `nx.http.mount` mounts share one origin, so the same-origin policy does
> not isolate one mount from another — a mount is a trust boundary between the *editor*
> and the *network*, not between plugins. The preview renders content you are actively
> editing (your own buffers); marked does not sanitize, so raw HTML in a buffer renders,
> as expected for a preview of your own documents.

## Tests

Pure-Lua [`nx.test`](https://github.com/davidrios/nxvim) specs that drive the routing
directly with a fake `req`/`respond` — no socket, no browser:

```sh
nxvim --test-plugin .
```

`test/server_spec.lua` covers markdown classification, the `/buffers` list (labels,
active), `/source` (live text + 404s), and the `/` shell; `test/page_spec.lua` pins the
page's client-side render invariants.

## Status

Complete:

- live, browser-based preview over `nx.http.mount` (native and web)
- multi-buffer sidebar + follow-the-editor mode
- GFM (tables, lists, code) and mermaid diagrams, rendered client-side

## License

MIT — see [LICENSE](LICENSE).
