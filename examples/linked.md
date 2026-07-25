# Linked from disk

You got here by clicking a link in the preview — and this file was never opened as a
buffer. The editor read it off disk through the mount's `/file` route, bounded to markdown
inside the workspace.

The sidebar shows it in italics with a hollow dot: *from disk, not open as a buffer*.

Open it for real with `:e examples/linked.md` and the entry becomes a normal one — the
preview then renders the live buffer, so unsaved edits show up too.

[Back to sample.md](sample.md)
