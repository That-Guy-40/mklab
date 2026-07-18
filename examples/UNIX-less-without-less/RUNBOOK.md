# RUNBOOK — how `ddpager` works, mechanism by mechanism

This is the tutorial written **against the verified code**. The six vendored
documents under [`upstream-source/`](upstream-source/README.md) record the
project's intent; where they and the code disagree, the code (and this lab's
[`demo.sh`](demo.sh) evidence) wins. Line references are into
[`bin/ddpager`](bin/ddpager), the verbatim script. Type along inside the
container (`su - learner`, work in `~/less-without-less/`).

The automated setup is [`setup-workshop.sh`](setup-workshop.sh); by hand:
launch the TOML, `apt-get install bash coreutils ncurses-bin python3`
(Debian) or `apk add bash coreutils ncurses python3 shadow` (Alpine has no
bash, no tput, and a BusyBox dd), `useradd -m -s /bin/bash learner`, copy
`bin/ddpager`, `drive-pager.py` and `demo.sh` into
`~learner/less-without-less/`.

## 0. What a pager actually is

A pager is a tiny state machine wearing a terminal costume: a **buffer**
(the file), an **offset** (which line is at the top of the screen), a
**draw** function that renders `offset..offset+rows-2` plus a status line,
and a **read-dispatch loop** that turns keystrokes into offset changes.
Everything else — search, filters, file rings — is bookkeeping around those
four. `ddpager` is that machine in ~1350 lines of bash, with two externals
doing the irreplaceable parts: `tput` (terminal capabilities) and `dd`
(byte-exact I/O that bash cannot do).

## 1. The terminal contract (`term_init`/`term_cleanup`, ~line 46)

Full-screen programs make three promises: draw on the **alternate screen**
(`tput smcup`) so the user's scrollback survives; put the keyboard in
**raw-ish mode** (`stty -echo -icanon raw min 1 time 0`) so keys arrive
byte-by-byte; and **undo all of it on ANY exit**:

```bash
SAVED_STTY=$(stty -g)          # opaque restore token — the only correct way
trap 'term_cleanup' EXIT       # quit, error, or signal: the terminal comes back
```

`stty -g` emits a machine-readable snapshot; restoring *that* (not `stty
sane`) returns the user's exact settings. The demo proves the contract holds
even on Ctrl-C death: rc=130 **and** `rmcup` appears in the captured bytes —
bash runs the EXIT trap when a builtin is killed by SIGINT. One cosmetic
finding: a clean `q` runs `term_cleanup` twice (`do_quit` calls it, then the
EXIT trap fires) — harmless, visible as a doubled `rmcup`.

Also here: **`tput` output is cached once** into `TC_*` variables
(`cache_termcaps`). Every escape the pager ever prints is a `printf '%s'` of
a cached string — the alternative is a fork per screen cell update. The one
exception, `term_cup()` (cursor addressing), forks `tput cup` per call,
because the row/column are parameters; that is the pager's main draw cost.

## 2. The event loop (`main`, ~line 1180)

```
while true:  draw_screen  ->  read_key  ->  case "$key" in ... esac
```

All state is globals (`OFFSET`, `BUFFER`, `SEARCH_PATTERN`, ...); every
handler mutates them and falls through to the next `draw_screen`. Note what
the loop does with a **numeric prefix** (`10j`, `25G`): digits are collected
*in the loop* before dispatch, with a live `:10` indicator in the status
line — and the first digit must be 1–9 so a bare `0` remains available as a
key. That inner while is the cleanest illustration in the script of "parsing
happens where the input arrives."

## 3. Reading keys: one byte at a time (`read_key`, ~line 401)

```bash
IFS= read -rsn1 c
```

