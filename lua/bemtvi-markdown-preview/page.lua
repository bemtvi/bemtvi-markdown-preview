-- The preview page: one self-contained HTML document served at the mount root. All
-- markdown rendering happens HERE, in the browser — the editor only serves bytes
-- (`/buffers`, `/source`). marked does the CommonMark/GFM parse, highlight.js the code-
-- fence syntax highlighting (~190 languages), and mermaid the diagram fences — all loaded
-- as ES modules from jsDelivr, so the page needs the network for those libraries (it
-- renders your local buffers, but pulls the renderer from a CDN).
--
-- Containment. marked does not sanitize, so a document's raw HTML renders — and a README
-- from a repo under review is not the user's own content. So the page is TWO documents:
--
--   * the SHELL (this page, served with the mount's `same_origin = true`): the sidebar,
--     the poll, the marked/highlight.js parse. It is entirely this plugin's own code, and
--     it is the only part that can reach the mount (`fetch` back to `/buffers` & co.).
--   * the DOC FRAME: an `<iframe sandbox="allow-scripts" srcdoc>` WITHOUT
--     `allow-same-origin`, holding the rendered markdown. It runs in an opaque origin, so
--     nothing in a document can read the shell, the mount, the editor page (web build) or
--     its storage. Its own CSP admits only the shell's per-load-nonced agent script (and
--     mermaid from its pinned CDN path): a document's `<script>` or `onerror=` never runs,
--     and `default-src 'none'` leaves it no network but `data:`/`https:` images.
--
-- The shell parses each block into an INERT `<template>` (no script runs, no image loads
-- there), rewrites its images to `data:` URLs, and posts the serialized HTML to the frame's
-- agent, which places it. Rendered HTML never enters the shell's live DOM. The frame talks
-- back with one message, a clicked link's `href`, which the shell treats as untrusted.
--
-- Escaping is the library's job wherever there is a library to do it: highlight.js returns
-- escaped markup, the code-block renderer returns `false` to fall back to marked's default
-- (which HTML-escapes), and every dynamic value the page inserts (buffer labels, error
-- text) is written through `textContent`. The one exception is the mermaid fence, whose
-- source the page must put back into the DOM as text for mermaid to read — that single
-- insertion escapes explicitly (`esc()`).
--
-- Re-render is INCREMENTAL. The page polls twice a second while you type, and re-parsing,
-- re-highlighting and re-drawing the whole document on every poll is the one thing here
-- that scales with document size rather than with the edit. So a poll diffs the lexer's
-- top-level blocks against what is on screen and only replaces the ones whose source text
-- actually changed; everything else keeps its DOM (mermaid diagrams included, which is
-- what keeps them from flickering on every keystroke).
--
-- Multi-buffer: the page polls `/buffers` for the open markdown buffers and renders one.
-- With no hash in the URL it FOLLOWS the editor's active buffer; the sidebar pins a buffer
-- (`#b:<id>`); "⟳ follow editor" clears the pin.
--
-- Cursor line: each block is wrapped with its source-line range, so the editor's cursor
-- line (polled from `/buffers`) is mapped back to a rendered block and highlighted — but
-- only while the page is showing the editor's ACTIVE buffer, the one the cursor is in.
-- A "⭱ follow cursor" toggle (remembered in localStorage) additionally scrolls that block
-- into view as the cursor moves; off by the user's choice, it just highlights.
--
-- Link navigation: a click on a markdown link inside the rendered doc navigates the
-- preview to that file (`#f:<abs path>`) instead of the browser leaving the page — even
-- when the target is not an open buffer, in which case `/file` reads it straight from
-- disk. If the linked file *is* open, the page renders the live buffer instead. External
-- `http(s):`/`mailto:` links open in a new tab (any other scheme — `javascript:` — is
-- dropped); in-page `#anchor` links are left alone.
--
-- Images: a relative `![](img/x.png)` is fetched by the shell from the mount's `/asset`
-- route and inlined as a `data:` URL as the block renders, so an image committed beside
-- the document loads. Same reason links go through `/file` — the browser has no
-- filesystem, so the bytes have to come from the editor. Inlined rather than pointed at
-- the mount because the sandboxed frame cannot load from the mount itself: natively its
-- requests carry `Origin: null`, and on the web build they bypass the Service Worker. An
-- `https:` or `data:` src is left alone.

