/* emacs.c — rung 4, the finale: a MicroEMACS-style screen editor as a client.
 *
 * The ladder's top rung. edit.c (POC-5) proved the *interactive foundation* —
 * a program can block on keystrokes and paint the screen using only the
 * firmware, with no OS. This grows a real editor on exactly that foundation:
 * a MULTI-LINE buffer, an emacs keymap, full-screen redraw with a mode line,
 * and a tutorial carried as data. It runs as an IEEE 1275 client on both
 * qemu-system-ppc and the revived OpenBIOS-x86 — no operating system anywhere.
 *
 * HONEST SCOPE — a reimplementation, not a line-for-line port. Open Firmware
 * ships Daniel Lawrence's MicroEMACS (uEmacs) as clients/emacs, but that source
 * is ~15 files deep in OS coupling: termios, open()/read()/write() on real
 * files, signals, a termcap database. Porting *that* verbatim to a freestanding
 * no-OS client is a different (and much larger) project. Instead this is a
 * faithful reimplementation of the MicroEMACS *core* — the parts that make it
 * MicroEMACS rather than any editor:
 *
 *   - a line-oriented buffer model (MicroEMACS's LINE list; here a fixed array
 *     of fixed-stride lines carved out of one clib_claim arena — no OS heap),
 *   - the emacs keymap (C-f/C-b/C-n/C-p motion, C-a/C-e, C-d/Backspace, C-k,
 *     Enter=split, C-x C-s save, C-x C-c exit),
 *   - full-screen redraw with a reverse-video mode line, and
 *   - the tutorial as data (MicroEMACS's built-in help, here preloaded into the
 *     buffer so the editor has content the instant it starts).
 *
 * Deliberately NO Meta/ESC bindings: a serial console makes a leading ESC
 * ambiguous (CLAUDE.md — arrow-key escapes read as "cancel"), so every command
 * is a single Control key or a two-key C-x sequence, which drives deterministically.
 *
 * Driven headlessly: type some keys, then C-x C-c, and on exit the screen is
 * cleared and the buffer is dumped as plain text — a summary line
 *   emacs: <L> lines, <C> chars[, saved]
 * followed by one "| <text>" line per buffer line. That dump is the greppable
 * proof that the multi-line edits landed (no escape sequences pollute it).
 *
 * Strict gnu89 to match the K&R clib: declarations at the top of each block.
 */
#include "clib.h"

/* write() is the raw firmware primitive (of1275_io.c); we use it directly to
 * emit a run of bytes that may contain no NUL (a buffer line is not a C string). */
int write(int fd, char *buf, int len);

#define MAXLINES 200          /* buffer height cap (index array is static) */
#define LINESZ   256          /* per-line byte cap (one arena slot) */
#define PAGE     22           /* visible text rows: screen rows 1..22 */
#define MODEROW  23           /* the reverse-video mode line */
#define MSGROW   24           /* the transient message/echo line */
#define NCOL     80           /* assumed terminal width (no way to query it) */

struct line { char *t; int used; };
static struct line lines[MAXLINES];   /* small: MAXLINES*(ptr+int) — fine in .bss */
static char *arena;                   /* MAXLINES*LINESZ, from clib_claim */
static int nlines;                    /* lines in use, 1..MAXLINES */
static int cl, cc;                    /* cursor: line index, column */
static int top;                       /* first visible line (viewport scroll) */
static int modified;                  /* buffer changed since last save */
static int saved;                     /* C-x C-s was pressed */

/* The built-in tutorial — MicroEMACS's "help as data", preloaded so the buffer
 * is never empty. Also the on-screen keymap cheat-sheet. */
static const char *tutorial[] = {
	"clib-emacs -- a MicroEMACS-style editor running as an OpenBIOS client (no OS).",
	"",
	"  Move    C-f forward  C-b back   C-n next-line  C-p prev-line",
	"  Line    C-a start    C-e end    Enter split    C-k kill-to-eol",
	"  Delete  Backspace    C-d forward-delete",
	"  File    C-x C-s save    C-x C-c exit",
	"",
	"Type below.  Every keystroke is a firmware `read`; every glyph a `write`.",
	"There is no operating system underneath this editor -- only the firmware.",
	"",
	0
};

/* ------------------------------------------------------------------ buffer */

static void setline(int n, const char *s)
{
	int i = 0;
	while (s[i] && i < LINESZ - 1) {
		lines[n].t[i] = s[i];
		i++;
	}
	lines[n].used = i;
}