Four flags, all load-bearing: `IFS=` (don't strip), `-r` (don't
backslash-eat), `-s` (don't echo), `-n1` (return after one char). Then the
hard part: **arrow keys are not one byte**. `Up` arrives as `\e[A`, so after
reading `\e` the code *peeks* with a 50 ms timeout:

```bash
IFS= read -rsn1 -t 0.05 seq
```

If nothing follows, the user pressed the actual Esc key; if `[` follows, it
is a CSI sequence and one more read (or two, for `\e[5~`-style PgUp/PgDn)
resolves it. That timeout is the whole difference between "Esc works" and
"Esc swallows the next keystroke" — and its 50 ms is why held-down arrow
keys on a laggy SSH link occasionally decompose into Esc + `[` + `A`.

## 4. The raw-mode illusion — who really owns your termios

Here is the pager's deepest lesson, and it is not in any of its six docs.
`stty raw` clears **ICRNL** (Enter should arrive as a dead `\r`, not `\n`)
and **ISIG** (Ctrl-C should be a plain byte 3). Yet observe (demo, section
4): Enter scrolls, and Ctrl-C kills the pager with exit 130.

The experiment that resolves it — run under the *same* stty line on the
*same* pty, with the reader swapped from bash's `read` to `dd bs=1 count=1`:

| reader | Enter arrives as | Ctrl-C |
|---|---|---|
| bash `read -rsn1` | `\n` (empty `$c` — read's delimiter) | SIGINT, exit 130 |
| `dd bs=1 count=1` | **byte 13** (`\r`, raw) | **byte 3** (plain data) |

Same terminal, same settings — different physics. Because **bash's `read
-n1` saves your termios, installs its own (ICRNL and ISIG back on), reads,
and restores yours**. The script's `stty raw` governs only the moments
*between* reads — which is to say, almost never. The pager's Enter key, its
`ENTER` mapping (`read` returning an empty string *is* the Enter detector,
~line 405), and its documented "130 on Ctrl-C" behavior are all bash's
doing.

Why you should care beyond trivia: port this pager to C or Python, keep the
same `stty raw` line, and Enter becomes a dead key while Ctrl-C stops
working — the "regression" was load-bearing shell behavior. It is also why
this lab's test harness drives a **real pty** and types real bytes: any
harness that pipes or pre-translates (this lab tried `script(1)` first)
tests a different terminal than your users have.

## 5. The dd binary detector (`detect_binary`, ~line 113)

The pager needs to warn on binary files, with no `file(1)` allowed. The
solution abuses a bash wart as a sensor — **command substitution silently
deletes NUL bytes**:

```bash
dd_stderr=$(dd if="$file" of=/dev/null bs=512 count=1 2>&1)   # truth: "512 bytes ..."
sample=$(dd if="$file" bs=512 count=1 2>/dev/null; printf X)  # bash-filtered copy
sample="${sample%X}"
(( ${#sample} < actual_bytes ))    # shorter? NULs existed -> binary
```

Three details worth stealing:

- **The sentinel `X`.** `$( )` also strips *trailing newlines*; appending
  `X` inside the substitution and removing it after preserves them, so the
  only length change left is NUL loss. (Modern bash ≥ 5.1 even prints
  `warning: ignored null byte in input` while it strips — older bash is
  silent, which is exactly why the byte *count* and not a warning is the
  detector.)
- **The truth channel is dd's stderr.** The word before `bytes` in dd's
  report is parsed with a two-variable scan — no grep, no awk. This is also
  the portability seam: GNU dd, BusyBox dd and BSD dd phrase that line
  differently ("bytes ... copied" / "bytes transferred"), and the parser's
  `word == bytes*` + previous-word-numeric test covers the dialects. On
  parse failure it fails *open* (assume text) — the right default for a
  warning.
- **`bs=512 count=1`**: one block is enough to classify almost every real
  file, and keeps the probe O(1) regardless of file size.

`demo.sh` reproduces the trick standalone (a 22-byte file with three NULs
measures 19 through bash) and then end-to-end (`WARNING: binary file
detected` on the status line).

## 6. Drawing without flicker (`draw_screen`, ~line 297)

No full clears per keystroke: the draw walks rows with `term_cup $i 0` +
`tput el` (clear-to-EOL), repaints only the text region, and renders `~`
markers past EOF like vi. The status line is reverse-video and **truncated
to the width with printf precision**: `printf '%.80s' "$status"` — a
built-in "cut" nobody remembers. (That truncation bit this lab's first
probe: open a file via a long absolute path and the `line 1/100` evidence
is truncated clean off the status line. The demo uses short names since.)

The offset is **clamped before every draw** — never below 0, never past
`vlen - PAGE_LINES`. Two visible consequences the demo pins: a file shorter
than the screen always reads `line 1/N` (a successful search *looks* like
nothing happened), and a search hit near EOF lands clamped on the last page
(`/needle` → hit at line 80 → status `line 78/100 (END)`).

Search highlighting (`print_highlighted_line`) is pure parameter expansion
again: split on the pattern with `%%pat*` / `#*pat`, wrap each occurrence in
`tput rev` / `tput sgr0`. Substring, not regex — same trade-off the filter
makes.

## 7. Search and filter through one lens (`view_*`, ~line 216)

The `&pattern` filter doesn't copy the buffer — it builds `FILTER_IDX`, an
array of *matching line numbers*, and every consumer goes through three
accessors: `view_len`, `view_line`, `view_real_lineno`. Navigation, search,
goto, the status line — none of them know whether a filter is active. One
indirection layer, and a whole feature costs nothing everywhere else. This
is the pager's best piece of architecture; steal it.

(`view_real_lineno` exists so `:N` line numbers and the `v` editor handoff
report *file* line numbers, not filtered-view positions.)

## 8. The file ring, follow mode, and the editor escape hatch

- **Ring** (`:n`/`:p`/`:e`/`:d`, ~line 180): filenames and per-file offsets
  in two parallel arrays; switching saves your scroll position and restores
  the other file's. `:e` appends, `:d` removes with a rebuild loop.
- **Follow mode** (`F`, ~line 961): a `tail -f` with **no sleep external** —
  the poll timer is `read -rsn1 -t 0.5`: wait half a second for a keypress;
  if none, re-`mapfile` the file and redraw at the bottom. Any key aborts.
  One builtin, three jobs: input, timeout, and cadence.
- **Editor** (`v`, ~line 1008): leave the alternate screen, *restore the
  user's stty*, exec `$VISUAL`/`$EDITOR` with `+<line>` (computed through
  `view_real_lineno` so filters don't lie to your editor), then re-enter raw
  mode, reload, and return to the same spot. The demo drives this with
  `EDITOR=/bin/true` — handoff and reload, no vim required.

## 9. Driving a TUI honestly (`drive-pager.py`)

The vendored `test_cmds.sh` says it best: *"This is complex - better to
manual test."* The lab's answer, in ~80 lines of python: fork the pager on a
**real pty master** (`pty.fork`), pin the geometry to 24×80
(`TIOCSWINSZ` — deterministic status lines), **type one byte every 40 ms**
(the same slow-send discipline as this repo's GRUB serial drivers, and for
the same reason: paste-speed input tests a buffer, not a keyboard), capture
every output byte, and report the child's true exit status (128+N for
signals, timeout kill **by PID**). Then the checks are just `grep -aF`
against the captured bytes for status-line evidence.

```bash
python3 drive-pager.py --out /tmp/cap.bin -k '1.0:25G' -k '0.8:q' -- \
    bash bin/ddpager /etc/services
grep -a 'line 25/' /tmp/cap.bin
```

## Exercises

1. **Add a keybinding.** `less` supports `p` (jump to percent). Wire `Np`
   into the main dispatch (`OFFSET = (vlen*N)/100`), then *prove it* with a
   one-line `drive-pager.py` call. The muscle being trained: every feature
   claim gets a harness check.
2. **Break the sentinel.** Remove the `printf X` from `detect_binary` and
   find a *text* file that now false-positives as binary. (Hint: what do
   most text files end with, and what does `$( )` strip?)
3. **Regex the filter.** `apply_filter` uses `==` globs. Convert it to
   `=~`. What happens to `&1.5` on a file of prices — and which behavior do
   you actually want as a user?
4. **Find the WINCH wrinkle.** Resize handling is
   `trap 'update_dimensions; draw_screen' WINCH` — but the process spends
   its life blocked in `read -rsn1`. Read bash's manual on when traps run
   relative to a blocking builtin, then explain what a resize does to the
   pending keystroke. (Empirical answer welcome: the driver can send
   `SIGWINCH`.)
