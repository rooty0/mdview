#!/usr/bin/env bash
#
# test.sh - integration tests for mdview.
#
# Renders throwaway markdown into temp dirs and asserts on the resulting HTML.
# Nothing outside $TMP is touched and Chrome is never launched (every render
# uses -o). Run from anywhere:
#
#     ./test.sh            # everything
#     ./test.sh -l         # list test names
#     ./test.sh raw diff   # only tests whose name matches one of these
#
# First run on a cold cache downloads github-markdown.css and mermaid.min.js.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MDVIEW="$SCRIPT_DIR/mdview"

PASS=0
FAIL=0
FAILED_TESTS=()
CURRENT=""

if [[ -t 1 ]]; then
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_GREEN=""; C_RED=""; C_BOLD=""; C_DIM=""; C_OFF=""
fi

ok()  { printf '  %sok%s   %s\n' "$C_GREEN" "$C_OFF" "$1"; PASS=$((PASS + 1)); }
bad() {
    printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "$1"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$CURRENT: $1")
}

# assert_eq <label> <actual> <expected>
assert_eq() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — want '$3', got '$2'"; fi
}

# assert_contains <label> <file> <pattern>
assert_contains() {
    if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 — '$3' not found in $(basename "$2")"; fi
}

# assert_absent <label> <file> <pattern>
assert_absent() {
    if grep -qE -- "$3" "$2" 2>/dev/null; then bad "$1 — '$3' unexpectedly present in $(basename "$2")"; else ok "$1"; fi
}

# count_matches <file> <pattern>  -> prints a number
count_matches() { grep -cE -- "$2" "$1" 2>/dev/null || true; }

# Throwaway git repo that ignores the user's global init.templateDir, which
# would otherwise install unrelated hooks into every fixture repo.
git_init() { git init -q --template= "$1"; }
git_commit() {
    git -C "$1" -c user.email=test@example.com -c user.name=test \
        -c commit.gpgsign=false commit --no-verify -q -m "$2"
}

