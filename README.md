# bemtvi-markdown-preview

A live, in-browser **markdown preview** for [bemtvi](https://github.com/bemtvi/bemtvi) —
an optional first-party plugin built entirely on the native `btv.*` plugin API
([ADR 0002](https://github.com/bemtvi/bemtvi)): no core changes.

The editor serves your buffers over a single [`btv.http.mount`](https://github.com/bemtvi/bemtvi);
the **browser** renders them ([marked](https://marked.js.org) for markdown, highlight.js
for fenced-code syntax, [mermaid](https://mermaid.js.org) for diagrams). Because it is a
*mount* (a subroute on the editor's one origin) and not a bound port, the identical plugin
runs on the web build too — a Service Worker satisfies the same routes. One page previews
**every** open markdown buffer; a sidebar switches between them, and with nothing pinned it
follows the editor's active buffer. Edits show up on the next poll (~500 ms) — no `:w`
needed, and only the block you changed is re-rendered, so a long document does not re-parse
itself twice a second while you type. Links to other markdown files navigate the preview
(read off disk when they are not open), and relative images load — a screenshot committed
next to the document is served over the mount, bounded to images inside the workspace.

```
:MarkdownPreview        mount (lazily) and open the preview in your browser
:MarkdownPreviewStop    retire the mount (open tabs show "editor gone")
:MarkdownPreviewToggle  open if stopped, stop if open
```

## Install

Put the plugin on the runtimepath and call `setup()` (it registers the commands; it does
**not** bind a mount):

```lua
require("bemtvi-markdown-preview").setup()
```

With `:Plugins` the plugin is already on the runtimepath, so `setup()` runs from
`plugin/bemtvi-markdown-preview.lua` automatically — the commands exist out of the box. A
leader map, if you like:

```lua
btv.keymap.set("n", "<leader>mp", "<cmd>MarkdownPreview<cr>", { desc = "Markdown preview" })
```

## Try it

From this repo's root:

```sh
BEMTVI_CONFIG=examples bemtvi examples/sample.md
```

Then `:MarkdownPreview` (or `<leader>p`). [`examples/sample.md`](examples/sample.md) is a
guided tour — live edit, the cursor line, code fences, mermaid, relative images, link
navigation, the buffer sidebar — each section a *type-this / see-that* note. Run it from the
repo root rather than from `examples/`: the cwd is the workspace root, and the mount only
reads inside it.

## Documentation

Full docs — the commands, the browser sidebar / follow-editor / follow-cursor / link
navigation, the `'httphost'` / `'httpport'` options, `setup()`, the mount's endpoints and
the `/file` disk-read bounding, and the network/security notes — live in the help file.
The same source renders both on GitHub and in the editor:

- In editor: `:help bemtvi-markdown-preview`
- On GitHub: [doc/bemtvi-markdown-preview.md](./doc/bemtvi-markdown-preview.md) (the help source)

## Development

Pure-Lua [`btv.test`](https://github.com/bemtvi/bemtvi) specs. `server_spec` drives the
routing directly with a fake `req`/`respond` — no socket, no browser — covering markdown
classification, `/buffers`, `/source`, `/file` and its bounding, and the `/` shell.
`page_spec` pins the page's client-side render invariants. `mount_spec` binds one real
mount and fetches every route over HTTP, so the plumbing either side of the handler is
covered too:

```sh
bemtvi --test-plugin .
```

The vimdoc `doc/bemtvi-markdown-preview.txt` is **generated** from
`doc/bemtvi-markdown-preview.md` via [panvimdoc](https://github.com/kdheepak/panvimdoc):
edit the `.md`, then run `bash scripts/gen-vimdoc.sh` (needs `pandoc` + `git`). Never edit
the `.txt` by hand.

## License

MIT — see [LICENSE](LICENSE).