local M = {}

-- The SHELL's CSP. The shell is this plugin's own code (rendered documents live in the
-- sandboxed doc frame, see the top of this file), so this is a modest CSP: it confines the
-- page to `'self'` plus the jsDelivr origin the libraries load from. The doc frame inherits
-- it and adds its own, stricter one (`FRAME_CSP` in the page).
--
-- `img-src` is the one directive deliberately wider than the rest. A document's images come
-- from three places: `'self'` covers the mount's own `/asset` route (a relative image read
-- off disk), `data:` an inline one, and `https:` a badge or hosted screenshot — which
-- confining images to `'self'` would render broken. Plain `http:` is not allowed; an image
-- is inert either way, so this widens what the page can *display*, not what it can run.
local CSP = table.concat({
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net",
  "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net",
  "img-src 'self' data: https:",
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
<!-- An empty data: icon, so the browser does not go asking the mount for /favicon.ico —
     which is not a route, so every tab would log a console 404 on load. -->
<link rel="icon" href="data:,">
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
  #follow, #cursorfollow {
    display: block; margin: 0 .4rem; font-size: .72rem; opacity: .6; cursor: pointer;
    background: none; border: 0; color: inherit; padding: .3rem 0; text-align: left;
  }
  #follow { margin-top: .8rem; }
  #follow:hover, #cursorfollow:hover { opacity: 1; }
  #follow.on, #cursorfollow.on { color: #3fb950; opacity: .9; }
  /* The rendered document lives in the sandboxed frame, which scrolls on its own. */
  #main { flex: 1 1 auto; min-width: 0; height: 100vh; position: sticky; top: 0; }
  #doc { display: block; width: 100%; height: 100%; border: 0; }
  #status { position: fixed; top: .6rem; right: .8rem; font-size: .72rem; opacity: .5; font-family: ui-monospace, monospace; }
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
    <button id="cursorfollow" title="Scroll to keep the editor's cursor line in view"></button>
  </nav>
  <!-- The rendered document. sandbox WITHOUT allow-same-origin: an opaque origin, so a
       document's own markup can never reach this page, the mount, or the editor. -->
  <article id="main"><iframe id="doc" sandbox="allow-scripts" title="rendered document"></iframe></article>
</div>
<script type="module">
import { marked } from "https://cdn.jsdelivr.net/npm/marked/+esm";
import hljs from "https://cdn.jsdelivr.net/npm/highlight.js@11/+esm";   // ~190 languages

// The page's ONE hand-rolled escape: a mermaid fence goes back into the DOM as source
// text for mermaid to read, so it cannot be interpolated raw — a diagram containing
// markup would be parsed as HTML, and a literal "</pre>" would break out of the block.
const esc = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);

// Auto-detection runs the text through every grammar highlight.js has, so it is by far
// the most expensive thing a render does. Past this size an unlabelled fence is left
// plain rather than spending seconds on it inside a poll.
const HL_MAX = 100000;

// mermaid fences become <pre class="mermaid">, drawn by mermaid INSIDE the doc frame;
// every other code block is syntax-highlighted by highlight.js — by the fence's language
// when it names a known one, else auto-detected. hljs.highlight()/highlightAuto() return
// HTML-escaped, span-wrapped markup, so escaping is the library's job there. Returning
// false anywhere here falls back to marked's own code renderer, which escapes too.
marked.use({ renderer: { code({ text, lang }) {
  if (lang === "mermaid") return `<pre class="mermaid">${esc(text)}</pre>`;
  const language = lang && hljs.getLanguage(lang) ? lang : null;
  if (!language && text.length > HL_MAX) return false;
  try {
    const out = language ? hljs.highlight(text, { language }) : hljs.highlightAuto(text);
    return `<pre><code class="hljs${language ? " language-" + language : ""}">${out.value}</code></pre>`;
  } catch { return false; }
}}});
marked.use({ gfm: true, breaks: false });

