# mdview — Agent Guide

A single-file Bash script that renders Markdown to GitHub-styled HTML via
`pandoc` and opens it in Chrome. Everything is client-side and offline: no
server, no build step, no npm. Pages are plain `file://` HTML.

**Status: in use.** All features listed below are implemented and working.

## Layout

    mdview/
      mdview                    # the entire program (~1270 lines)
      AGENTS.md
      .pre-commit-config.yaml   # editorconfig-checker, whitespace, shellcheck
      .editorconfig
      .gitignore

`~/bin/mdview` is a symlink to `mdview` in this directory. Edit the file
here; the symlink picks it up with no reinstall step.

## Invariants

- **`shellcheck mdview` must pass with zero findings.** Enforced by
  pre-commit. Existing `# shellcheck disable=...` directives are deliberate
  and documented in place.
- **No new runtime dependencies.** Only `pandoc`, `git`, `curl`, `open`,
  and coreutils/BSD userland. No Python, no Node, no `fswatch`. If a feature
  seems to need one, find another way or ask first.
- **macOS-only is accepted.** The script already relies on
  `~/Library/Caches`, `stat -f %m`, `md5`, and `open -a "Google Chrome"`.
  Don't add portability shims nobody asked for.
- **Keep it one file.** The single-file property is the point — it's
  copyable and greppable. Don't split into a lib/ directory.

## Architecture

Top-to-bottom flow in `mdview`:

1. **Arg parsing** — long and short flags, see `-h`.
2. **Dependency + cache setup** — verifies `pandoc`, populates
   `~/Library/Caches/mdview/` with `github-markdown.css` and
   `mermaid.min.js` (downloaded once, from the latest GitHub release).
3. **Heredoc assets** — `$HEADER_FILE` (all CSS + all client JS),
   `$BEFORE_FILE` / `$AFTER_FILE` (the `<article>` wrapper),
   `$LUA_FILTER` (link/image rewriting), `$MERMAID_HEADER_TEMPLATE`.
4. **`relpath()`** — pure-Bash relative path computation. No `python3`.
5. **`render_md()`** — one `pandoc` invocation per file.
6. **`build_diff_suffix()` / `render_all()`** — diff embedding and the
   parallel worker pool.
7. **Chrome launch, then optional watch loop.**

### Asset strategy

Cached CSS/JS is **symlinked** into the output directory, and pages
reference it relatively (`github-markdown.css`, `mermaid.min.js`). This
keeps absolute cache paths out of the HTML source. Do not switch to
`--embed-resources`; it was removed deliberately (file size, render time).

### Lua filter (`$LUA_FILTER`)

Two jobs, both required:

- Rewrites local `*.md` / `*.markdown` link targets to `*.html` so pages
  cross-link in `--all` mode.
- Rewrites relative `<img src>` and relative non-`.md` link targets to
  **absolute** source-tree paths, so images and referenced assets resolve
  from a temp output dir. Applied unconditionally, not just in `--all`.

The filter derives the source directory from `PANDOC_STATE.input_files[1]`
at load time. `PANDOC_DOCUMENT` is **not** populated during element
traversal — metadata plumbing was tried and does not work. Because of this,
`render_md` must always pass pandoc an **absolute** input path.

### Client-side features (all in `$HEADER_FILE`)

Buttons stack bottom-right, each reusing `id="width-toggle"` for styling and
computing its own `bottom` offset from
`document.querySelectorAll('[id="width-toggle"]').length`. **Order of the
IIFEs therefore matters** — a new button must be registered before the
help-modal IIFE, which discovers hotkeys by scanning `[data-hotkey]`.

| Feature | Hotkey | Gated on |
| --- | --- | --- |
| Wide / narrow toggle | `w` | always |
| Table of contents sidebar | `t` | document has headings |
| Links modal (local vs external, with counts) | `l` | always |
| Git diff modal | `d` | `--diff` and a diff exists |
| Raw markdown modal | `r` | `--raw` |
| Keyboard shortcuts help | `?` | always |

State persisted in `localStorage`: `mdview-wide`, `mdview-toc`.

Every modal and the TOC close on `Esc` via its own `keydown` listener.

## Hard-won gotchas

Read this section before touching the corresponding code.

### A literal `</script>` anywhere inside `$HEADER_FILE` breaks the page

The HTML parser scans `<script>` content as bytes and terminates on the
first `</script>` — **including inside a JS comment or string literal**.
A comment mentioning `</script>` once caused the rest of the JS to render
as visible body text. Write it as `<\/script>` or reword.

