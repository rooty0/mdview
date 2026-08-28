# mdview

Render Markdown to GitHub-styled HTML and open it in Chrome.

One Bash script, no server, no build step. Pages are plain `file://` HTML,
so they work offline and you can keep them around after the tool exits.

```bash
mdview README.md              # render and open in Chrome
mdview -a README.md           # also render every .md under the tree,
                              # with working links between the pages
mdview -W notes.md            # re-render on every save
mdview -o ./site -a README.md # write to a directory instead of opening Chrome
```

## Install

Dependencies: **pandoc** (required), **shellcheck** and **pre-commit** (only
if you're editing the script). Chrome and git you almost certainly have.

```bash
brew install pandoc
git clone <this-repo> ~/me/scripts/shell/mdview
ln -s ~/me/scripts/shell/mdview/mdview ~/bin/mdview   # anywhere on your PATH
```

On first run it downloads `github-markdown.css` and `mermaid.min.js` into
`~/Library/Caches/mdview/` and reuses them from then on. Delete that
directory to force a refresh to the latest releases.

For development:

```bash
brew install shellcheck pre-commit
cd ~/me/scripts/shell/mdview && pre-commit install
```

macOS only - it relies on `open -a`, `~/Library/Caches`, and BSD `stat`.

## Flags

| Flag | What it does |
| --- | --- |
| `-a`, `--all` | Render every `.md` under the root too, rewriting `*.md` links to `*.html` so you can click between pages |
| `-r`, `--root DIR` | Root for `--all` (default: current directory). The file must live inside it |
| `-d`, `--diff` | Add a Diff button showing the file's uncommitted `git diff` |
| `-R`, `--raw` | Add a Raw button: select text, hit `r`, see the markdown behind it |
| `-W`, `--watch` | Stay running and re-render on change. Reload the tab yourself |
| `-o`, `--output DIR` | Write to `DIR` and don't open Chrome |
| `-h`, `--help` | Usage |

Environment: `MDVIEW_JOBS` (parallel renders, default 4),
`MDVIEW_WATCH_INTERVAL` (poll seconds, default 1).

## In the browser

Buttons sit in the bottom-right corner; every one has a hotkey, and `?`
lists them.

| Key | |
| --- | --- |
| `w` | Toggle wide / narrow reading width |
| `t` | Table of contents sidebar, with scroll-spy |
| `l` | All links on the page, local vs external, with repeat counts |
| `d` | Git diff (with `--diff`) |
| `r` | Markdown source for the current selection (with `--raw`) |
| `?` | Keyboard shortcuts |
| `Esc` | Close whatever is open |

Code blocks get a GitHub-style copy button on hover. ` ```mermaid ` fences
render as diagrams, each with its own download-as-SVG button.

## Notes

`--watch` does **not** reload the browser - hit reload yourself. Chrome
blocks `fetch()` on `file://` pages, so live reload would mean either a
local HTTP server or AppleScript driving the browser; neither felt worth it.

`--raw` roughly doubles HTML size, because pandoc has to annotate every
element with its source position. That's why it's opt-in.

## Development

```bash
./test.sh            # 50 assertions, ~30s
./test.sh -l         # list test names
./test.sh raw diff   # run a subset
shellcheck mdview
```

`AGENTS.md` documents the architecture and, more usefully, the non-obvious
constraints - read it before changing the script.