const statusEl = document.getElementById("status");
const listEl = document.getElementById("buflist");
const frameEl = document.getElementById("doc");
const followEl = document.getElementById("follow");
const cursorFollowEl = document.getElementById("cursorfollow");

const MD_RE = /\.(md|markdown|mdown|mkd|mkdn|mdx)$/i;
const POLL_MS = 500;

// The mount's base path, for the relative fetches below. mount:url() is trailing-slashed,
// but a URL typed or bookmarked without the slash serves the same page — and then a bare
// "buffers" would resolve one level UP, out of the mount, and every poll would 404. So
// derive the base rather than trusting the address bar to end in "/".
const BASE = location.pathname.endsWith("/") ? location.pathname : location.pathname + "/";

// ----- the sandboxed doc frame ---------------------------------------------
// A fresh nonce per page load: the frame's CSP runs ONLY the script carrying it (the agent
// below) plus mermaid from its pinned path, so markup in a document — a <script>, an
// onerror= — never executes, and default-src 'none' gives it no network at all.
const NONCE = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("");
const MERMAID = "https://cdn.jsdelivr.net/npm/mermaid@10/dist/";
const FRAME_CSP = [
  "default-src 'none'",
  `script-src 'nonce-${NONCE}' ${MERMAID}`,
  "style-src 'unsafe-inline' https://cdn.jsdelivr.net",
  "img-src data: https:",
  "font-src data: https://cdn.jsdelivr.net",
].join("; ");

// The frame's agent: places the blocks the shell posts, marks the cursor block, draws
// mermaid diagrams, and reports link clicks back. It only ever ACCEPTS messages from the
// shell (its parent); the one thing it sends is { t: "link", href }.
const AGENT = `
const main = document.getElementById("main");
const els = new Map();          // block id -> element
let cursor = null;
let mermaidP = null;
const loadMermaid = () => mermaidP || (mermaidP = import("${MERMAID}mermaid.esm.min.mjs")
  .then((m) => { m.default.initialize({ startOnLoad: false, securityLevel: "strict" }); return m.default; })
  .catch(() => null));
// mermaid THROWS on a diagram it cannot parse, which is the normal state of a fence you are
// halfway through typing; contain that so a bad diagram stays as its source text.
async function runMermaid(els) {
  const nodes = [];
  for (const el of els) for (const n of el.querySelectorAll("pre.mermaid")) nodes.push(n);
  if (nodes.length === 0) return;
  const mermaid = await loadMermaid();
  if (!mermaid) return;
  try { await mermaid.run({ nodes, suppressErrors: true }); } catch {}
}
addEventListener("message", (e) => {
  if (e.source !== parent || !e.data) return;
  const m = e.data;
  if (m.t === "render") {
    if (m.reset) { els.clear(); cursor = null; }
    const fresh = [];
    for (const [id, html] of m.add) {
      const el = document.createElement("div");
      el.className = "blk";
      el.innerHTML = html;
      els.set(id, el);
      fresh.push(el);
    }
    const keep = new Set(m.order);
    for (const id of [...els.keys()]) if (!keep.has(id)) els.delete(id);
    main.replaceChildren(...m.order.map((id) => els.get(id)).filter(Boolean));
    if (cursor && !cursor.isConnected) cursor = null;
    if (m.reset) scrollTo(0, 0);
    runMermaid(fresh);
  } else if (m.t === "empty") {
    els.clear(); cursor = null;
    const p = document.createElement("p");
    p.id = "empty";
    p.textContent = String(m.text);
    main.replaceChildren(p);
  } else if (m.t === "cursor") {
    const hit = m.id == null ? null : (els.get(m.id) || null);
    if (hit !== cursor) {
      if (cursor) cursor.classList.remove("cursor-here");
      if (hit) hit.classList.add("cursor-here");
      cursor = hit;
    }
    if (m.scroll && hit) hit.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }
});
// Every link click goes to the shell, which decides; only an in-page #anchor stays here.
function onLink(e) {
  const a = e.target && e.target.closest ? e.target.closest("a") : null;
  if (!a) return;
  const href = a.getAttribute("href") || "";
  if (!href || href.startsWith("#")) return;
  e.preventDefault();
  parent.postMessage({ t: "link", href }, "*");
}
addEventListener("click", onLink);
addEventListener("auxclick", onLink);
parent.postMessage({ t: "ready" }, "*");
`;

