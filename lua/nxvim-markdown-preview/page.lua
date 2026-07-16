-- The preview page: one self-contained HTML document served at the mount root. All
-- markdown rendering happens HERE, in the browser — the editor only serves bytes
-- (`/buffers`, `/source`). marked does the CommonMark/GFM parse and mermaid the diagram
-- fences, both loaded as ES modules from jsDelivr, so the page needs the network for
-- those two libraries (it renders your local buffers, but pulls the renderer from a CDN).
--
-- Escaping is the library's job, never ours: the code-block renderer returns `false` to
-- fall back to marked's default (which HTML-escapes), and every dynamic value the page
-- inserts (buffer labels, error text) is written through `textContent`, so nothing here
-- hand-rolls an escape.
--
-- Multi-buffer: the page polls `/buffers` for the open markdown buffers and renders one.
-- With no hash in the URL it FOLLOWS the editor's active buffer; the sidebar pins a buffer
-- (`#b:<id>`); "⟳ follow editor" clears the pin.
--
-- Link navigation: a click on a markdown link inside the rendered doc navigates the
-- preview to that file (`#f:<abs path>`) instead of the browser leaving the page — even
-- when the target is not an open buffer, in which case `/file` reads it straight from
-- disk. If the linked file *is* open, the page renders the live buffer instead. External
-- links open in a new tab; in-page `#anchor` links are left alone.

local M = {}

-- The mount renders content the user is actively editing (their own buffers), so this is
-- a modest CSP, not a sandbox: it confines the page to `'self'` plus the jsDelivr origin
-- the two libraries load from. marked does not sanitize, so raw HTML in a buffer renders
-- — expected for a preview of your own documents. NOTE the security caveat of nx.http
-- mounts: one shared origin, no cross-mount isolation (see httpmount.lua).
local CSP = table.concat({
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self' data: https://cdn.jsdelivr.net",
  "connect-src 'self' https://cdn.jsdelivr.net",
}, "; ")

-- Headers for the "/" response — HTML, plus the CSP above.
function M.headers()
  return {
    ["content-type"] = "text/html; charset=utf-8",
    ["content-security-policy"] = CSP,
    ["cache-control"] = "no-store",
  }
end