static void copyline(struct line *dst, struct line *src)
{
	int i;
	for (i = 0; i < src->used; i++)
		dst->t[i] = src->t[i];
	dst->used = src->used;
}

static void ins_char(int ch)
{
	struct line *L = &lines[cl];
	int i;
	if (L->used >= LINESZ - 1)
		return;                       /* line full — drop the key */
	for (i = L->used; i > cc; i--)
		L->t[i] = L->t[i - 1];
	L->t[cc] = (char)ch;
	L->used++;
	cc++;
	modified = 1;
}

/* Enter: split the current line at the cursor; the tail becomes a new line. */
static void open_line(void)
{
	int i, taillen;
	if (nlines >= MAXLINES)
		return;
	/* open a hole at cl+1 by shifting lines cl+1..nlines-1 up one slot */
	for (i = nlines; i >= cl + 2; i--)
		copyline(&lines[i], &lines[i - 1]);
	taillen = lines[cl].used - cc;
	for (i = 0; i < taillen; i++)
		lines[cl + 1].t[i] = lines[cl].t[cc + i];
	lines[cl + 1].used = taillen;
	lines[cl].used = cc;                  /* truncate at the split point */
	nlines++;
	cl++;
	cc = 0;
	modified = 1;
}

static void del_back(void)
{
	struct line *L = &lines[cl];
	int i, prevused, n;
	if (cc > 0) {
		for (i = cc - 1; i < L->used - 1; i++)
			L->t[i] = L->t[i + 1];
		L->used--;
		cc--;
		modified = 1;
	} else if (cl > 0) {
		/* join this line onto the end of the previous one */
		prevused = lines[cl - 1].used;
		n = L->used;
		if (prevused + n > LINESZ - 1)
			return;                   /* would overflow — refuse */
		for (i = 0; i < n; i++)
			lines[cl - 1].t[prevused + i] = L->t[i];
		lines[cl - 1].used = prevused + n;
		for (i = cl; i < nlines - 1; i++)
			copyline(&lines[i], &lines[i + 1]);
		nlines--;
		cl--;
		cc = prevused;
		modified = 1;
	}
}

static void del_fwd(void)
{
	struct line *L = &lines[cl];
	int i, n;
	if (cc < L->used) {
		for (i = cc; i < L->used - 1; i++)
			L->t[i] = L->t[i + 1];
		L->used--;
		modified = 1;
	} else if (cl < nlines - 1) {
		/* pull the next line onto the end of this one */
		n = lines[cl + 1].used;
		if (L->used + n > LINESZ - 1)
			return;
		for (i = 0; i < n; i++)
			L->t[L->used + i] = lines[cl + 1].t[i];
		L->used += n;
		for (i = cl + 1; i < nlines - 1; i++)
			copyline(&lines[i], &lines[i + 1]);
		nlines--;
		modified = 1;
	}
}

static void kill_line(void)
{
	struct line *L = &lines[cl];
	if (cc < L->used) {
		L->used = cc;                 /* kill to end of line */
		modified = 1;
	} else {
		del_fwd();                    /* at eol: kill the line break */
	}
}

/* ------------------------------------------------------------------ motion */

static void mv_fwd(void)
{
	if (cc < lines[cl].used)
		cc++;
	else if (cl < nlines - 1) {
		cl++;
		cc = 0;
	}
}

static void mv_back(void)
{
	if (cc > 0)
		cc--;
	else if (cl > 0) {
		cl--;
		cc = lines[cl].used;
	}
}

static void mv_down(void)
{
	if (cl < nlines - 1) {
		cl++;
		if (cc > lines[cl].used)
			cc = lines[cl].used;
	}
}

static void mv_up(void)
{
	if (cl > 0) {
		cl--;
		if (cc > lines[cl].used)
			cc = lines[cl].used;
	}
}

/* ------------------------------------------------------------------ render */

/* append str/uint into a fixed-width mode-line buffer, never past NCOL */
static int app(char *b, int p, const char *s)
{
	while (*s && p < NCOL)
		b[p++] = *s++;
	return p;
}

static int appd(char *b, int p, unsigned int v)
{
	char t[11];
	int i = (int)sizeof(t);
	t[--i] = '\0';
	if (v == 0)
		t[--i] = '0';
	while (v && i > 0) {
		t[--i] = (char)('0' + (v % 10));
		v /= 10;
	}
	return app(b, p, &t[i]);
}

