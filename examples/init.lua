-- Try nxvim-markdown-preview end-to-end (from the plugin repo root):
--
--     NXVIM_CONFIG=examples cargo run -p nxvim -- README.md   # (run from the nxvim repo)
--
-- …or point NXVIM_CONFIG at this dir with any markdown file. Then :MarkdownPreview
-- opens your browser at a live preview that follows the current buffer; open more
-- markdown buffers (:e other.md) and switch between them from the sidebar.
--
-- Put the plugin on the runtimepath (adjust the path to wherever you cloned it):
nx._add_rtp(os.getenv("HOME") .. "/work/nxvim-plugins/nxvim-markdown-preview")
require("nxvim-markdown-preview").setup()

-- Pin a stable, bookmarkable port instead of the ephemeral default (optional):
--   nx.o.httpport = 8080

-- A leader map, for convenience.
vim.g.mapleader = "\\"
nx.keymap.set("n", "<leader>p", "<cmd>MarkdownPreview<cr>", { desc = "Markdown preview" })
