-- Auto-loaded when the plugin is on the runtimepath (sourced from `plugin/` like a
-- neovim plugin). Registers :MarkdownPreview and friends so the commands exist out of the
-- box; setup() is idempotent, so a user calling require("nxvim-markdown-preview").setup()
-- is harmless. No mount is bound here — nothing opens a port until :MarkdownPreview.
require("nxvim-markdown-preview").setup()
