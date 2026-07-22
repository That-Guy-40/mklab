/* edit.c — rung 4 (the foundation): a tiny interactive editor as a client.
 *
 * The ladder's top rung is a MicroEMACS port; this is the spike that de-risks
 * it — the make-or-break question isn't the editor logic, it's whether an
 * *interactive* program (blocking on keystrokes, painting the screen with
 * cursor control) can run as an OpenBIOS client at all. It can: with no OS,
 * the client reads keys through the firmware `read` service (clib getch) and
 * paints via ANSI escapes through `write` (clib cls/gotoxy/put_char).
 *
 * A one-line editor: type text, Backspace edits, Ctrl-X saves & exits. That is
 * the whole interactive core an editor needs (input loop + render + an edit op
 * + a command key); a full MicroEMACS port grows the buffer model and keymap
 * on top of exactly this. Strict C89 to match the K&R clib.
 *
 * Driven headlessly: send keys, then Ctrl-X, and the plain final line
 *   edit: wrote <n> chars: <text>
 * is the greppable success marker (printed after a screen clear, so no escape
 * sequences pollute it).
 */
#include "clib.h"

#define MAXLEN 78

int main(void)
{
	char buf[MAXLEN + 1];
	int len = 0;
	int c;

	cls();
	gotoxy(1, 1);
	putsn("clib-edit -- a tiny line editor running as an OpenBIOS client (no OS).");
	putsn("Type text.  Backspace edits.  Ctrl-X saves & exits.");
	gotoxy(4, 1);
	puts("> ");

	for (;;) {
		c = getch();
		if (c == 0x18) {                       /* Ctrl-X: save & quit */
			break;
		} else if (c == 0x7f || c == 0x08) {   /* Backspace / DEL */
			if (len > 0) {
				len--;
				puts("\b \b");         /* rub out the last glyph */
			}
		} else if (c == '\r' || c == '\n') {
			/* single line: ignore Enter */
		} else if (c >= 0x20 && c < 0x7f && len < MAXLEN) {
			buf[len++] = (char)c;
			put_char(c);                   /* echo the keystroke */
		}
	}
	buf[len] = '\0';

	cls();
	gotoxy(1, 1);
	puts("edit: wrote ");
	put_udec((unsigned int)len);
	puts(" chars: ");
	putsn(buf);
	return 0;
}
