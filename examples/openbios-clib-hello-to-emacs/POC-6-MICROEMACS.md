# POC-6 — a MicroEMACS-style editor as a client (the finale, both arches)

**Goal:** the literal top of the ladder — an `emacs` rung: a real *multi-line*
screen editor running as an OpenBIOS client, no OS underneath.
**Result: DONE and green on BOTH arches.** `emacs.c` runs as an IEEE 1275 client
on stock `qemu-system-ppc` *and* on the revived OpenBIOS-x86, driven headlessly:
it preloads a tutorial, takes emacs keystrokes, **splits a line with Enter**
(the multi-line operation `edit.c` could not do), and dumps a verifiable buffer
on `C-x C-c`. Two new green verdicts — `smoke-client.sh {ppc,x86} emacs` — for
**eight total** across the ladder.

## The thinking — what "port MicroEMACS" honestly means here

POC-5 already proved the hard part: an *interactive* program (block on a key,
paint with cursor control) can run as a client with only the firmware. So the
finale is not a research question, it's a **scope** question: how much of
MicroEMACS do we actually port, and how honestly do we label it?

Open Firmware ships Daniel Lawrence's **MicroEMACS** (uEmacs) as `clients/emacs`.
But that source is ~15 files of *OS* editor: `termios` raw-mode toggling,
`open()`/`read()`/`write()` on real files, signal handlers, a termcap database,
a spawn-a-subshell command. A freestanding client has **none** of those — no
files, no signals, no termcap, no shell. Porting that tree verbatim isn't
"a mechanical port," it's rewriting its entire bottom half. So the honest move
is the one this repo keeps making (cf. the POC-4 retraction): **reimplement the
MicroEMACS *core* faithfully, and say plainly that's what it is** — not paste a
source file and pretend the OS layer came along for free.

The *core* is what makes MicroEMACS MicroEMACS rather than any editor:

1. a **line-oriented buffer** (MicroEMACS's `LINE` list),
2. the **emacs keymap** (`C-f/C-b/C-n/C-p`, `C-a/C-e`, `C-d`/Backspace, `C-k`,
   Enter=split, `C-x C-s`, `C-x C-c`),
3. **full-screen redraw** with a reverse-video **mode line**, and
4. the **tutorial as data** — MicroEMACS's built-in help, preloaded so the buffer
   is never empty.

`emacs.c` is those four, ~430 lines of strict gnu89 on the existing `clib` — and
nothing else changed. The console half (`getch`/`put_char`/`cls`/`gotoxy`) and
the `claim`-backed allocator were already there from rungs 3–4; the finale
*consumes* them, it doesn't grow them. That's the payoff of building the ladder:
the last rung is pure editor code.

## The buffer model — a line array carved from one `claim`

MicroEMACS threads its lines on a doubly-linked list. We use the simplest model
that is still faithfully *line-oriented*: a fixed array of fixed-stride lines,
all carved from **one `clib_claim` arena** (no OS heap — `claim` *is* the
allocator, exactly as in memtest):

```c
struct line { char *t; int used; };
static struct line lines[MAXLINES];          /* small: in .bss */
arena = clib_claim(MAXLINES * LINESZ);       /* 200 * 256 = 50 KiB, one call */
for (i = 0; i < MAXLINES; i++) lines[i].t = arena + i*LINESZ;
```

The buffer index array is a few KB of static — fine even at the x86 client's
cramped `-Ttext 0x20000` link address — while the **text** lives in `claim`ed
memory, per the standing rule (a big buffer belongs in `claim`, not `.bss`).
Line insert/delete moves whole lines by copying their bytes between fixed slots;
O(nlines·LINESZ) per Enter, which for a 200-line lab buffer is a sub-millisecond
`memmove` and dead simple to get right. Enter's `open_line()` shifts the tail
lines up one slot, copies the cursor line's tail into the freed slot, and
truncates the original at the split column — a textbook line-split.

## No Meta keys — a serial-console design constraint, not laziness

Every command is a single Control byte or a two-key `C-x` sequence.
**Deliberately no `M-` / ESC bindings:** over a serial console a leading ESC is
ambiguous (CLAUDE.md — arrow-key escapes read as "cancel/exit" in GRUB's editor;
the same hazard here), and it makes headless driving nondeterministic. Control
keys can't be dropped or misread that way, so the whole keymap drives cleanly
byte-for-byte. This is the same lesson the serial-console doctrine keeps
teaching, applied to an editor's key bindings.

## Headless proof — the buffer dump

An interactive full-screen program is noisy: every keystroke repaints 24 rows of
ANSI. So on `C-x C-c` the editor clears the screen and dumps the buffer as
**plain text** — a summary line plus one `| <text>` line per buffer line — with
no escape sequences to pollute the grep:

```
emacs: 11 lines, 437 chars
| MEOW
| PURRclib-emacs -- a MicroEMACS-style editor running as an OpenBIOS client (no OS).
| 
|   Move    C-f forward  C-b back   C-n next-line  C-p prev-line
...
```

The smoke *types* `MEOW`, then **Enter**, then `PURR`, then `C-x C-c`. Cursor
starts at (line 0, col 0); `MEOW` inserts at the head of the tutorial's first
line; **Enter splits it** so `MEOW` is alone on line 0 and the tutorial text
moves to line 1; `PURR` then types at the head of that new second line. The
verdict asserts two things the *single*-line `edit.c` could never produce:

- `^| MEOW$` — a line whose entire content is `MEOW` (the split really happened),
- `| PURR…` — text on the split-off second line (editing a *different* line).

If Enter had merely inserted a character (no split), `MEOW` and `PURR` would
share one line and the `^| MEOW$` anchor would fail — which is exactly the
`REGRESSION:` the smoke prints. Multi-line editing is the invariant under test.

## The live transcript (driven headlessly)

```console
$ ./smoke-client.sh ppc emacs
  - booting stock qemu-system-ppc + our emacs CD, driving boot cd:\EMACS.;1 → …/smoke-client-ppc-emacs.log
PASS: OpenBIOS-ppc loaded our C client 'emacs' and it ran a MicroEMACS-style multi-line editor (typed, split a line with Enter, C-x C-c saved-and-exited) over the IEEE 1275 client interface

$ ./smoke-client.sh x86 emacs
  - booting revived OpenBIOS-x86 + our emacs CD, driving $load + go → …/smoke-client-x86-emacs.log
PASS: revived OpenBIOS-x86 loaded our C client 'emacs' and it ran a MicroEMACS-style multi-line editor (typed, split a line with Enter, C-x C-c saved-and-exited) over the IEEE 1275 client interface
```

Watch the mode line track the cursor across the split, from the raw log
(reverse-video codes shown): after `MEOW` the bar reads
`-- clib-emacs -- L1 C5  10 lines *` (still one line, column 5); after Enter it
jumps to `L2 C1  11 lines *` — the line count went 10→11 and the cursor dropped
to the start of the new second line. Identical byte-for-byte on ppc and on the
revived x86, so the split lands the same under x86's rebased GDT segments as it
does on ppc.

## Why this closes the ladder

`hello` proved the firmware runs your C. `memtest` proved it hands you RAM.
`edit` proved it gives you an interactive terminal. `emacs` proves all three at
once compose into a *program you'd actually recognize* — a screen editor with a
buffer, a keymap, and a mode line — on a machine with **no operating system**,
on two architectures, one of which we had to bring back from the dead (POC-4).
The "syscall" was the firmware callback the whole way up.

## Pitfalls checklist

- **Full redraw is simplest and correct.** Repaint all 24 rows every keystroke;
  the input is slow-sent, the console is a real terminal, so there is no flicker
  problem worth an incremental-update engine in a lab.
- **`\r\r\n` line endings.** The console turns the client's `\n` into `\r\n`, and
  the buffer dump's own `\r` rides along — a `^| MEOW$` grep must tolerate a
  trailing CR (`^\| MEOW[[:space:]]*$`), or it fails on output that is actually
  correct. (Cost one red smoke on the first run.)
- **Text in `claim`, index in `.bss`.** The x86 client links at `0x20000` in a
  self-sizing window; a 50 KB static text array is asking for trouble, a 50 KB
  `claim`ed arena is not.
- **`echo-gate` still self-clocks through the repaint.** Each typed byte appears
  inside the redraw it triggers (the editor read it, then painted it), so the
  gate confirms *after* the firmware consumed it — and the console buffers input
  between `getch` calls, so nothing drops even while a repaint is still
  streaming.
- **No Meta/ESC bindings** — a leading ESC is ambiguous over serial; Control-only
  keeps the keymap deterministic.
- **Scope honesty** — this is a faithful reimplementation of the MicroEMACS core,
  **not** a line-for-line port of Lawrence's OS-coupled uEmacs source. Said in
  the code header, said here.
