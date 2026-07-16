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
-- With no `#id` in the URL it FOLLOWS the editor's active buffer; clicking a buffer in
-- the sidebar pins it (sets the hash); "⟳ follow editor" clears the pin.

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

// The pinned buffer id (from the URL hash), or null to FOLLOW the editor's active buffer.
function pinned() {
  const h = location.hash.slice(1);
  return h ? Number(h) : null;
}
followEl.onclick = () => { location.hash = ""; };

let shownId = null;    // the buffer currently rendered
let shownText = null;  // its last-rendered text, so we only re-render on change
let listKey = null;    // signature of the last sidebar, so we only rebuild on change

function setStatus(s) { statusEl.textContent = s; }

// Rebuild the sidebar from /buffers. textContent for labels — no escaping by hand.
function renderList(data, selId) {
  const key = JSON.stringify([data.list.map(b => [b.id, b.label]), data.active, selId]);
  if (key === listKey) return;
  listKey = key;
  listEl.replaceChildren();
  for (const b of data.list) {
    const btn = document.createElement("button");
    btn.className = "buf" + (b.id === selId ? " sel" : "") + (b.id === data.active ? " active" : "");
    btn.onclick = () => { location.hash = String(b.id); };
    const dot = document.createElement("span");
    dot.className = "dot";
    dot.textContent = "●";
    btn.append(dot, document.createTextNode(b.label));
    btn.title = b.name || b.label;
    listEl.append(btn);
  }
  if (data.list.length === 0) {
    const p = document.createElement("p");
    p.id = "empty";
    p.textContent = "no markdown buffers open";
    listEl.append(p);
  }
}

async function renderDoc(id) {
  const res = await fetch("source?buf=" + id, { cache: "no-store" });
  if (!res.ok) {                     // the buffer closed out from under us
    if (id === shownId) { shownId = null; shownText = null; }
    return;
  }
  const md = await res.text();
  if (id === shownId && md === shownText) return;   // unchanged — skip the re-render
  shownId = id; shownText = md;
  mainEl.innerHTML = marked.parse(md);
  await mermaid.run({ nodes: mainEl.querySelectorAll("pre.mermaid") });
}

function showEmpty(msg) {
  shownId = null; shownText = null;
  const p = document.createElement("p");
  p.id = "empty";
  p.textContent = msg;
  mainEl.replaceChildren(p);
}

async function tick() {
  try {
    const data = await (await fetch("buffers", { cache: "no-store" })).json();
    const pin = pinned();
    followEl.textContent = pin === null ? "⟳ following editor" : "⟳ follow editor";
    followEl.classList.toggle("on", pin === null);

    // Which buffer to show: the pin if it is still open, else the editor's active
    // markdown buffer, else the first one in the list.
    const ids = new Set(data.list.map(b => b.id));
    let sel = pin !== null && ids.has(pin) ? pin
      : (data.active != null ? data.active
      : (data.list[0] ? data.list[0].id : null));

    renderList(data, sel);
    if (sel === null) {
      showEmpty("no markdown buffers open");
      document.title = "markdown preview";
    } else {
      await renderDoc(sel);
      const b = data.list.find(x => x.id === sel);
      document.title = (b ? b.label : "buffer " + sel) + " — preview";
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