const FRAME_HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="${FRAME_CSP}">
<!-- highlight.js token themes, one per colour scheme; each is a couple of KB. -->
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/highlight.js@11/styles/github.min.css" media="(prefers-color-scheme: light)">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/highlight.js@11/styles/github-dark.min.css" media="(prefers-color-scheme: dark)">
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 16px/1.65 ui-sans-serif, system-ui, -apple-system, sans-serif; }
  #main { padding: 2rem 2.2rem; max-width: 52rem; }
  /* Each top-level block is wrapped so it can take the cursor-line highlight and be
     replaced on its own when its source changes; the negative margin keeps its text
     aligned with the rest. */
  .blk { padding: 0 .6rem; margin: 0 -.6rem; border-radius: 6px; transition: background .1s; }
  .blk.cursor-here { background: color-mix(in srgb, #4493f8 14%, transparent); box-shadow: inset 3px 0 0 #4493f8; }
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
</style></head>
<body><main id="main"><p id="empty">loading…</p></main>
<script nonce="${NONCE}">${AGENT}<\/script></body></html>`;

// Messages to the frame wait for its agent to say it is listening (a handshake rather than
// the load event, which the iframe's initial about:blank can also fire). Posted to "*"
// because the frame's origin is opaque ("null") and cannot be named.
let frameLoaded = false;
const outbox = [];
function post(m) {
  if (frameLoaded) frameEl.contentWindow.postMessage(m, "*");
  else outbox.push(m);
}
addEventListener("message", (e) => {
  if (frameLoaded || e.source !== frameEl.contentWindow || !e.data || e.data.t !== "ready") return;
  frameLoaded = true;
  for (const m of outbox.splice(0)) frameEl.contentWindow.postMessage(m, "*");
});
frameEl.srcdoc = FRAME_HTML;

// localStorage throws outright where storage is blocked (some private-browsing and
// embedded contexts). The toggle then just doesn't persist, instead of the exception
// taking the whole module down at load.
const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch {} },
};

// ----- cursor-follow toggle (auto-scroll) ----------------------------------
// When on, the preview scrolls to keep the editor's cursor line in view. A user choice,
// remembered across reloads; default on. Toggling on re-scrolls to the current cursor.
let autoScroll = store.get("btvmp.autoscroll") !== "0";
let lastCursorLine = null;   // the last line applyCursor scrolled for; null re-arms a scroll
function renderCursorFollow() {
  cursorFollowEl.textContent = autoScroll ? "⭱ following cursor" : "⭱ follow cursor";
  cursorFollowEl.classList.toggle("on", autoScroll);
}
cursorFollowEl.onclick = () => {
  autoScroll = !autoScroll;
  store.set("btvmp.autoscroll", autoScroll ? "1" : "0");
  lastCursorLine = null;   // so enabling scrolls to the cursor on the next poll
  renderCursorFollow();
};
renderCursorFollow();

// ----- selection (the URL hash) --------------------------------------------
// #b:<id>  a live buffer   |   #f:<abs path>  a file read from disk   |   (none) follow.
function parseSel() {
  const raw = location.hash.slice(1);
  // A bufnr is a positive integer; anything else in the hash is not a buffer we can ask
  // for (Number("") is 0, which btv.buf.* would read as "the current buffer").
  if (raw.startsWith("b:")) { const id = Number(raw.slice(2)); return Number.isInteger(id) && id > 0 ? { buf: id } : null; }
  if (raw.startsWith("f:")) return { file: decode(raw.slice(2)) };
  return null;   // follow the editor's active buffer
}
followEl.onclick = () => { location.hash = ""; };
addEventListener("hashchange", () => runTick());   // navigate at once, not on the next poll

// ----- path helpers (POSIX-style, no file:// needed) -----------------------
// decodeURIComponent throws on a malformed escape (a bare "%" in a link target); a link
// the page cannot decode is passed through verbatim rather than taking the click handler
// — or, from parseSel, the whole poll — down with it.
const decode = (s) => { try { return decodeURIComponent(s); } catch { return s; } };
// The directory of `p`; "" when `p` has no slash (so a bare name is not treated as a dir).
const dirOf = (p) => { const i = p.lastIndexOf("/"); return i < 0 ? "" : p.slice(0, i); };
const baseName = (p) => p.replace(/\/+$/, "").split("/").pop();
// Resolve a link or image target against the directory of the file it appears in, honouring
// "."/".." segments. A LEADING "/" is workspace-relative, not filesystem-absolute — that is
// what it means everywhere markdown is written (`/docs/x.md`, `/img/logo.png` are repo-root
// paths, and the mount only serves inside the workspace anyway), so it resolves against
// `docRoot`. Before the first poll `docRoot` is "" and such a path stays filesystem-
// absolute, which the workspace bound then refuses — the safe direction to be wrong in.
function resolvePath(baseDir, href) {
  href = decode(href.split(/[?#]/)[0]);
  const base = href.startsWith("/") ? docRoot : baseDir;
  const stack = base.split("/").filter(Boolean);
  for (const seg of href.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") stack.pop();
    else stack.push(seg);
  }
  return "/" + stack.join("/");
}

// An image's bytes from the mount's /asset route, as a data: URL (null when it cannot be
// read). The sandboxed frame cannot load from the mount itself, so the shell fetches and
// inlines. Cached per document (cleared on a switch), so a re-rendered block does not
// refetch every image in it.
const assetCache = new Map();   // abs path -> Promise<string | null>
function assetData(path) {
  let p = assetCache.get(path);
  if (!p) {
    p = fetch(BASE + "asset?path=" + encodeURIComponent(path), { cache: "no-store" })
      .then((r) => (r.ok ? r.blob() : null))
      .then((blob) => blob && new Promise((res) => {
        const fr = new FileReader();
        fr.onload = () => res(String(fr.result));
        fr.onerror = () => res(null);
        fr.readAsDataURL(blob);
      }))
      .catch(() => null);
    assetCache.set(path, p);
  }
  return p;
}

// Point a document-relative <img src> at the mount's own /asset route — inlined. The browser
// has no filesystem, so a screenshot committed beside the document can only reach the page
// through the editor — the same reason a link to a closed file goes through /file. Anything
// already carrying a scheme (https:, data:) or protocol-relative is left exactly as the
// author wrote it, and so is an image in a document we have no path for (nothing to resolve
// against). `srcset` is not rewritten — marked never emits one, and a hand-written one in
// raw HTML keeps whatever the author put there. `el` is an INERT template fragment, so
// setting src here loads nothing.
async function localizeImages(el) {
  if (!shownPath) return;
  const jobs = [];
  for (const img of el.querySelectorAll("img")) {
    const src = img.getAttribute("src") || "";
    if (!src || src.startsWith("//") || /^[a-z][a-z0-9+.-]*:/i.test(src)) continue;
    const path = resolvePath(dirOf(shownPath), src);
    jobs.push(assetData(path).then((data) => {
      if (data) img.setAttribute("src", data);
      else img.removeAttribute("src");
    }));
  }
  await Promise.all(jobs);
}

// ----- render --------------------------------------------------------------
let shownKey = null;    // "b:<id>" / "f:<path>" of what is rendered, for change detection
let shownText = null;   // its last text, so an unchanged poll does not re-render
let shownPath = null;   // the rendered doc's absolute path, the base for link resolution
let docRoot = "";       // the editor's workspace root, the base for a "/…" link or image
let shownBlocks = [];   // [{ raw, ls, le, id }] currently in the frame, in document order
let cursorId = null;    // the block id carrying the cursor highlight
let nextBlockId = 1;    // block ids are never reused, so the frame cannot confuse two
let listKey = null;     // signature of the last sidebar, so we only rebuild on a change
let statusText = null;  // last status written, so an unchanged poll writes no DOM

function setStatus(s) { if (s !== statusText) { statusText = s; statusEl.textContent = s; } }
function setTitle(t) { if (document.title !== t) document.title = t; }

// Lex markdown into its top-level blocks, each carrying its SOURCE-line range. Tokens'
// `raw` concatenate to the source, so counting their newlines tracks the line each block
// starts and ends on — which is how the editor's cursor line maps back to a rendered
// block, and (with `raw` as the identity) how a re-render knows which blocks changed.
function lexBlocks(md) {
  const tokens = marked.lexer(md);
  const blocks = [];
  let line = 1;
  for (const tok of tokens) {
    const raw = tok.raw || "";
    const nl = (raw.match(/\n/g) || []).length;
    const ls = line, le = ls + nl - (raw.endsWith("\n") ? 1 : 0);
    line += nl;
    if (tok.type === "space") continue;   // blank runs render nothing to mark
    blocks.push({ raw, ls, le, tok, links: tokens.links });
  }
  return blocks;
}

// One block's HTML, for the frame. Parsed into an inert <template> — scripts there never
// run and images never load — and serialized straight back out, so the document's markup
// never touches this page's live DOM.
async function renderBlock(b) {
  const tpl = document.createElement("template");
  const one = [b.tok]; one.links = b.links;   // keep reference-link defs for the parser
  tpl.innerHTML = marked.parser(one);
  const el = tpl.content;
  await localizeImages(el);
  return tpl.innerHTML;
}

// Re-render `md` into the frame, REUSING every block whose source text is unchanged, and
// send only the freshly-built ones. This is what keeps the poll's cost proportional to the
// edit instead of to the document: typing in one paragraph re-parses that paragraph, and
// the twenty highlighted code fences and mermaid diagrams above it keep the DOM (and the
// pixels) they already have — the frame's agent draws mermaid for the fresh blocks only.
//
// Blocks are matched by their raw source, taken in order, so a document with several
// identical blocks still pairs each with its own element.
async function reconcile(md, reset) {
  const reusable = new Map();   // raw -> queue of block ids from the previous render
  for (const p of shownBlocks) {
    let q = reusable.get(p.raw);
    if (!q) reusable.set(p.raw, q = []);
    q.push(p.id);
  }
  const next = [], fresh = [];
  for (const b of lexBlocks(md)) {
    const q = reusable.get(b.raw);
    let id = (q && q.length) ? q.shift() : null;
    if (id == null) { id = nextBlockId++; fresh.push([id, renderBlock(b)]); }
    next.push({ raw: b.raw, ls: b.ls, le: b.le, id });
  }
  const add = await Promise.all(fresh.map(async ([id, html]) => [id, await html]));
  shownBlocks = next;
  if (cursorId != null && !next.some((n) => n.id === cursorId)) cursorId = null;
  post({ t: "render", order: next.map((n) => n.id), add, reset });
}

// Fetch `url` and render it, unless its text is unchanged from last time. Returns false
// when the source is gone (a closed buffer, an unreadable file) so the caller can react.
async function renderFrom(url, key, path) {
  const res = await fetch(url, { cache: "no-store" });
  if (!res.ok) { if (key === shownKey) { shownKey = null; shownText = null; } return false; }
  const md = await res.text();
  shownPath = path;
  if (key === shownKey && md === shownText) return true;
  const switched = key !== shownKey;   // a different doc, not just a live edit of this one
  // Another document's blocks (and images) are not ours to reuse, however alike they look.
  // Switching documents also starts the frame at the top (`scrollTo(0, 0)` in the agent);
  // an edit to the SAME doc keeps your place.
  if (switched) { shownBlocks = []; cursorId = null; assetCache.clear(); }
  shownKey = key; shownText = md;
  await reconcile(md, switched);
  return true;
}

// Mark the block that holds source `line` (1-based) as the cursor line; `null` clears it.
// Cheap enough to run every poll — the cursor moves without the text changing, so this is
// separate from the re-render, and it messages the frame only when something changes.
// When cursor-follow is on, the frame scrolls that block into view (`hit.scrollIntoView`
// in the agent) — but only when the line actually CHANGED, so a user who scrolls away
// while the cursor sits still is not yanked back every poll; the follow resumes on the
// next cursor move.
function applyCursor(line) {
  let hit = null;
  if (line != null) {
    for (const b of shownBlocks) {
      if (b.ls > line) break;   // blocks are in source order, so this one is past it
      if (line <= b.le) { hit = b.id; break; }
    }
  }
  const scroll = Boolean(autoScroll && hit && line !== lastCursorLine);
  if (hit !== cursorId || scroll) post({ t: "cursor", id: hit, scroll });
  cursorId = hit;
  lastCursorLine = line;
}

function showEmpty(msg) {
  shownKey = null; shownText = null; shownPath = null;
  shownBlocks = []; cursorId = null;
  post({ t: "empty", text: msg });
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

// A link clicked inside the rendered doc, reported by the frame's agent. The `href` came
// out of the document, so it is UNTRUSTED: only `http(s):`/`mailto:` (and protocol-relative)
// links open, in a new tab with no opener — a `javascript:` or any other scheme is
// dropped, since opening it from here would run it with this page's privileges. A link to
// a MARKDOWN file navigates the preview (pinning it as a disk file — a tick then prefers
// the live buffer if that file happens to be open); any other relative link does nothing.
addEventListener("message", (e) => {
  if (e.source !== frameEl.contentWindow || !e.data || e.data.t !== "link") return;
  const href = e.data.href;
  if (typeof href !== "string" || !href) return;
  if (href.startsWith("//") || /^[a-z][a-z0-9+.-]*:/i.test(href)) {
    if (href.startsWith("//") || /^(https?|mailto):/i.test(href)) window.open(href, "_blank", "noopener");
    return;
  }
  if (!shownPath) return;                          // no base path to resolve against
  const path = resolvePath(dirOf(shownPath), href);
  if (!MD_RE.test(path)) return;                   // only markdown links drive the preview
  location.hash = "f:" + encodeURIComponent(path);
});

// ----- poll ----------------------------------------------------------------
async function tick() {
  try {
    const data = await (await fetch(BASE + "buffers", { cache: "no-store" })).json();
    // Before anything renders: a "/…" link or image resolves against the workspace root.
    docRoot = data.root || "";
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
      setTitle("markdown preview");
    } else if (target.buf != null) {
      const b = data.list.find(x => x.id === target.buf);
      await renderFrom(BASE + "source?buf=" + target.buf, "b:" + target.buf, b ? b.name : null);
      setTitle((b ? b.label : "buffer " + target.buf) + " — preview");
      // The editor's cursor line belongs to the ACTIVE buffer, so mark it only there.
      applyCursor(target.buf === data.active ? data.cursor : null);
    } else {
      const ok = await renderFrom(BASE + "file?path=" + encodeURIComponent(target.file), "f:" + target.file, target.file);
      if (!ok) showEmpty("cannot read " + target.file);
      setTitle(baseName(target.file) + " — preview");
      applyCursor(null);   // a disk file has no editor cursor in it
    }
    setStatus("live");
  } catch (e) {
    setStatus("editor gone (" + e.message + ")");
  }
}

// One tick at a time, re-armed only once the previous one settles. A render can outlast
// the poll interval (a big document, a slow diagram) and overlapping ticks would race each
// other on the `shown*` state and do every fetch twice — which a fixed-interval timer
// cannot prevent. A hashchange arriving mid-tick asks for one more pass instead of starting a
// second one, so a click in the sidebar still navigates immediately.
let ticking = false, again = false, timer = null;

function schedule(ms) {
  clearTimeout(timer);
  timer = setTimeout(runTick, ms);
}

async function runTick() {
  if (ticking) { again = true; return; }
  ticking = true;
  try {
    await tick();
  } finally {
    ticking = false;
    const immediate = again;
    again = false;
    schedule(immediate ? 0 : POLL_MS);
  }
}

runTick();
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