static void draw_modeline(void)
{
	char b[NCOL];
	int p;
	p = app(b, 0, "-- clib-emacs -- L");
	p = appd(b, p, (unsigned int)(cl + 1));
	p = app(b, p, " C");
	p = appd(b, p, (unsigned int)(cc + 1));
	p = app(b, p, "  ");
	p = appd(b, p, (unsigned int)nlines);
	p = app(b, p, " lines ");
	p = app(b, p, modified ? "* " : (saved ? "(saved) " : "- "));
	while (p < NCOL)
		b[p++] = '-';
	write(1, b, NCOL);
}

static void redraw(void)
{
	int r, li;
	/* keep the cursor line inside the viewport */
	if (cl < top)
		top = cl;
	if (cl >= top + PAGE)
		top = cl - PAGE + 1;

	cls();
	for (r = 0; r < PAGE; r++) {
		li = top + r;
		if (li >= nlines)
			break;
		gotoxy(r + 1, 1);
		if (lines[li].used > 0)
			write(1, lines[li].t, lines[li].used);
	}

	gotoxy(MODEROW, 1);
	puts("\033[7m");                      /* reverse video */
	draw_modeline();
	puts("\033[0m");

	gotoxy(MSGROW, 1);
	puts(saved ? "[saved]  C-x C-c exit   C-x C-s save"
		   : "C-x C-c exit   C-x C-s save   (no OS underneath)");

	gotoxy(cl - top + 1, cc + 1);         /* park the cursor */
}

/* ------------------------------------------------------------------- driver */

static unsigned int totalchars(void)
{
	unsigned int n = 0;
	int i;
	for (i = 0; i < nlines; i++)
		n += (unsigned int)lines[i].used;
	return n;
}

int main(void)
{
	int i, c, c2;

	arena = (char *)clib_claim(MAXLINES * LINESZ);
	if (arena == (char *)0) {
		putsn("emacs: claim failed -- no buffer memory");
		return 1;
	}
	for (i = 0; i < MAXLINES; i++) {
		lines[i].t = arena + i * LINESZ;
		lines[i].used = 0;
	}

	/* preload the tutorial-as-data */
	nlines = 0;
	for (i = 0; tutorial[i] != 0 && nlines < MAXLINES; i++) {
		setline(nlines, tutorial[i]);
		nlines++;
	}
	if (nlines == 0)
		nlines = 1;                   /* always at least one line */
	cl = 0;
	cc = 0;
	top = 0;

	for (;;) {
		redraw();
		c = getch();
		if (c == 0x18) {              /* C-x prefix */
			c2 = getch();
			if (c2 == 0x03)       /* C-x C-c : exit */
				break;
			else if (c2 == 0x13) {/* C-x C-s : save */
				saved = 1;
				modified = 0;
			}
			/* other C-x combos: ignored */
		} else if (c == 0x06) {       /* C-f */
			mv_fwd();
		} else if (c == 0x02) {       /* C-b */
			mv_back();
		} else if (c == 0x0e) {       /* C-n */
			mv_down();
		} else if (c == 0x10) {       /* C-p */
			mv_up();
		} else if (c == 0x01) {       /* C-a */
			cc = 0;
		} else if (c == 0x05) {       /* C-e */
			cc = lines[cl].used;
		} else if (c == 0x04) {       /* C-d */
			del_fwd();
		} else if (c == 0x0b) {       /* C-k */
			kill_line();
		} else if (c == 0x7f || c == 0x08) {  /* Backspace / DEL */
			del_back();
		} else if (c == '\r' || c == '\n') {  /* Enter */
			open_line();
		} else if (c >= 0x20 && c < 0x7f) {   /* printable */
			ins_char(c);
		}
		/* unbound control keys: silently ignored */
	}

	/* headless-friendly exit: clear, then dump the buffer as plain text */
	cls();
	gotoxy(1, 1);
	puts("emacs: ");
	put_udec((unsigned int)nlines);
	puts(" lines, ");
	put_udec(totalchars());
	puts(" chars");
	if (saved)
		puts(", saved");
	putsn("");
	for (i = 0; i < nlines; i++) {
		puts("| ");
		if (lines[i].used > 0)
			write(1, lines[i].t, lines[i].used);
		putsn("");
	}
	return 0;
}
