# ddpager — Feature Showcase

A guided tour of every feature and flag in `ddpager`, the pure-Bash
`less`-clone built from nothing but BASH builtins, `dd`, and `tput`.

> **Why it exists.** When you land on a rescue disk, a `scratch` container,
> or an air-gapped recovery shell, the only things you can count on are
> POSIX core utilities. `ddpager` gives you a familiar pager in that world.

```
                       +--------------------------+
   bash builtins ----> |                          |
                       |        ddpager           |  ----> familiar
   dd (binary sniff) ->|  (one self-contained sh) |        less-style
                       |                          |        UI
   tput / stty ------> |                          |
                       +--------------------------+
```

---

## Table of contents

1. [Invocation & command-line flags](#1-invocation--command-line-flags)
2. [Loading content](#2-loading-content)
3. [Navigation](#3-navigation)
4. [Search & highlighting](#4-search--highlighting)
5. [Filtering (`&`)](#5-filtering-)
6. [Multi-file ring](#6-multi-file-ring)
7. [Command mode (`:`)](#7-command-mode-)
8. [Line numbers](#8-line-numbers)
9. [Binary file detection](#9-binary-file-detection)
10. [Status line](#10-status-line)
11. [Help screen](#11-help-screen)
12. [Resize handling](#12-resize-handling)
13. [Live & external features (`F`, `v`, `^G`)](#13-live--external-features-f-v-g)
14. [Exit codes](#14-exit-codes)
15. [Cookbook of rich examples](#15-cookbook-of-rich-examples)

---

## 1. Invocation & command-line flags

```
ddpager [OPTIONS] [file ...]
command | ddpager
```

| Flag | Effect | Source |
|------|--------|--------|
| `-N` | Start with the line-number gutter visible | `ddpager.sh:987` |
| `-h` | Print the usage banner and exit `0` | `ddpager.sh:988` |
| `-v` | Print version (`ddpager 0.1.0`) and exit `0` | `ddpager.sh:989` |
| `--` | End-of-options marker (anything after is a filename) | `ddpager.sh:990` |

Examples:

```bash
ddpager -h                  # usage
ddpager -v                  # ddpager 0.1.0
ddpager -N notes.txt        # open with line numbers showing
ddpager -- -weirdfile.txt   # open a file whose name starts with "-"
```

---

## 2. Loading content

`ddpager` accepts three kinds of input:

| Source | How | Notes |
|--------|-----|-------|
| One or more named files | `ddpager a.log b.log` | Builds the file ring (see §6). |
| Stdin pipe | `cmd \| ddpager` | Shown as `(stdin)` in the status line. Slurped with `mapfile` *before* raw mode is entered (`ddpager.sh:1007`). |
| `:e <file>` at runtime | `:e /etc/hosts` | Appends to the ring and switches to it. |

Missing files are reported on stderr but do **not** abort startup as
long as at least one file is valid (`ddpager.sh:1014-1026`).

```bash
# Two real files plus one ghost — ghost is reported, real ones still open.
ddpager /etc/hostname /etc/does-not-exist /etc/os-release
```

---

## 3. Navigation

Every navigation command accepts an optional **numeric prefix** that
overrides its default. You type the digits *before* the command key,
exactly like `vi` or `less`:

```
10j     # 10 lines forward
25G     # jump to line 25
3n      # next 3 search matches
100b    # 100 lines backward (not 100 pages)
```

The running count is echoed on the status line as you type
(`show_pending_count`, `ddpager.sh:449`), and any non-digit key
finalises it and becomes the command to execute. Bare `0` is **not**
treated as a count — leading `0` is ignored — so you can still type
`0j` literally (it's the same as `j`).

| Key | Default | With count `N` |
|-----|---------|----------------|
| `j` / `↓` / `Enter` | +1 line | +N lines |
| `k` / `↑` | −1 line | −N lines |
| `Space` / `f` / `PgDn` | +1 page | **+N lines** (not pages) |
| `b` / `PgUp` | −1 page | **−N lines** |
| `d` | +½ page | +N lines |
| `u` | −½ page | −N lines |
| `y` | −1 line | −N lines |
| `g` / `Home` | line 1 | jump to line N |
| `G` / `End` | last line | jump to line N |
| `n` | next match | next match repeated N times |
| `N` | reverse match | reverse match N times |
| `r` | repaint | (count ignored) |

### What happens when the count is absent

Without a prefix, commands behave exactly as they always did —
`Space` still scrolls a full page, `d` still scrolls half a page, and
`G` still jumps to the last line. The count just opts you into
finer-grained or explicit movement when you want it.

### Visual feedback while counting

```
┌─ after pressing '1' ─┐     ┌─ after pressing '2' ─┐
│ ...                  │ →   │ ...                  │
│ :1                   │     │ :12                  │
└──────────────────────┘     └──────────────────────┘
   status line shows             count grows live
   the pending count
```

The count display vanishes the moment you press a non-digit key, and
the next redraw restores the normal status bar.

### Picture of the page model

```
 +-------------------------+  <- OFFSET   (top of screen)
 | line OFFSET             |
 | line OFFSET+1           |  PAGE_LINES = TERM_LINES - 1
 | ...                     |
 | line OFFSET+PAGE_LINES-1|
 +-------------------------+
 | status line (reverse)   |
 +-------------------------+
```

`OFFSET` is *clamped* on every redraw (`ddpager.sh:303-308`) so you
can never scroll past the EOF tilde rows.

---

## 4. Search & highlighting

| Key | Action |
|-----|--------|
| `/pattern` | Search forward, wrap at EOF |
| `?pattern` | Search backward, wrap at BOF |
| `n` | Repeat search in the same direction |
| `N` | Repeat search in the *opposite* direction |

Both `n` and `N` accept numeric prefixes: `3n` jumps to the *third*
next match, `5N` walks back five matches.

Pattern semantics: **literal substring**, case-sensitive. There is no
regex (a deliberate constraint — no `grep`/`awk` allowed).

When a wrap happens you get a status-line message:

```
search hit TOP, continuing at BOTTOM
search hit BOTTOM, continuing at TOP
Pattern not found: foo
```

Every visible occurrence on every visible line is highlighted in
reverse video by `print_highlighted_line` (`ddpager.sh:273-295`):

```
The quick [brown] fox jumps over the lazy dog
A [brown] bear ate the fox
```
*(brackets here represent the reverse-video block.)*

You can also kick off a search from command mode:

```
:/needle      # forward search "needle"
:?needle      # backward search "needle"
```

---

## 5. Filtering (`&`)

Press `&`, type a pattern, hit Enter — the view collapses to **only**
lines containing that substring. Press `&` followed by Enter (empty
pattern) to clear the filter.

```
&error           # show only lines containing "error"
&                # back to full file
```

Implementation note: filtering does **not** rewrite the buffer. It
builds a `FILTER_IDX` array of buffer indices (`apply_filter`,
`ddpager.sh:216-229`); every navigation/search call goes through
`view_len` / `view_line` accessors so filter-mode is invisible to the
rest of the engine. The status line also reports the hit count:

```
ddpager.sh  line 1/47  (TOP) &error [12 hits]
```

When line numbers are on (`:N`), filtered lines keep their **original**
line numbers so you always know where you are in the real file.

---

## 6. Multi-file ring

Open many files at once and walk the ring:

```bash
ddpager nginx-access.log nginx-error.log app.log
```

| Key/cmd | Action |
|---------|--------|
| `:n` / `:next` | Next file in the ring |
| `:p` / `:prev` | Previous file in the ring |
| `:e <file>` | Append a new file to the ring and jump to it |
| `:d` | Drop the current file from the ring (refuses if it's the last) |
| `:x` | Examine the **first** file in the ring |
| `:x N` | Examine the **N-th** file in the ring (1-based) |
| `:f` or `=` | Show the current file's info |

Per-file scroll position is **remembered** in `FILE_OFFSETS`
(`ddpager.sh:177`), so flipping between files preserves where you
were reading.

```
ddpager.sh (file 2 of 3)  line 320/1138  28%
```

---

## 7. Command mode (`:`)

Press `:` and you get a real text prompt at the status line with
backspace and Escape-to-cancel support. The complete grammar
(`ddpager.sh:751-802`):

| Command | Purpose |
|---------|---------|
| `:q`, `:quit`, `:q!` | Quit |
| `:n`, `:next` | Next file in ring |
| `:p`, `:prev` | Previous file in ring |
| `:e <file>` | Open file, append to ring |
| `:d` | Remove current file from ring |
| `:x` | Examine first file |
| `:x N` | Examine N-th file (1-based) |
| `:f` | File info (also `=` shortcut) |
| `:N` | Toggle line number gutter |
| `:/pat` | Forward search pattern `pat` |
| `:?pat` | Backward search pattern `pat` |
| `:<number>` | Jump to that line number |

Examples:

```
:e /var/log/auth.log     # add auth.log to the ring
:1500                    # jump to line 1500
:/Exception              # forward-search "Exception"
:N                       # show/hide line numbers
:x 2                     # jump to second file in the ring
:f                       # "auth.log: 9421 lines [file 3 of 4]"
```

Line input supports backspace (`^?` / `^H`) and Escape to cancel
without executing.

---

## 8. Line numbers

Two ways to enable the line-number gutter:

1. From the shell at startup: `ddpager -N file.txt`
2. At runtime: press `:` then `N` then Enter.

The gutter auto-sizes to the line count of the buffer
(`ddpager.sh:316-323`) and is rendered dim:

```
   1  #!/usr/bin/env bash
   2  set -uo pipefail
   3
   4  TC_CLEAR=$(tput clear)
   ...
1138  main "$@"
```

When a filter is active, the numbers shown are the **original**
buffer line numbers — not the post-filter row index — courtesy of
`view_real_lineno` (`ddpager.sh:253-264`).

---

## 9. Binary file detection

This is the cleverest trick in the script. `detect_binary`
(`ddpager.sh:113-149`) sniffs the first 512 bytes with `dd` *and*
exploits a Bash quirk: **command substitution silently strips NUL
bytes**.

The technique:

1. Capture `dd`'s stderr (`"512 bytes copied, ..."`) and parse out the
   true byte count by walking words.
2. Re-read the same bytes into a Bash variable, with a sentinel `X`
   appended to defeat trailing-newline stripping.
3. If the variable's `${#sample}` is **shorter** than the byte count,
   NULs were stripped → the file is binary.

No `file(1)`, no `grep -P`, no `xxd`. Pure shell + `dd`.

When triggered, the user gets a flash message:

```
WARNING: binary file detected — display may be garbled
```

The file still loads — `ddpager` won't refuse to show you what's
there, it just warns once.

---

## 10. Status line

The bottom row is a reverse-video status bar. Three layouts swap in
depending on context:

```
  filename  line N/M  POSITION                       <- normal
  filename (file 2 of 5)  line N/M  POSITION         <- multi-file
  filename  line N/M  POSITION  &needle [12 hits]    <- filter active
```

`POSITION` is one of `(TOP)`, `(END)`, `(empty)`, or a percentage
like `42%`. One-shot messages (search results, errors, file info)
preempt the line for a single redraw, then it returns to normal.

---

## 11. Help screen

Press `h` at any time to drop into a full-screen help page listing
every key and command. Any keystroke returns you to the file at
exactly the offset you left.

```
  ddpager 0.1.0 — BASH/dd/tput pager

  NAVIGATION
    j  Down  Enter     Forward one line
    k  Up              Backward one line
    ...
```

---

## 12. Resize handling

`ddpager` installs a `WINCH` trap (`ddpager.sh:1039`) that re-queries
`tput lines` / `tput cols` and triggers a full redraw. Resize your
terminal mid-paging and the layout adapts cleanly with no manual
repaint needed.

If you suspect garbage on the screen for any reason (a stray write
from another process, an SSH glitch), press `r` to force a repaint.

---

## 13. Live & external features (`F`, `v`, `^G`)

Three keys bridge `ddpager` to the outside world: watching a file
grow, handing off to your editor, and asking "where exactly am I?".

### 13.1 `F` — follow mode (tail -f)

Press capital `F` to jump to the end of the current file and enter
**follow mode**. `ddpager` re-reads the file every 500 ms and scrolls
to keep the newest line visible. The status line shows:

```
/var/log/syslog  Waiting for data... (press any key to abort)
```

**Any keystroke** leaves follow mode and returns to normal paging.
After exiting you can scroll back, search, filter — all your history
is still in the buffer.

Implementation notes (`ddpager.sh:963`):

- Uses `read -rsn1 -t 0.5` as both the keystroke poll **and** the
  follow-interval timer, so there's no separate sleep.
- Each tick runs `mapfile -t BUFFER < "$fname"`; if the line count
  changed, it reapplies any active filter and clamps `OFFSET` to the
  new tail.
- Refuses `(stdin)` with `"Cannot follow stdin"` — stdin has already
  been consumed when the pager entered raw mode, so there's nothing
  to re-read.

```bash
ddpager /var/log/syslog
# inside:
F
# watch new lines appear as other processes log.
# press any key → "Follow mode ended"
```

Combine with a filter for a poor-man's `tail -f | grep`:

```bash
ddpager /var/log/nginx/access.log
# inside:
&" 500 "        # filter for 500s
F               # follow the tail; new 500s show up live
```

### 13.2 `v` — edit in `$VISUAL` / `$EDITOR`

Press `v` and `ddpager` suspends its UI, hands the current file to
your editor with the **cursor positioned on the current top line**,
and then seamlessly returns you to the pager on the same line.

Editor resolution (`ddpager.sh:1008`):

1. `$VISUAL` if set
2. otherwise `$EDITOR`
3. otherwise fall back to `vi`

The editor string is word-split so multi-word commands like
`EDITOR="vim -p"` or `VISUAL="emacs -nw"` work correctly. Line
numbers are passed with the universal `+N` convention, so `vi`,
`vim`, `nano`, `emacs`, `kak`, `hx`, `micro`, and friends all jump
to the right place.

```bash
EDITOR=vim ddpager ddpager.sh
# inside:
:500            # scroll to line 500
v               # drops into `vim +500 ddpager.sh`
# ...edit, save, :q...
# back in ddpager at line 500, with fresh content
```

Refuses `(stdin)` (`"Cannot edit stdin"`) and unwritable files
(`"File not writable: <name>"`) before touching the terminal — so
you're never left in a half-restored state.

What happens to the terminal during the handoff:

```
pager active         editor active          pager active again
┌──────────────┐    ┌──────────────┐       ┌──────────────┐
│ alt-screen   │ →  │ normal screen│  →    │ alt-screen   │
│ raw stty     │    │ saved stty   │       │ raw stty     │
│ cursor: off  │    │ cursor: on   │       │ cursor: off  │
└──────────────┘    └──────────────┘       └──────────────┘
                       $EDITOR +N file
```

If the filter is active when you press `v`, `ddpager` resolves the
*real* buffer line number (via `view_real_lineno`) before launching
the editor, so you land on the line you actually see — not the
post-filter row index.

### 13.3 `^G` — extended file info

Press `Ctrl+G` to flash a detailed one-line status report:

```
ddpager.sh  lines 320-343/1279  bytes 33128  28%
```

Fields (`ddpager.sh:1058`):

| Field | Meaning |
|-------|---------|
| `name` | Current filename (or `(stdin)`) |
| `lines A-B/T` | Visible line range `A-B` out of `T` total in the view |
| `bytes N` | Total bytes in the loaded buffer |
| `PCT%` | Through-the-file percentage of the bottom visible line |
| `[file i of n]` | Ring position, only when more than one file is open |

Byte counting is done by summing `${#line} + 1` across the buffer —
no `wc`, no `stat`, no external tool. For stdin that's the exact
bytes that arrived; for files it's the on-disk content ± 1 byte if
the file lacks a trailing newline.

Contrast with the simpler `:f` / `=` shortcut which only reports
`<name>: N lines`. `^G` is the "really, tell me everything" variant.

```bash
ddpager big.log
# inside:
G               # jump to bottom
^G              # "big.log  lines 9800-9822/9822  bytes 1048576  100%"
&ERROR
^G              # "big.log  lines 1-14/14  bytes 1048576  100%"
                # (note: line counts reflect the filtered view;
                #  bytes still reflect the whole buffer)
```

---

## 14. Exit codes

| Code | Meaning |
|------|---------|
| `0` | Normal quit (`q`, `:q`, EOF) |
| `1` | Startup error (bad flag, no readable files) |
| `130` | Interrupted by `Ctrl+C` (standard `128 + SIGINT`) |

---

## 15. Cookbook of rich examples

### a) Read a syslog and pin to errors

```bash
ddpager /var/log/syslog
# inside:
&error            # filter to error lines
G                 # jump to the most recent
?CRIT             # walk backward through CRIT messages
n n n             # repeat
```

### b) Pipe `find` output through the pager

```bash
find /etc -type f 2>/dev/null | ddpager
# inside:
/passwd           # locate passwd-related paths
N                 # walk hits backward
```

### c) Read three rotated logs as a ring with line numbers

```bash
ddpager -N nginx.access.log.1 nginx.access.log.2 nginx.access.log.3
# inside:
:n                # next log
:1000             # jump to line 1000
:f                # confirm where we are
:p                # back to previous log (resumes its old offset)
```

### d) Open more files without leaving the pager

```bash
ddpager app.log
# inside:
:e /var/log/syslog
:e /var/log/auth.log
:x 1              # back to app.log
:d                # drop app.log from the ring
```

### e) Quickly inspect a "what is this file?" suspect

```bash
ddpager /usr/bin/ls
# Status line flashes:
#   WARNING: binary file detected — display may be garbled
# Then you can still scroll, search for ASCII strings, etc.
```

### f) Precise jumps with numeric prefixes

```bash
ddpager bigfile.txt
# inside:
20j               # forward 20 lines
5k                # backward 5 lines
25G               # jump straight to line 25
100G              # jump to line 100
50 Space          # 50 lines forward (not 50 pages!)
3n                # skip to the 3rd-next search match
g                 # back to top
G                 # all the way to bottom
```

### g) Search-and-highlight a stack trace

```bash
crashing-cmd 2>&1 | ddpager
# inside:
/Traceback        # forward to the first traceback
n                 # next traceback
&Exception        # collapse view to exception lines only
&                 # back to the full output
```

### h) Recovery shell sanity check

```bash
# In a busybox/initramfs shell with no less, no more:
ddpager /etc/fstab /etc/hostname /etc/passwd
# Walk the ring with :n / :p, search with /, jump with :<n>.
```

### i) Read a file whose name starts with `-`

```bash
ddpager -- -weird-filename.log
```

### j) One-keystroke file info

```bash
ddpager *.md
# inside:
=                 # "README.md: 191 lines [file 1 of 5]"
:n
=                 # "USAGE.md: 412 lines [file 2 of 5]"
^G                # "USAGE.md  lines 1-23/412  bytes 13288  5% [file 2 of 5]"
```

### k) Live-tail a rotating log

```bash
ddpager /var/log/nginx/access.log
# inside:
F                 # jump to end and follow
                  # new requests stream in live
# press any key → "Follow mode ended"
G                 # still at the bottom, fully interactive again
```

### l) Follow with a filter for live triage

```bash
ddpager /var/log/syslog
# inside:
&kernel           # collapse view to kernel messages
F                 # follow the tail; only kernel lines trigger updates
                  # (the filter is reapplied on every poll)
```

### m) Edit-then-view round-trip

```bash
EDITOR=vim ddpager ddpager.sh
# inside:
/draw_screen      # locate the function
n                 # next hit (the definition)
v                 # opens vim +<line> ddpager.sh
# ...edit and :wq...
# back in the pager, positioned at the same line, with fresh content
```

### n) Edit a file found via the ring

```bash
ddpager *.sh
# inside:
:n :n             # walk to the file you want
v                 # edit that specific file
:f                # confirm name after reloading
```

### o) "Where exactly am I?" in a huge log

```bash
ddpager huge.log
# inside:
G
^G                # "huge.log  lines 9998-10020/10020  bytes 1572864  100%"
:5000
^G                # "huge.log  lines 5000-5022/10020  bytes 1572864  50%"
```

### p) Fall back gracefully when `$EDITOR` is exotic

```bash
# Multi-word editors are word-split correctly:
EDITOR="vim -p" ddpager a.txt b.txt
# inside:
v                 # launches `vim -p +<line> a.txt`

# If no editor is configured at all, vi is the last-resort default.
```

---

## At-a-glance cheat sheet

```
NAV     j k  ↑ ↓  Enter   Space f b   PgDn PgUp
        d u y   g G  Home End   r (repaint)

COUNT   Nj Nk  N(Space) Nf Nb  Nd Nu Ny  Ng NG  Nn NN
        e.g. 10j = 10 down   25G = line 25   3n = 3 matches

SEARCH  /pat   ?pat   n   N

FILTER  &pat   &  (empty clears)

FILES   :n  :p  :e <file>  :d  :x [N]  :f  =

LIVE    F   (follow / tail -f, any key aborts)
EDIT    v   ($VISUAL or $EDITOR, +N cursor)
INFO    ^G  (name, line range, bytes, percent)

MISC    :N (numbers)   :<n> (goto line)   h (help)   q (quit)

FLAGS   -N (start with numbers)   -h   -v   --
```

---

*Generated as a feature showcase for `ddpager.sh` v0.1.0. See
[USAGE.md](USAGE.md), [FEATURES.md](FEATURES.md), and
[DESIGN.md](DESIGN.md) for the long-form documentation.*