# Stop a background job and reap it. Returns 0 if it shut down on SIGTERM,
# 1 if it had to be forced. Note SIGINT is unusable here: bash sets it to
# ignored for async jobs when job control is off, and a signal ignored at
# entry cannot be trapped — so the script's INT handler never runs and a
# plain `wait` would block forever. Interactive Ctrl-C is unaffected.
stop_bg() {
    local pid=$1 i
    kill -TERM "$pid" 2>/dev/null
    for ((i = 0; i < 40; i++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null
            return 0
        fi
        sleep 0.25
    done
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 1
}

# macOS mktemp -t ignores TMPDIR and always uses the per-user /var/folders
# dir, so a run's temp dir can't be redirected into the test sandbox. List
# them instead and diff against a baseline to ignore pre-existing ones.
TMP_BASE=${TMPDIR:-/tmp}
list_run_dirs() { find "$TMP_BASE" -maxdepth 1 -name 'mdview.*' -type d 2>/dev/null | sort; }

TMP=$(mktemp -d -t mdview-test)
trap 'rm -rf "$TMP"' EXIT

# --- fixtures ---------------------------------------------------------------

make_fixture() {
    local dir=$1
    mkdir -p "$dir/docs/images" "$dir/nested"

    # A 1x1 PNG so the image reference points at something real.
    printf '\211PNG\r\n\032\n' >"$dir/docs/images/shot.png"
    printf 'key: value\n' >"$dir/config.yaml"

    cat >"$dir/index.md" <<'MD'
# Index

Paragraph with **bold** and *italic* and `code`.

![A screenshot](docs/images/shot.png)

- [Relative md link](nested/page.md)
- [Relative asset link](config.yaml)
- [External link](https://example.com/a)
- [External link again](https://example.com/a)
- [Mail](mailto:someone@example.com)
- [Anchor](#index)
- [Absolute path](/etc/hosts)

```python
print("hello")
```

## Second section

End copy.
**End copy.**
MD

    cat >"$dir/nested/page.md" <<'MD'
# Nested page

Back to [the index](../index.md).

```mermaid
flowchart LR
  A --> B
```
MD

    cat >"$dir/plain.md" <<'MD'
# Plain

No code, no diagrams, no links.
MD
}

# --- tests ------------------------------------------------------------------

test_shellcheck() {
    if command -v shellcheck >/dev/null 2>&1; then
        local out
        out=$(shellcheck "$MDVIEW" 2>&1)
        assert_eq "shellcheck reports nothing" "$out" ""
    else
        printf '  %sskip%s shellcheck not installed\n' "$C_DIM" "$C_OFF"
    fi
}

# Guards the page-truncation bug: a literal </script> anywhere inside the
# header heredoc (even in a JS comment) ends the block early and dumps the
# rest of the JS into the page as visible text.
test_header_script_balance() {
    local body opens closes
    body=$(awk '/^cat >"\$HEADER_FILE" <<'"'"'HTML'"'"'$/{f=1;next} /^HTML$/{f=0} f' "$MDVIEW")
    opens=$(printf '%s\n' "$body" | grep -c '<script>')
    closes=$(printf '%s\n' "$body" | grep -c '</script>')
    assert_eq "header heredoc opens exactly one script block" "$opens" "1"
    assert_eq "header heredoc closes exactly one script block" "$closes" "1"
}

# Guards the BSD mktemp bug: only *trailing* Xs are substituted, so a
# template with a suffix after them yields a fixed filename shared by every
# parallel render job.
test_mktemp_templates() {
    local offenders
    # Pull out each quoted mktemp template and keep the ones whose last
    # character isn't an X.
    offenders=$(grep -o 'mktemp "[^"]*"' "$MDVIEW" \
        | sed 's/^mktemp "//; s/"$//' \
        | grep -v 'X$' || true)
    assert_eq "every mktemp template ends in Xs" "$offenders" ""
}

test_single_file() {
    local src="$TMP/single" out="$TMP/single-out"
    make_fixture "$src"
    "$MDVIEW" -o "$out" "$src/index.md" >/dev/null 2>&1
    assert_eq "index.html written" "$([[ -f "$out/index.html" ]] && echo yes)" "yes"
    assert_eq "only the entry file rendered" "$(find "$out" -name '*.html' | wc -l | tr -d ' ')" "1"
    assert_contains "css symlinked and referenced relatively" "$out/index.html" 'href="github-markdown\.css"'
    assert_eq "css symlink resolves" "$([[ -e "$out/github-markdown.css" ]] && echo yes)" "yes"
}

test_asset_rewriting() {
    local src="$TMP/assets" out="$TMP/assets-out"
    make_fixture "$src"
    "$MDVIEW" -o "$out" "$src/index.md" >/dev/null 2>&1
    local f="$out/index.html"
    assert_contains "relative image src made absolute" "$f" "src=\"$src/docs/images/shot\.png\""
    assert_contains "relative non-md link made absolute" "$f" "href=\"$src/config\.yaml\""
    assert_contains "external link untouched" "$f" 'href="https://example\.com/a"'
    assert_contains "mailto untouched" "$f" 'href="mailto:someone@example\.com"'
    assert_contains "anchor untouched" "$f" 'href="#index"'
    assert_contains "already-absolute path untouched" "$f" 'href="/etc/hosts"'
}

test_all_mode() {
    local src="$TMP/all" out="$TMP/all-out"
    make_fixture "$src"
    (cd "$src" && "$MDVIEW" -a -o "$out" index.md >/dev/null 2>&1)
    assert_eq "all three pages rendered" "$(find "$out" -name '*.html' | wc -l | tr -d ' ')" "3"
    assert_eq "nested page kept its subdir" "$([[ -f "$out/nested/page.html" ]] && echo yes)" "yes"
    assert_contains "md link rewritten to html" "$out/index.html" 'href="nested/page\.html"'
    assert_contains "nested backlink rewritten" "$out/nested/page.html" 'href="\.\./index\.html"'
    assert_contains "nested page finds css one level up" "$out/nested/page.html" 'href="\.\./github-markdown\.css"'
}

test_mermaid() {
    local src="$TMP/mermaid" out="$TMP/mermaid-out"
    make_fixture "$src"
    (cd "$src" && "$MDVIEW" -a -o "$out" index.md >/dev/null 2>&1)
    assert_contains "mermaid js injected where a fence exists" "$out/nested/page.html" 'src="\.\./mermaid\.min\.js"'
    assert_absent "mermaid js not injected where no fence exists" "$out/plain.html" 'mermaid\.min\.js"'
    assert_contains "svg download button wired up" "$out/nested/page.html" 'mdview-svg-dl'
}

# gfm's tex_math_dollars reads two "$" amounts in one paragraph as inline
# math and swallows the markup between them, so prose about money loses its
# bold and code spans and pandoc warns on every render.
test_no_tex_math() {
    local src="$TMP/math" out="$TMP/math-out"
    mkdir -p "$src"
    cat >"$src/money.md" <<'MD'
Cutting the pins saves ~$8.3k/yr. The other **104 HPAs** are on
`prod-group-*` and that is where the remaining ~$23k/yr sits.

```math
\sqrt{x}
```
MD
    local warnings
    # mdview's own progress lines also go to stderr, so look only for pandoc's.
    warnings=$("$MDVIEW" -o "$out" "$src/money.md" 2>&1 >/dev/null | grep 'WARNING' || true)
    local f="$out/money.html"

    assert_eq "pandoc emits no warnings" "$warnings" ""
    # A <pre class="math"> code block is the desired outcome; a <span> is not.
    assert_absent "currency does not become a math span" "$f" '<span class="math'
    assert_contains "bold survives between two dollar amounts" "$f" '<strong>104 HPAs</strong>'
    assert_contains "code span survives between two dollar amounts" "$f" '<code>prod-group-\*</code>'
    # shellcheck disable=SC2016  # \$ is a regex escape, not a shell variable
    assert_contains "both dollar amounts kept verbatim" "$f" '\$8\.3k/yr'
    # shellcheck disable=SC2016  # \$ is a regex escape, not a shell variable
    assert_contains "second dollar amount kept verbatim" "$f" '\$23k/yr'
    assert_contains "math fence degrades to a code block" "$f" '<pre class="math"><code>'
}

test_raw_off() {
    local src="$TMP/rawoff" out="$TMP/rawoff-out"
    make_fixture "$src"
    "$MDVIEW" -o "$out" "$src/index.md" >/dev/null 2>&1
    assert_eq "no sourcepos attributes" "$(count_matches "$out/index.html" 'data-pos=')" "0"
    assert_absent "no embedded source block" "$out/index.html" '<script type="text/markdown"'
}

test_raw_on() {
    local src="$TMP/rawon" out="$TMP/rawon-out"
    make_fixture "$src"
    # A closing script tag in the source must not truncate the embed.
    # shellcheck disable=SC2016  # backticks are literal markdown, not a subshell
    printf '\nInline `</script>` in prose.\n' >>"$src/index.md"
    "$MDVIEW" -R -o "$out" "$src/index.md" >/dev/null 2>&1
    local f="$out/index.html"
    assert_contains "sourcepos attributes present" "$f" 'data-pos='
    assert_contains "source embedded" "$f" '<script type="text/markdown" id="mdview-source">'
    assert_contains "closing script tag escaped in embed" "$f" '<\\/script>'

    # Canary for the page-truncation bug. This fixture has no mermaid fence, so
    # the page should hold exactly two script blocks: the header's and the
    # source embed's. A third close means something leaked a literal </script>
    # and everything after it is now rendering as body text.
    assert_eq "no stray closing script tag in the page" \
        "$(grep -o '</script>' "$f" | wc -l | tr -d ' ')" "2"
}

# The expensive one: with a shared scratch file, parallel jobs cross-
# contaminate and a page ends up embedding another file's markdown.
test_parallel_isolation() {
    local src="$TMP/race" out="$TMP/race-out" n=40 i
    mkdir -p "$src"
    for ((i = 1; i <= n; i++)); do
        # shellcheck disable=SC2016  # backticks are literal markdown fences
        printf '# File %s\n\nMARKER_%s_ONLY here.\n\n```mermaid\nflowchart LR\n  A%s --> B%s\n```\n' \
            "$i" "$i" "$i" "$i" >"$src/f$i.md"
    done
    (cd "$src" && MDVIEW_JOBS=8 "$MDVIEW" -a -R -o "$out" f1.md >/dev/null 2>&1)

    local mismatches=0
    for ((i = 1; i <= n; i++)); do
        local own foreign
        own=$(count_matches "$out/f$i.html" "MARKER_${i}_ONLY")
        foreign=$(grep -oE 'MARKER_[0-9]+_ONLY' "$out/f$i.html" 2>/dev/null \
            | sort -u | grep -vc "^MARKER_${i}_ONLY$" || true)
        [[ "$own" -eq 0 || "$foreign" -ne 0 ]] && mismatches=$((mismatches + 1))
    done
    assert_eq "all $n pages rendered" "$(find "$out" -name '*.html' | wc -l | tr -d ' ')" "$n"
    assert_eq "no cross-contamination between parallel jobs" "$mismatches" "0"
}

test_scratch_cleanup() {
    local src="$TMP/scratch" out="$TMP/scratch-out"
    make_fixture "$src"

    local before after
    before=$(list_run_dirs)
    ( cd "$src" && "$MDVIEW" -a -R -o "$out" index.md >/dev/null 2>&1 )
    after=$(list_run_dirs)
    assert_eq "one-shot run leaves no temp dir behind" \
        "$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | wc -l | tr -d ' ')" "0"

    # Accumulation only shows up over repeated renders, so drive a watch
    # session through several cycles and inspect its live temp dir.
    before=$(list_run_dirs)
    ( cd "$src" && exec env MDVIEW_WATCH_INTERVAL=1 \
        "$MDVIEW" -a -R -W -o "$out" index.md >/dev/null 2>&1 ) &
    local md_pid=$!
    sleep 3

    local live
    live=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$(list_run_dirs)") | head -1)
    if [[ -z "$live" || ! -d "$live" ]]; then
        bad "could not locate the watch session's temp dir"
    else
        local cycle
        for cycle in 1 2 3 4; do
            printf '\nedit %s\n' "$cycle" >>"$src/index.md"
            printf '\nedit %s\n' "$cycle" >>"$src/nested/page.md"
            sleep 2
        done
        # mermaid-header.tpl.html is the shared template written once at
        # startup, not a per-render scratch file, so it's expected to persist.
        assert_eq "no scratch files accumulate across watch cycles" \
            "$(find "$live" -maxdepth 1 \( -name 'mermaid-header.*' -o -name 'raw-suffix.*' \) \
                ! -name '*.tpl.html' 2>/dev/null | wc -l | tr -d ' ')" "0"
    fi

    stop_bg "$md_pid"
    assert_eq "watch session removes its temp dir on exit" \
        "$([[ -n "$live" && -d "$live" ]] && echo present || echo gone)" "gone"
}

test_diff() {
    local src="$TMP/diff" out="$TMP/diff-out"
    make_fixture "$src"
    git_init "$src"
    git -C "$src" add -A
    git_commit "$src" "init"

    # Clean tree: the modal content div must be absent.
    "$MDVIEW" -d -o "$out" "$src/index.md" >/dev/null 2>&1
    assert_eq "clean tree embeds no diff" \
        "$(count_matches "$out/index.html" '<div id="mdview-diff-modal-content"')" "0"

    # Dirty tree: the div appears.
    printf '\nAn uncommitted line.\n' >>"$src/index.md"
    "$MDVIEW" -d -o "$out" "$src/index.md" >/dev/null 2>&1
    assert_eq "dirty tree embeds a diff" \
        "$(count_matches "$out/index.html" '<div id="mdview-diff-modal-content"')" "1"
    assert_contains "diff content is syntax highlighted" "$out/index.html" 'class="(va|st|dt|kw)"'

    # A diff containing its own fences must not break out of the wrapper.
    # shellcheck disable=SC2016  # backticks are literal markdown fences
    printf '\n```mermaid\nflowchart LR\n  X --> Y\n```\n' >>"$src/index.md"
    "$MDVIEW" -d -o "$out" "$src/index.md" >/dev/null 2>&1
    assert_eq "diff with nested fences still embeds one block" \
        "$(count_matches "$out/index.html" '<div id="mdview-diff-modal-content"')" "1"

    # Committing removes it again.
    git -C "$src" add -A
    git_commit "$src" "second"
    "$MDVIEW" -d -o "$out" "$src/index.md" >/dev/null 2>&1
    assert_eq "committed tree embeds no diff" \
        "$(count_matches "$out/index.html" '<div id="mdview-diff-modal-content"')" "0"
}

test_diff_outside_git() {
    local src="$TMP/nogit" out="$TMP/nogit-out"
    make_fixture "$src"
    local err
    err=$("$MDVIEW" -d -o "$out" "$src/index.md" 2>&1 >/dev/null)
    assert_eq "renders despite --diff outside a repo" \
        "$([[ -f "$out/index.html" ]] && echo yes)" "yes"
    case "$err" in
        *"not inside a git repository"*) ok "warns that --diff was ignored" ;;
        *) bad "warns that --diff was ignored — got: $err" ;;
    esac
}

test_watch() {
    local src="$TMP/watch" out="$TMP/watch-out"
    make_fixture "$src"

    # exec replaces the subshell with mdview itself, so $! is the pid we need
    # to signal later rather than a wrapper that would leave it orphaned.
    ( cd "$src" && exec env MDVIEW_WATCH_INTERVAL=1 \
        "$MDVIEW" -a -W -o "$out" index.md >/dev/null 2>&1 ) &
    local md_pid=$!
    sleep 3


    local before after
    before=$(md5 -q "$out/index.html" 2>/dev/null)
    printf '\n## Added while watching\n' >>"$src/index.md"
    sleep 3
    after=$(md5 -q "$out/index.html" 2>/dev/null)
    if [[ -n "$before" && "$before" != "$after" ]]; then
        ok "edit triggers a re-render"
    else
        bad "edit triggers a re-render — hash unchanged"
    fi
    assert_contains "edited content reached the output" "$out/index.html" 'Added while watching'

    printf '# Created later\n\nBRAND_NEW_FILE\n' >"$src/late.md"
    sleep 3
    assert_eq "file created mid-session gets rendered" \
        "$([[ -f "$out/late.html" ]] && echo yes)" "yes"

    # An untouched page must not be rewritten.
    local plain_before plain_after
    plain_before=$(md5 -q "$out/plain.html" 2>/dev/null)
    printf '\nanother edit\n' >>"$src/index.md"
    sleep 3
    plain_after=$(md5 -q "$out/plain.html" 2>/dev/null)
    assert_eq "unchanged pages are not re-rendered" "$plain_before" "$plain_after"

    if stop_bg "$md_pid"; then
        ok "watcher shuts down when signalled"
    else
        bad "watcher shuts down when signalled — had to force-kill"
    fi
}

# macOS reaps files under /var/folders that haven't been touched for ~3
# days, so a --watch session left running over a weekend loses header.html,
# before.html and friends while still running. Every render after that
# failed, and the loop still logged "re-rendered".
test_survives_reaped_assets() {
    local src="$TMP/reap" out="$TMP/reap-out"
    make_fixture "$src"

    local before
    before=$(list_run_dirs)
    ( cd "$src" && exec env MDVIEW_WATCH_INTERVAL=1 \
        "$MDVIEW" -a -W -o "$out" index.md >/dev/null 2>"$TMP/reap.err" ) &
    local md_pid=$!
    sleep 3

    local live
    live=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$(list_run_dirs)") | head -1)
    if [[ -z "$live" || ! -d "$live" ]]; then
        bad "could not locate the watch session's temp dir"
        stop_bg "$md_pid"
        return
    fi

    # Simulate the reaper: delete the write-once assets out from under it.
    rm -f "$live/header.html" "$live/before.html" "$live/after.html" \
          "$live/mdlinks.lua" "$live/mermaid-header.tpl.html"
    assert_eq "assets really were removed" \
        "$([[ -f "$live/before.html" ]] && echo present || echo gone)" "gone"

    printf '\n## After the reaper\n' >>"$src/index.md"
    sleep 3

    assert_contains "render recovers after assets are reaped" \
        "$out/index.html" 'After the reaper'
    assert_eq "shared assets were rewritten" \
        "$([[ -f "$live/before.html" && -f "$live/header.html" ]] && echo yes)" "yes"
    assert_absent "no pandoc crash reported" "$TMP/reap.err" 'Uncaught exception'
    assert_absent "no failure logged" "$TMP/reap.err" 'FAILED'

    stop_bg "$md_pid"
}

# The reaper takes rendered pages too, not just the scratch assets. A page
# that vanished has to come back without waiting for the source to be edited,
# which for a session left running for days may never happen.
test_rebuilds_vanished_output() {
    local src="$TMP/vanish" out="$TMP/vanish-out"
    make_fixture "$src"

    ( cd "$src" && exec env MDVIEW_WATCH_INTERVAL=1 \
        "$MDVIEW" -W -o "$out" index.md >/dev/null 2>"$TMP/vanish.err" ) &
    local md_pid=$!
    sleep 3
    assert_eq "initial render landed" \
        "$([[ -f "$out/index.html" ]] && echo yes)" "yes"

    rm -f "$out/index.html"
    sleep 4
    assert_eq "vanished page is rebuilt without an edit" \
        "$([[ -f "$out/index.html" ]] && echo yes)" "yes"

    # Recording the snapshot before rendering used to make the next cycle read
    # our own output as a change, costing a second pass every time.
    sleep 2
    assert_eq "rebuilt exactly once, no flip-flop" \
        "$(grep -c 're-rendered' "$TMP/vanish.err" | tr -d ' ')" "1"

    # The output field is corrected in place, so mtime tracking must still work.
    printf '\n## Later edit\n' >>"$src/index.md"
    sleep 3
    assert_contains "ordinary edits still tracked" "$out/index.html" 'Later edit'

    stop_bg "$md_pid"
}

# A render that fails must not be reported as a success.
test_reports_render_failure() {
    local src="$TMP/fail" out="$TMP/fail-out"
    make_fixture "$src"

    # A directory where the output file must go makes pandoc's write fail.
    mkdir -p "$out"
    mkdir -p "$out/index.html"

    local err rc
    err=$("$MDVIEW" -o "$out" "$src/index.md" 2>&1 >/dev/null)
    rc=$?
    assert_eq "failed render exits non-zero" "$rc" "1"
    case "$err" in
        *"pandoc failed on"*) ok "failure is reported on stderr" ;;
        *) bad "failure is reported on stderr — got: ${err:0:120}" ;;
    esac
    case "$err" in
        *"index.md"*) ok "the failing file is named" ;;
        *) bad "the failing file is named" ;;
    esac
}

