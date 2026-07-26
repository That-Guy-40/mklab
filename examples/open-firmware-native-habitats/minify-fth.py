#!/usr/bin/env python3
"""minify-fth.py — squeeze a Forth vocabulary into ONE line, for `setenv nvramrc`.

Why this exists (the PPC track's whole delivery constraint):

  `setenv` parses its value to the END OF LINE (forth/admin/nvram.fs: `linefeed
  parse`), so an nvramrc script is necessarily a single line. But `\\` is a
  comment-to-end-of-line in Forth — so naively joining a commented vocabulary
  onto one line makes the FIRST comment swallow the ENTIRE rest of the
  vocabulary, silently. You get `ok` and no words.

  And the store is small: OpenBIOS's config partition is DEF_SYSTEM_SIZE =
  0xc10 bytes (packages/nvram.c:31), minus a 0x10 header = 3072 bytes for ALL
  config variables put together, stored CHRP-style as "name=value\\0". So the
  budget for nvramrc is 3072 minus whatever the other ~30 variables cost.

So: strip both comment forms, collapse whitespace, emit one line, and report
the byte count against that budget.

Usage:  minify-fth.py FILE.fth [FILE.fth ...]     (writes the one-liner to stdout)
        minify-fth.py --size FILE.fth             (byte count only, to stderr)

Deliberately NOT a general Forth parser. It knows exactly three things:
  \\ ... to end of line          a comment (also a lone "\\" line)
  ( ... )                        a comment, when "(" is a standalone token
  ." ... "  and  " ... "         strings, whose contents are left ALONE
The third rule is the one that matters: `." OFDIAG-1: not a path"` must survive
byte-for-byte, and a "(" or "\\" inside such a string must not start a comment.
"""
import sys

def minify(src: str) -> str:
    # Tokens, not characters: a preserved string is ONE token and is never
    # re-split, so its interior spacing survives the final join untouched.
    # (First version collapsed whitespace globally at the end and quietly ate
    # the alignment inside `." OFDIAG path:   "`.)
    out = []
    for line in src.splitlines():
        i, n = 0, len(line)
        pending = []

        def flush():
            out.extend("".join(pending).split())
            pending.clear()

        while i < n:
            # a string: ." xxx"  or  " xxx"  — copy through verbatim
            if line.startswith('." ', i) or (line[i] == '"' and (i + 1 < n and line[i+1] == ' ')):
                start = i
                i += 3 if line[i] == '.' else 2
                while i < n and line[i] != '"':
                    i += 1
                i += 1                      # include the closing quote
                flush()
                out.append(line[start:i])
                continue
            # \ comment to end of line (must be a standalone token)
            if line[i] == '\\' and (i == 0 or line[i-1].isspace()) and \
               (i + 1 >= n or line[i+1].isspace()):
                break
            # ( comment ) — standalone token only
            if line[i] == '(' and (i == 0 or line[i-1].isspace()) and \
               (i + 1 < n and line[i+1].isspace()):
                depth = 1
                i += 1
                while i < n and depth:
                    if line[i] == ')':
                        depth -= 1
                    i += 1
                continue
            pending.append(line[i])
            i += 1
        flush()
    # Join with single spaces: Forth is whitespace-delimited, so a newline and a
    # space are the same token separator — EXCEPT inside the strings above,
    # which are single tokens here and so pass through unchanged.
    return " ".join(out)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--size"]
    if not args:
        sys.exit(__doc__)
    text = minify("\n".join(open(f).read() for f in args))
    if "--size" in sys.argv[1:]:
        print(len(text), file=sys.stderr)
    else:
        print(text)
    print(f"minify-fth: {len(text)} bytes "
          f"(nvramrc budget: 3072 shared with ~30 other config variables)",
          file=sys.stderr)
