# ddpager

A `less`-like terminal pager implemented in pure BASH using only builtins, `dd`, and `tput`. No external text-processing tools (`sed`, `awk`, `grep`, `cat`, `less`, `more`) required.

**Version:** 0.1.0

## Overview

`ddpager` provides a terminal pager with familiar `less`-style controls for viewing files and piped output. It features forward/backward scrolling, pattern search with highlighting, line filtering, multi-file navigation, and binary file detection.

### The "Living Off the Land" Advantage

`ddpager` is designed for minimal environments where only core POSIX tools are available:
- Rescue disks
- Container runtimes (scratch, alpine)
- Recovery shells
- Air-gapped systems

No package manager? No problem. `bash`, `dd`, and `tput` are standard.

---

## Quick Start

```bash
# View a file
ddpager filename.txt

# View multiple files
ddpager file1.txt file2.txt file3.txt

# Pipe output to ddpager
cat filename.txt | ddpager

# Start with line numbers
ddpager -N myfile.txt
```

---

## Documentation

| Document | Purpose |
|----------|--------|
| [USAGE.md](USAGE.md) | User guide with command reference |
| [FEATURES.md](FEATURES.md) | Feature list and implementation details |
| [DESIGN.md](DESIGN.md) | Technical deep dive and architecture |
| [MAINTENANCE.md](MAINTENANCE.md) | Troubleshooting and sysadmin guide |

---

## Features

- **Navigation**: `j`, `k`, `Space`, `b`, `d`, `u`, `g`, `G`
- **Search**: `/pattern`, `?pattern`, `n`, `N` with highlighting
- **Filter**: `&pattern` to show only matching lines
- **Multi-file**: Ring navigation with `:n`, `:p`
- **Commands**: `:` mode with `:e`, `:d`, `:f`, `:N`, `:<n>`
- **Follow mode**: `F` tails a growing file (like `tail -f`), any key aborts
- **External editor**: `v` hands off to `$VISUAL` / `$EDITOR` with `+line`
- **Extended info**: `^G` shows name, line range, bytes, and percent
- **Binary detection**: Automatic warning for non-text files
- **Line numbers**: Toggle with `:N`
- **Help screen**: `h` displays command reference

---

## Constraints

- Uses only BASH builtins, `dd`, and `tput`
- No `sed`, `awk`, `grep`, `cat`, `less`, or `more`
- Optionally uses `socat` for readline integration

---

## Installation

```bash
# Copy to a directory in your PATH
sudo cp ddpager.sh /usr/local/bin/ddpager
sudo chmod +x /usr/local/bin/ddpager

# Verify installation
which ddpager
ddpager -v
```

### System Requirements

| Tool | Purpose |
|------|--------|
| `bash` 4.0+ | Shell interpreter |
| `dd` | Binary detection |
| `tput` | Terminal control |
| `stty` | Terminal settings |

---

## Quick Reference

Most navigation commands accept an optional **numeric prefix**
(vi/less style). Type the digits, then the command key:

```
10j     10 lines forward           25G     jump to line 25
10k     10 lines backward          3n      skip 3 search matches
50 Spc  50 lines forward           100b    100 lines backward
```

| Key | Default | With `N` prefix |
|-----|---------|-----------------|
| `j`, `↓`, `Enter` | Down 1 | Down N |
| `k`, `↑` | Up 1 | Up N |
| `Space`, `f`, `PgDn` | Page forward | N lines forward |
| `b`, `PgUp` | Page backward | N lines backward |
| `d` | Half page down | N lines down |
| `u` | Half page up | N lines up |
| `y` | Up 1 | Up N |
| `g`, `Home` | First line | Jump to line N |
| `G`, `End` | Last line | Jump to line N |
| `n` / `N` | Repeat search | Repeat N times |
| `/`, `?` | Search fwd / back | — |
| `&` | Filter lines | — |
| `:` | Command mode | — |
| `F` | Follow file (`tail -f`); any key aborts | — |
| `v` | Edit current file in `$VISUAL` / `$EDITOR` | — |
| `^G` | Extended file info (name, lines, bytes, %) | — |
| `=` | Short file info | — |
| `r` | Repaint screen | — |
| `h` | Help screen | — |
| `q` | Quit | — |

### Command Mode

| Command | Action |
|---------|--------|
| `:n` | Next file |
| `:p` | Previous file |
| `:e <file>` | Open file |
| `:d` | Remove file |
| `:f` or `=` | File info |
| `:N` | Toggle line numbers |
| `:<n>` | Jump to line |

---

## Examples

```bash
# View log file
ddpager /var/log/syslog

# View multiple files
ddpager access.log error.log

# Pipe through ddpager
ls -la | ddpager
find / -type f -name "*.log" 2>/dev/null | ddpager

# Search with highlight
ddpager file.txt
# Then type /pattern and press Enter

# Filter to show only matching lines
ddpager file.txt
# Then type &pattern and press Enter

# Navigate multiple files
ddpager file1.txt file2.txt file3.txt
# Use :n and :p to switch files

# Live-tail a growing log (tail -f replacement)
ddpager /var/log/syslog
# Then press F; any key aborts follow mode

# Edit the file you're viewing in your editor
EDITOR=vim ddpager ddpager.sh
# Then press v — launches `vim +<line> ddpager.sh`,
# returns you to the same spot after :wq

# Extended file info at the cursor
ddpager big.log
# Then press Ctrl-G → "big.log  lines 1-23/9822  bytes 1048576  0%"
```

---

## Exit Codes

| Code | Meaning |
|------|--------|
| 0 | Success (quit normally) |
| 1 | Error (invalid arguments, missing files) |
| 130 | Interrupted (Ctrl+C) |

---

## Limitations

- **Memory**: Entire file loaded into BASH array
- **Binary files**: Display may be garbled
- **Regex**: No regex support (glob patterns only)
- **Wide characters**: Truncation uses byte count
- **No syntax highlighting**: Only search highlighting

---

## License

This project is provided as-is for educational and practical use.

---

## See Also

- [USAGE.md](USAGE.md) — Detailed user documentation
- [FEATURES.md](FEATURES.md) — Feature breakdown
- [DESIGN.md](DESIGN.md) — Technical architecture
- [MAINTENANCE.md](MAINTENANCE.md) — Troubleshooting guide

---

## Credits

Implementation explores the Unix philosophy of building tools from minimal, reliable components.
