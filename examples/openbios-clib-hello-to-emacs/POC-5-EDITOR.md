# POC-5 — an interactive editor as a client (ppc)

**Goal:** the ladder's top rung — an editor running as an OpenBIOS client.
**Result: the interactive foundation is PASSED and green.** A tiny screen editor
runs as a client on stock `qemu-system-ppc`: it blocks on keystrokes, echoes
them, edits with Backspace, and saves-and-exits on Ctrl-X — all through the
firmware, with no operating system. A full MicroEMACS port grows on exactly this
core and is the scoped finale (below).

## The thinking

"Port emacs" sounds like an editor problem, but the editor logic is the *easy*
part — it's portable C. The make-or-break question for running *any* editor as a
client is **interactivity with no OS**: can the program block waiting for a
keystroke, and paint the screen with cursor control, using only the firmware?
So POC-5 de-risks that first, with the smallest thing that needs all of it:

- **input loop** — block on a key (`getch`),
- **render** — echo it, move the cursor, clear the screen (ANSI),
- **an edit operation** — Backspace rubs out the last glyph,
- **a command key** — Ctrl-X ends the session.

That is the whole interactive skeleton of an editor. If it works, MicroEMACS is
"add a buffer model and a keymap"; if it doesn't, no amount of editor code
helps.

## The clib grows a console (OFW `clients/lib`'s other half)

```c
int  getch(void)              /* poll the firmware `read` until a key arrives */
void put_char(int c)          /* one byte via `write` */
void cls(void)                /* "\033[2J\033[H" — erase + home */
void gotoxy(int row, int col) /* "\033[r;cH" — position the cursor */
```

The one subtlety: the firmware `read` service is **non-blocking** — it returns 0
bytes when no key is waiting — so `getch` spins until it gets one. An editor's
main loop is just one big `getch`. Everything paints with ANSI escape sequences
straight to `write`; there is no termcap and no terminal driver, because the
console on the other end (the muxed stdio / pty) *is* a real terminal.

## edit.c — the one-line editor

`edit.c` is ~50 lines: `cls`, print a banner, then loop on `getch` — printable
keys append to a buffer and echo; Backspace/DEL shortens it and rubs out the
glyph (`"\b \b"`); Ctrl-X breaks the loop; on exit it clears the screen and
prints a plain summary line. Strict C89, like the rest of the clib.

## The live transcript (driven headlessly)

Driving the editor means *typing* at it. The smoke sends `hellX`, then Backspace,
then `o`, then Ctrl-X — so the buffer should end up `hello` (the erroneous `X`
rubbed out):

```console
$ ./smoke-client.sh ppc edit
  - booting stock qemu-system-ppc + our edit CD, driving boot cd:\EDIT.;1
PASS: OpenBIOS-ppc loaded our C client 'edit' and it ran a tiny interactive editor (typed, backspaced, Ctrl-X saved) over the IEEE 1275 client interface
```

The raw console stream (escape sequences left in, so you can see the painting):

```
[4;1H> hellX o[2J[H[1;1Hedit: wrote 5 chars: hello
```

Read it left to right: `[4;1H> ` positions the prompt; `hellX` is typed; the
`\b \b` after it rubs out the `X`; `o` lands; Ctrl-X ends the loop; `[2J[H`
clears; and the plain marker `edit: wrote 5 chars: hello` confirms the buffer is
`hello` (5 chars). Every keystroke went *in* through the firmware `read` service
and every glyph came *out* through `write` — an interactive program on the bare
machine.

## The finale that grows on this: a full MicroEMACS

What remains for a literal `emacs` rung is a **port of MicroEMACS** (OFW ships
one as a client): a multi-line buffer/gap model, a keymap dispatch, and a
tutorial file carried as data — all on top of this exact `getch`/`cls`/`gotoxy`
shim, with `clib_claim` for its buffers. That is a large, mechanical port (rip
out the OS/file layer, keep the editor core), and it is the honest next step, not
something this POC claims to have done. What POC-5 *does* prove is that nothing
about the client model stands in its way.

## Pitfalls checklist

- **`read` is non-blocking** — 0 bytes means "no key yet," not EOF; `getch`
  must poll.
- **Print the success marker after `cls`** — otherwise the editor's own escape
  sequences interleave with it and the smoke's grep gets noisy.
- **ppc console input needs a real terminal** (muxed stdio) — the pty driver,
  not a `-serial unix:` socket.
- **Slow-send keystrokes** (the pty driver's default 40 ms) — the serial console
  has no flow control and drops fast bursts.
- **ANSI, not termcap** — the pty is a real terminal; escape sequences are the
  whole "terminal driver."