-- The page. A `[==[ ]==]` long bracket because the JS below contains `]]` in a regex,
-- which would close a plain `[[ ]]` string mid-page.
local HTML = [==[
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>markdown preview</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 16px/1.65 ui-sans-serif, system-ui, -apple-system, sans-serif; }
  #layout { display: flex; min-height: 100vh; }
  #side {
    flex: 0 0 15rem; border-right: 1px solid color-mix(in srgb, currentColor 15%, transparent);
    padding: 1rem .6rem; position: sticky; top: 0; align-self: flex-start; height: 100vh;
    overflow-y: auto; font-size: .85rem;
  }
  #side h2 {
    font-size: .68rem; text-transform: uppercase; letter-spacing: .06em; opacity: .5;
    margin: 0 .4rem .5rem; font-weight: 600;
  }
  .buf {
    display: block; width: 100%; text-align: left; border: 0; background: none;
    color: inherit; font: inherit; padding: .35rem .5rem; border-radius: 6px;
    cursor: pointer; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .buf:hover { background: color-mix(in srgb, currentColor 8%, transparent); }
  .buf.sel { background: color-mix(in srgb, currentColor 14%, transparent); font-weight: 600; }
  .buf .dot { opacity: 0; margin-right: .4rem; }
  .buf.active .dot { opacity: .9; color: #3fb950; }
  .buf.disk { font-style: italic; }
  .buf.disk .dot { opacity: .6; }
  #follow {
    margin: .8rem .4rem 0; font-size: .72rem; opacity: .6; cursor: pointer;
    background: none; border: 0; color: inherit; padding: .3rem 0;
  }
  #follow:hover { opacity: 1; }
  #follow.on { color: #3fb950; opacity: .9; }
  #main { flex: 1 1 auto; min-width: 0; padding: 2rem 2.2rem; max-width: 52rem; }
  #status { position: fixed; top: .6rem; right: .8rem; font-size: .72rem; opacity: .5; font-family: ui-monospace, monospace; }
  h1, h2, h3 { line-height: 1.25; margin: 1.6em 0 .5em; }
  h1 { border-bottom: 1px solid color-mix(in srgb, currentColor 18%, transparent); padding-bottom: .25em; }
  code { font: .88em ui-monospace, SFMono-Regular, Menlo, monospace; background: color-mix(in srgb, currentColor 10%, transparent); padding: .15em .35em; border-radius: 4px; }
  pre { background: color-mix(in srgb, currentColor 7%, transparent); padding: .9rem 1rem; border-radius: 8px; overflow-x: auto; }
  pre code { background: none; padding: 0; }
  pre.mermaid { background: none; text-align: center; }
  blockquote { margin: 1em 0; padding: .1em 1em; border-left: 3px solid color-mix(in srgb, currentColor 25%, transparent); opacity: .85; }
  hr { border: none; border-top: 1px solid color-mix(in srgb, currentColor 20%, transparent); margin: 2em 0; }
  a { color: #4493f8; }
  img { max-width: 100%; }
  table { border-collapse: collapse; }
  td, th { border: 1px solid color-mix(in srgb, currentColor 20%, transparent); padding: .35em .7em; }
  #empty { opacity: .5; font-style: italic; }
</style>
</head>
<body>
<div id="status">connecting…</div>
<div id="layout">
  <nav id="side">
    <h2>markdown buffers</h2>
    <div id="buflist"></div>
    <button id="follow" title="Render whichever buffer is active in the editor"></button>
  </nav>
  <article id="main"><p id="empty">loading…</p></article>
</div>
<script type="module">
import { marked } from "https://cdn.jsdelivr.net/npm/marked/+esm";
import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.esm.min.mjs";

// mermaid fences become <pre class="mermaid">; every other code block returns false so
// marked's own (escaping) renderer handles it. No hand-rolled escape.
marked.use({ renderer: { code({ text, lang }) {
  return lang === "mermaid" ? `<pre class="mermaid">${text}</pre>` : false;
}}});
marked.use({ gfm: true, breaks: false });
mermaid.initialize({ startOnLoad: false });

const statusEl = document.getElementById("status");
const listEl = document.getElementById("buflist");
const mainEl = document.getElementById("main");
const followEl = document.getElementById("follow");

const MD_RE = /\.(md|markdown|mdown|mkd|mkdn|mdx)$/i;

// ----- selection (the URL hash) --------------------------------------------
// #b:<id>  a live buffer   |   #f:<abs path>  a file read from disk   |   (none) follow.
function parseSel() {
  const raw = location.hash.slice(1);
  if (raw.startsWith("b:")) { const id = Number(raw.slice(2)); return Number.isFinite(id) ? { buf: id } : null; }
  if (raw.startsWith("f:")) return { file: decodeURIComponent(raw.slice(2)) };
  return null;   // follow the editor's active buffer
}
followEl.onclick = () => { location.hash = ""; };
addEventListener("hashchange", tick);   // navigate at once, not only on the next poll

// ----- path helpers (POSIX-style, no file:// needed) -----------------------
// The directory of `p`; "" when `p` has no slash (so a bare name is not treated as a dir).
const dirOf = (p) => { const i = p.lastIndexOf("/"); return i < 0 ? "" : p.slice(0, i); };
const baseName = (p) => p.replace(/\/+$/, "").split("/").pop();
// Resolve a link target against the directory of the file it appears in, honouring a
// leading "/" (absolute) and "."/".." segments.
function resolvePath(baseDir, href) {
  href = decodeURIComponent(href.split(/[?#]/)[0]);
  const stack = href.startsWith("/") ? [] : baseDir.split("/").filter(Boolean);
  for (const seg of href.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") stack.pop();
    else stack.push(seg);
  }
  return "/" + stack.join("/");
}

// ----- render --------------------------------------------------------------
let shownKey = null;   // "b:<id>" / "f:<path>" of what is rendered, for change detection
let shownText = null;  // its last text, so an unchanged poll does not re-render
let shownPath = null;  // the rendered doc's absolute path, the base for link resolution
let listKey = null;    // signature of the last sidebar, so we only rebuild on a change

function setStatus(s) { statusEl.textContent = s; }

// Fetch `url` and render it, unless its text is unchanged from last time. Returns false
// when the source is gone (a closed buffer, an unreadable file) so the caller can react.
async function renderFrom(url, key, path) {
  const res = await fetch(url, { cache: "no-store" });
  if (!res.ok) { if (key === shownKey) { shownKey = null; shownText = null; } return false; }
  const md = await res.text();
  shownPath = path;
  if (key === shownKey && md === shownText) return true;
  shownKey = key; shownText = md;
  mainEl.innerHTML = marked.parse(md);
  await mermaid.run({ nodes: mainEl.querySelectorAll("pre.mermaid") });
  return true;
}

function showEmpty(msg) {
  shownKey = null; shownText = null; shownPath = null;
  const p = document.createElement("p"); p.id = "empty"; p.textContent = msg;
  mainEl.replaceChildren(p);
}

// Rebuild the sidebar: the open buffers, plus — when we are viewing a linked file that is
// NOT open — one italic entry for it, so the selection is always legible. textContent for
// every label, so nothing is escaped by hand.
function renderList(data, sel, diskFile) {
  const key = JSON.stringify([data.list.map(b => [b.id, b.label]), data.active, sel, diskFile]);
  if (key === listKey) return;
  listKey = key;
  listEl.replaceChildren();
  for (const b of data.list) {
    const btn = document.createElement("button");
    btn.className = "buf" + (sel && sel.buf === b.id ? " sel" : "") + (b.id === data.active ? " active" : "");
    btn.onclick = () => { location.hash = "b:" + b.id; };
    const dot = document.createElement("span"); dot.className = "dot"; dot.textContent = "●";
    btn.append(dot, document.createTextNode(b.label));
    btn.title = b.name || b.label;
    listEl.append(btn);
  }
  if (diskFile) {
    const btn = document.createElement("button");
    btn.className = "buf disk sel";
    btn.onclick = () => { location.hash = "f:" + encodeURIComponent(diskFile); };
    const dot = document.createElement("span"); dot.className = "dot"; dot.textContent = "○";
    btn.append(dot, document.createTextNode(baseName(diskFile)));
    btn.title = diskFile + "  (from disk — not open as a buffer)";
    listEl.append(btn);
  }
  if (data.list.length === 0 && !diskFile) {
    const p = document.createElement("p"); p.id = "empty"; p.textContent = "no markdown buffers open";
    listEl.append(p);
  }
}

// A click on a link inside the rendered doc. External links open in a new tab; an in-page
// anchor is left alone; a link to a MARKDOWN file navigates the preview (pinning it as a
// disk file — a tick then prefers the live buffer if that file happens to be open).
mainEl.addEventListener("click", (e) => {
  const a = e.target.closest("a");
  if (!a) return;
  const href = a.getAttribute("href") || "";
  if (!href || href.startsWith("#")) return;
  if (/^[a-z][a-z0-9+.-]*:/i.test(href)) { a.target = "_blank"; a.rel = "noopener"; return; }
  if (!shownPath) return;                          // no base path to resolve against
  const path = resolvePath(dirOf(shownPath), href);
  if (!MD_RE.test(path)) return;                   // only markdown links drive the preview
  e.preventDefault();
  location.hash = "f:" + encodeURIComponent(path);
});

// ----- poll ----------------------------------------------------------------
async function tick() {
  try {
    const data = await (await fetch("buffers", { cache: "no-store" })).json();
    const sel = parseSel();
    followEl.textContent = sel === null ? "⟳ following editor" : "⟳ follow editor";
    followEl.classList.toggle("on", sel === null);

    // Resolve the selection to a concrete target. A file selection prefers the LIVE
    // buffer when that path is already open (so unsaved edits show), else reads disk.
    const byName = new Map(data.list.map(b => [b.name, b]));
    let target = null, effSel = null, diskFile = null;
    if (sel && sel.file) {
      const open = byName.get(sel.file);
      if (open) { target = { buf: open.id }; effSel = { buf: open.id }; }
      else { target = { file: sel.file }; diskFile = sel.file; }
    } else if (sel && sel.buf != null && data.list.some(b => b.id === sel.buf)) {
      target = { buf: sel.buf }; effSel = target;
    } else if (data.active != null) {
      target = { buf: data.active }; effSel = target;
    } else if (data.list[0]) {
      target = { buf: data.list[0].id }; effSel = target;
    }

    renderList(data, effSel, diskFile);

    if (!target) {
      showEmpty("no markdown buffers open");
      document.title = "markdown preview";
    } else if (target.buf != null) {
      const b = data.list.find(x => x.id === target.buf);
      await renderFrom("source?buf=" + target.buf, "b:" + target.buf, b ? b.name : null);
      document.title = (b ? b.label : "buffer " + target.buf) + " — preview";
    } else {
      const ok = await renderFrom("file?path=" + encodeURIComponent(target.file), "f:" + target.file, target.file);
      if (!ok) showEmpty("cannot read " + target.file);
      document.title = baseName(target.file) + " — preview";
    }
    setStatus("live");
  } catch (e) {
    setStatus("editor gone (" + e.message + ")");
  }
}

tick();
setInterval(tick, 500);
</script>
</body>
</html>
]==]

-- The page shell, served at "/". Static: it carries no per-request state, the browser
-- pulls buffer state from `/buffers` and `/source`.
function M.html()
  return HTML
end

return M
