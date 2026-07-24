# nxvim-markdown-preview

A live, in-browser **markdown preview** for [nxvim](https://github.com/davidrios/nxvim) —
an optional first-party plugin built entirely on the native `nx.*` plugin API
([ADR 0002](https://github.com/davidrios/nxvim)): no core changes.

The editor serves your buffers over a single [`nx.http.mount`](https://github.com/davidrios/nxvim);
the **browser** renders them ([marked](https://marked.js.org) for markdown, highlight.js
for fenced-code syntax, [mermaid](https://mermaid.js.org) for diagrams). Because it is a
*mount* (a subroute on the editor's one origin) and not a bound port, the identical plugin
runs on the web build too — a Service Worker satisfies the same routes. One page previews
**every** open markdown buffer; a sidebar switches between them, and with nothing pinned it
follows the editor's active buffer. Edits show up on the next poll (~500 ms) — no `:w`
needed.

```
:MarkdownPreview        mount (lazily) and open the preview in your browser
:MarkdownPreviewStop    retire the mount (open tabs show "editor gone")
:MarkdownPreviewToggle  open if stopped, stop if open
```

## Install

Put the plugin on the runtimepath and call `setup()` (it registers the commands; it does
**not** bind a mount):

```lua
require("nxvim-markdown-preview").setup()
```

With `:Plugins` the plugin is already on the runtimepath, so `setup()` runs from
`plugin/nxvim-markdown-preview.lua` automatically — the commands exist out of the box. A
leader map, if you like:

```lua
nx.keymap.set("n", "<leader>mp", "<cmd>MarkdownPreview<cr>", { desc = "Markdown preview" })
```

## Try it

```sh
NXVIM_CONFIG=examples cargo run -p nxvim -- SOME_FILE.md   # from the nxvim repo
```

Then `:MarkdownPreview`, open more markdown files with `:e`, and switch between them from
the sidebar. See [`examples/init.lua`](examples/init.lua).

## Documentation

Full docs — the commands, the browser sidebar / follow-editor / follow-cursor / link
navigation, the `'httphost'` / `'httpport'` options, `setup()`, the mount's endpoints and
the `/file` disk-read bounding, and the network/security notes — live in the help file.
The same source renders both on GitHub and in the editor:

- In editor: `:help nxvim-markdown-preview`
- On GitHub: [doc/nxvim-markdown-preview.md](./doc/nxvim-markdown-preview.md) (the help source)

## Development

Pure-Lua [`nx.test`](https://github.com/davidrios/nxvim) specs drive the routing directly
with a fake `req`/`respond` — no socket, no browser (`server_spec` covers markdown
classification, `/buffers`, `/source`, and the `/` shell; `page_spec` pins the page's
client-side render invariants):

```sh
nxvim --test-plugin .
```

The vimdoc `doc/nxvim-markdown-preview.txt` is **generated** from
`doc/nxvim-markdown-preview.md` via [panvimdoc](https://github.com/kdheepak/panvimdoc):
edit the `.md`, then run `bash scripts/gen-vimdoc.sh` (needs `pandoc` + `git`). Never edit
the `.txt` by hand.

## License

MIT — see [LICENSE](LICENSE).
