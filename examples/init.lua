-- Try nxvim-markdown-preview end-to-end, from THIS repo's root:
--
--     NXVIM_CONFIG=examples nxvim examples/sample.md
--
-- Then :MarkdownPreview (or <leader>p) opens your browser at a live preview, and
-- `examples/sample.md` walks you through every feature — live edit, the cursor line,
-- code fences, mermaid, relative images, link navigation, the buffer sidebar.
--
-- Run it from the nxvim repo instead if you are building the editor:
--
--     NXVIM_CONFIG=<this dir> cargo run -p nxvim -- <this dir>/sample.md
--
-- The cwd is the workspace root, and the mount only reads markdown and images from
-- inside it — so run from the repo root, not from examples/, or the relative image in
-- sample.md resolves outside the workspace and is refused.
--
-- Put the plugin on the runtimepath (adjust the path to wherever you cloned it):
nx._add_rtp(os.getenv("HOME") .. "/work/nxvim-plugins/nxvim-markdown-preview")
require("nxvim-markdown-preview").setup()

-- Pin a stable, bookmarkable port instead of the ephemeral default (optional):
--   nx.o.httpport = 8080

-- A leader map, for convenience.
vim.g.mapleader = "\\"
nx.keymap.set("n", "<leader>p", "<cmd>MarkdownPreview<cr>", { desc = "Markdown preview" })