test_cli() {
    local out
    out=$("$MDVIEW" -h 2>&1)
    case "$out" in
        *"Usage:"*"--watch"*) ok "help lists every flag" ;;
        *) bad "help lists every flag" ;;
    esac

    out=$("$MDVIEW" 2>&1); assert_eq "no args exits 2" "$?" "2"
    out=$("$MDVIEW" --nope x.md 2>&1); assert_eq "unknown flag exits 2" "$?" "2"
    out=$("$MDVIEW" /nonexistent-xyz.md 2>&1); assert_eq "missing file exits 1" "$?" "1"

    # --all requires the entry file to live under the root.
    local src="$TMP/root" out2="$TMP/root-out"
    make_fixture "$src"
    mkdir -p "$TMP/root-elsewhere"
    ( cd "$TMP/root-elsewhere" && "$MDVIEW" -a -o "$out2" "$src/index.md" >/dev/null 2>&1 )
    assert_eq "--all rejects an entry file outside the root" "$?" "1"
}

# --- runner -----------------------------------------------------------------

ALL_TESTS=(
    shellcheck
    header_script_balance
    mktemp_templates
    cli
    single_file
    asset_rewriting
    all_mode
    mermaid
    no_tex_math
    raw_off
    raw_on
    parallel_isolation
    scratch_cleanup
    diff
    diff_outside_git
    watch
    rebuilds_vanished_output
    survives_reaped_assets
    reports_render_failure
)

