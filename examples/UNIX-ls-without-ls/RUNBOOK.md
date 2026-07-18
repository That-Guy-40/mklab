# RUNBOOK — how `ddls` works, technique by technique

This is the tutorial the original project never had, **written against the
code, not the header** (the header lies — see the
[errata](README.md#documented-errata)). Line references are into
[`bin/ddls`](bin/ddls), the verbatim script. Type along inside the container
(`su - learner`, then work in `~/ls-without-ls/`) or on any GNU/Linux box
with bash ≥ 4.2.

The automated version of the container setup is
[`setup-workshop.sh`](setup-workshop.sh); the by-hand equivalent is: launch
the TOML, `apt-get install bash coreutils ncurses-bin util-linux` (Debian is
mostly there already) or `apk add bash coreutils ncurses util-linux shadow`
(Alpine has *none* of it), `useradd -m -s /bin/bash learner`, copy
`bin/ddls`, `bin/fixed/ddls` and `demo.sh` into `~learner/ls-without-ls/`.

## 0. The problem `ls` actually solves

Strip away the flags and `ls` is a four-stage pipeline: **enumerate** a
directory, **stat** every entry, **sort** the records, **format** them for a
terminal. That is a database report generator — which is why this lab sits
right after the shell-as-a-database pair in the learning path. `ddls`
implements all four stages with three externals: `stat` (the only way to ask
the kernel about an inode without compiling something), `tput` (the only
portable way to ask the terminal its width), and — despite the name — never
`dd`.

## 1. The stat engine: one fork, twelve fields (`stat_file`, ~line 213)

The naive reimplementation calls `stat` once per *field*:

```bash
size=$(stat -c %s "$f"); mtime=$(stat -c %Y "$f"); perms=$(stat -c %A "$f")  # ...×12
```

Twelve forks per file × a 500-entry directory = 6000 processes. `ddls` makes
**one** call with a packed format string:

```bash
readonly STAT_DELIM=$'\x01'
raw=$(stat --printf="%F${STAT_DELIM}%A${STAT_DELIM}%h${STAT_DELIM}..." "$path")
```

Two ideas here:

- **The delimiter is `\x01`** — a byte that cannot appear in usernames,
  sizes, or type strings. Splitting on spaces or tabs would corrupt on the
  first `staff group` or spacey username; `\x01` never collides. (Filenames
  *could* contain `\x01`, but the filename is never inside this string —
  ddls already has it.)
- **The split is pure parameter expansion** — no `cut`, no `IFS` games:

```bash
while [[ "$tmp" == *"$STAT_DELIM"* ]]; do
    parts+=("${tmp%%"$STAT_DELIM"*}")   # everything before the first \x01
    tmp="${tmp#*"$STAT_DELIM"}"         # everything after it
done
```

`%%pat*` and `#*pat` are the workhorses of zero-fork bash. Memorize them.

Try it:

```bash
stat --printf='%F\x01%s\x01%Y\n' /etc/hostname | od -c | head -2
```

**Two footnotes that demo.sh pins as errata:** the comment above this code
says `-L` is used "to NOT follow symlinks" — backwards (GNU stat lstat's *by
default*; `-L` would follow), and correctly no `-L` is ever passed. And
`-n`/symlink handling issues 1–2 *extra* stat calls — the one-fork claim
holds only for the common path.

## 2. Time without `date` (`format_time`, ~line 184)

Bash ≥ 4.2's `printf '%(...)T'` formats epoch seconds in-process:

```bash
printf -v now '%(%s)T' -1            # -1 = "now"
printf '%(%b %e %H:%M)T\n' "$S_MTIME"
```

That single feature deletes the `date` dependency. `ddls` also reproduces
ls's **six-month rule**: recent files show `Jul 18 12:04`, older ones show
`Jan 15  2025`. ddls uses 180 days where GNU ls uses half a Julian year
(182.62 days) — close enough that the demo steers its fixture mtimes well
clear of the boundary. (`%e` is the space-padded day — the reason columns
line up.)

## 3. Structs from parallel arrays (`ENT_*`, ~line 307)

Bash has no records, so `ddls` uses the classic workaround: fifteen arrays
indexed together — `ENT_NAME[7]`, `ENT_SIZE[7]`, `ENT_MTIME[7]` are one
entry. Collection (`add_entry`) also accumulates the **column widths**
(`W_USER`, `W_SIZE`, ...) in the same pass, which is exactly how real ls
gets its `-l` columns aligned: you cannot print the first line until you
have seen the widest entry of every column.

This is also the design's main trap: every helper mutates globals. The
recursive `-R` path has to harvest its subdirectory list *before* recursing
(~line 741), because the recursive call's `clear_entries` destroys the
arrays mid-iteration. Read that comment — it documents a bug that was
evidently found the hard way.

## 4. Sorting without `sort` (`sort_entries`, ~line 381)

`ddls` sorts an **index array** with insertion sort, leaving the fifteen
data arrays untouched:

```bash
while (( j >= 0 )) && compare_entries "$key_idx" "${SORT_IDX[$j]}"; do
    SORT_IDX[$(( j + 1 ))]=${SORT_IDX[$j]}
    (( j-- ))
done
```

- The comparator is **pluggable** (`name` / `size` / `time`), which is how
  `-S`, `-t`, `-U` and `-r` all share one sorter.
- Name comparison is `[[ "$a" < "$b" ]]` — byte order, which matches GNU ls
  under `LC_ALL=C` and *only* under `LC_ALL=C`. That one export in `demo.sh`
  is why Debian (glibc) and Alpine (musl) produce identical bytes.
- It is **O(n²)** and honest about it ("fine for directory-scale data").
  `time bash bin/ddls /usr/bin >/dev/null` if you want to feel the difference
  from real ls.

**The nanosecond divergence** (demo, section 3a): the comparator uses
`stat %Y` — whole seconds — so same-second files tie and fall back to name
order. GNU ls compares full timespecs. The fixed twin adds `%.9Y` and sorts
on one 19-digit integer (it still fits `intmax_t` — check:
`date +%s%N | wc -c`).

## 5. Columns like ls does them (`print_columns`, ~line 541)

The default tty view: find the widest name, add 2, divide the terminal width
(`tput cols`) by that, print **column-major** (down, then across). It's the
same greedy algorithm GNU ls uses, minus ls's refinement of per-column
widths.

Padding must count **visible** characters — the ANSI color codes around a
name have width zero — so the code prints `name_out` (colored) but pads by
`${#ENT_NAME[idx]}` (uncolored). Break that and colored listings go ragged.

This function also hosts the lab's sharpest bug (demo, section 4): the `-i`
fallback to one-per-line lives *inside* the row loop, so it prints
`num_rows` entries instead of `n` — 12 files, 2 shown, **no error**. The
fixed twin hoists it before the loop. Silent truncation is the failure mode
you don't notice; the sibling `paths.py --check` gate in this repo exists
for the same reason.

## 6. Color from mode bits (`color_for_file`, ~line 76)

The `LS_COLORS` defaults, reimplemented from the octal mode:

```bash
printf -v mode_int '%d' "0$oct_mode"      # octal string -> integer
(( mode_int & 04000 ))  # setuid          (( mode_int & 01000 ))  # sticky
(( mode_int & 0002 ))   # other-writable  (( mode_int & 0111 ))   # any exec
```

Directories get four different colors depending on sticky × other-writable —
run `bash bin/ddls --color -l /tmp` and note `/tmp`'s white-on-blue: that's
`01777`, sticky+ow, the "anyone can write here" warning paint. Dangling
symlinks get `CLR_ORPHAN` via a plain `[[ -e ]]` probe.

Two color quirks are pinned in the demo: `--color=never` is dead on a tty
(the auto-color default runs *after* argument parsing and overwrites it —
order of initialization is a real bug class), and extension colors fork a
`$( )` per file (`color_for_extension`), which is most of ddls's slowness
with `--color`.

## 7. `readdir` is a glob (`list_directory`, ~line 678)

No `find`, no `ls` — directory enumeration is a bash glob with two shopts:

```bash
shopt -s nullglob                 # empty dir -> zero words, not a literal '*'
shopt -s dotglob                  # -a/-A: hidden files too
for entry in "${dir%/}"/*; do ...
```

Note the save/restore dance around it — `shopt` is process-global, and a
library function that flips it without restoring corrupts its caller. Also
note `[[ -e "$entry" || -L "$entry" ]]`: a dangling symlink fails `-e` but
must still be listed — that `-L` is why `link-dangling` shows up at all.

## 8. The oracle workflow

The habit this lab wants to leave you with — when you reimplement something,
**diff against the original**, byte for byte, both directions:

```bash
cd ~/ls-without-ls
diff <(bash bin/ddls -la /etc) <(ls -la /etc) && echo IDENTICAL
diff <(bash bin/ddls -t -1 /var/log) <(ls -t -1 /var/log)   # spot the ns ties
bash demo.sh        # the full 32
```

## Exercises

1. **Close an erratum yourself.** Pick #4 (`--color=never`) or #5 (`-i`
   columns) from the [README table](README.md#documented-errata), fix it in
   a copy of `bin/ddls`, and check your fix against `bin/fixed/ddls`
   (`diff -u`). The demo will tell you if you got it byte-right: point
   `FDLS` at your copy.
2. **Feel the fork tax.** `time` ddls vs ls on `/usr/bin` with and without
   `--color`. Then find the `$( )` in the per-entry path (hint: section 6)
   and estimate calls saved by inlining it.
3. **Break the delimiter.** Create a user named with a space (container!
   it's disposable) and confirm the `\x01` split survives where an
   IFS-space split would not.
4. **ls's own corner.** Run both tools on a directory containing a filename
   with a newline (`touch $'bad\nname'`). Which one lies to you less? (GNU
   ls quotes by default since 8.25; ddls prints raw. Neither is "wrong" —
   POSIX is the interesting read here.)