The `--raw` source embed has the same hazard from the other direction: the
markdown being embedded is passed through
`sed 's|</\([sS][cC]...\)|<\\/\1|g'` first, and the client JS reverses that
escape when reading.

### BSD `mktemp` only substitutes *trailing* `X`s

`mktemp "$TMP_DIR/foo.XXXXXX.html"` silently returns the **literal** path
`foo.XXXXXX.html` on macOS, because the `X`s aren't trailing. This caused
every parallel render job to share one scratch file — a real race that
could embed the wrong file's markdown into a page under `--raw --all`.

Templates must end in `X`s: `mktemp "$TMP_DIR/foo.XXXXXXXX"`. Pandoc reads
`-H` / `-A` includes verbatim and ignores the extension, so dropping
`.html` is harmless.

### `--diff` intent vs. diff existence must stay separate

`WANT_DIFF` holds the user's `--diff` flag and is **never reassigned**.
Whether a diff currently exists is recomputed per render pass by
`build_diff_suffix()`, which echoes `true`/`false`.

Conflating the two latches the feature off permanently under `--watch`: the
first clean-tree pass sets the flag false, and the guard that would
recompute it is the same flag. Both directions of the transition
(clean → dirty, dirty → committed) are supported and were verified.

### `git commit` doesn't change mtime

So the watch loop can't detect it via file stats. It separately fingerprints
`git diff HEAD -- <entry>` with `md5` and re-renders the entry page when
that fingerprint changes. Without this, the Diff modal goes stale after a
commit.

### Diff fence length is computed, not fixed

A diff can contain its own fenced code blocks. The script scans the diff for
the longest backtick run and opens the wrapping fence one backtick longer.
Hardcoding ` ```diff ` breaks highlighting partway through such diffs.

### Skylighting diff colours are hardcoded

Pandoc only emits Skylighting CSS for classes the *main* document triggers,
so a document with no code blocks got an uncoloured diff modal. The
`#mdview-diff-body .va / .st / .dt / .kw` rules in `$HEADER_FILE` exist to
cover that and must stay.

### Mermaid lives in a monorepo

`releases/latest` for `mermaid-js/mermaid` returns sub-package tags. The
fetch filters for `^mermaid@` and pulls the dist bundle from jsDelivr.

### `--all` root resolution

`BASE_DIR` is `$PWD` (or `--root`), **not** the entry file's directory.
Deriving it from the entry file broke `../..`-style links. The entry file
must live under `BASE_DIR`; the script errors with a hint if not.

## Parallelism

`render_all()` runs `render_md` in background jobs with a fixed pool
(`MDVIEW_JOBS`, default 4) using `wait -n`. Roughly 3–4x on a 36-file tree.

Anything `render_md` writes must be **per-invocation** — see the `mktemp`
gotcha. Per-invocation scratch files are deleted at the end of `render_md`
so long `--watch` sessions don't accumulate them.

Shared read-only files created before the loop (`$HEADER_FILE`,
`$LUA_FILTER`, `$MERMAID_HEADER_TEMPLATE`) are safe.

## Watch mode

`--watch` polls mtimes every `MDVIEW_WATCH_INTERVAL` seconds (default 1)
rather than depending on `fswatch`. Each cycle re-runs `collect_md_files`,
so files added or deleted under `BASE_DIR` mid-session are picked up, and
diffs the previous snapshot with `comm -13` to re-render only what changed.

**There is no browser auto-reload** — reload the tab yourself. This was a
deliberate scope decision: `file://` pages can't `fetch()` in Chrome, so
live reload would need a cache-busted `<script>` token poll, a local HTTP
server (which would break the absolute-path image rewriting), or AppleScript
tab control. If asked to add it, revisit those three options.

`--watch` keeps the `EXIT` trap active, so Ctrl-C removes the temp dir and
any Chrome tabs pointing at it go dead. Without `--watch` the trap is
cleared before launching Chrome so pages outlive the process.

## Testing

There is no test suite. Verify changes by rendering and inspecting output:

```bash
./mdview -o /tmp/t1 some.md              # single file
./mdview -a -o /tmp/t2 some.md           # whole tree, cross-links
./mdview -R -o /tmp/t3 some.md           # sourcepos + embedded source
MDVIEW_JOBS=8 ./mdview -a -R -o /tmp/t4 some.md   # race check
shellcheck mdview
```

For parallel-safety changes, generate N files each containing a unique
marker, render with a high `MDVIEW_JOBS`, and assert every output page
contains only its own marker.

Browser-side behaviour (hotkeys, modals, mermaid, copy buttons) needs a
manual pass in Chrome — it isn't covered by anything automated.