if [[ "${1:-}" == "-l" || "${1:-}" == "--list" ]]; then
    printf '%s\n' "${ALL_TESTS[@]}"
    exit 0
fi

[[ -x "$MDVIEW" ]] || { echo "Error: $MDVIEW not found or not executable" >&2; exit 1; }
command -v pandoc >/dev/null 2>&1 || { echo "Error: pandoc is required to run the tests" >&2; exit 1; }

SELECTED=()
if (( $# )); then
    for name in "${ALL_TESTS[@]}"; do
        for pat in "$@"; do
            [[ "$name" == *"$pat"* ]] && { SELECTED+=("$name"); break; }
        done
    done
    (( ${#SELECTED[@]} )) || { echo "No tests match: $*" >&2; exit 1; }
else
    SELECTED=("${ALL_TESTS[@]}")
fi

START=$SECONDS
for name in "${SELECTED[@]}"; do
    CURRENT=$name
    printf '%s%s%s\n' "$C_BOLD" "$name" "$C_OFF"
    "test_$name"
done

printf '\n%s%d passed, %d failed%s in %ds\n' \
    "$C_BOLD" "$PASS" "$FAIL" "$C_OFF" "$((SECONDS - START))"
if (( FAIL )); then
    printf '\nFailures:\n'
    printf '  %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
