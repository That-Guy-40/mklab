# ddpager

A `less`-like pager implemented using pure BASH builtins, `dd`, and `tput`. No external text-processing tools (`sed`, `awk`, `grep`, `cat`) or pagers (`less`, `more`) required.

**Version:** 0.1.0

## Overview

`ddpager` provides a terminal pager with familiar `less`-style controls for viewing files and piped output. It features forward/backward scrolling, pattern search with highlighting, line filtering, multi-file navigation, and binary file detection.

### Constraints

- Uses only BASH 4+ builtins, `dd`, and `tput`
- No `sed`, `awk`, `grep`, `cat`, `less`, or `more`
- Optionally uses `socat` for readline integration

---

## Quick Start

### Basic Usage

```bash
# View a file
ddpager filename.txt

# View multiple files
ddpager file1.txt file2.txt file3.txt

# Pipe output to ddpager
cat filename.txt | ddpager

# Another pipe example
ls -la | ddpager
```

### First Steps

```bash
# Start with line numbers visible
ddpager -N myfile.txt

# View help while inside ddpager
h

# Quit ddpager
q
```

---

## Command Line Options

| Option | Description |
|--------|-------------|
| `-N` | Start with line numbers enabled |
| `-h` | Show help message and exit |
| `-v` | Show version number and exit |

### Examples

```bash
# Show version
ddpager -v
# Output: ddpager 0.1.0

# Start with line numbers
ddpager -N largefile.log

# Show help
ddpager -h
```

---

## Navigation Commands

### Single-Line Movement

| Key | Aliases | Action |
|-----|---------|--------|
| `j` | `DOWN`, `ENTER` | Move down one line |
| `k` | `UP` | Move up one line |

### Page Movement

| Key | Aliases | Action |
|-----|---------|--------|
| `Space` | `f`, `PgDn` | Move forward one full page |
| `b` | `PgUp` | Move backward one full page |

### Half-Page Movement

| Key | Action |
|-----|--------|
| `d` | Move forward half a page |
| `u` | Move backward half a page |

### Jump to Position

| Key | Aliases | Action |
|-----|---------|--------|
| `g` | `HOME` | Jump to first line (TOP) |
| `G` | `END` | Jump to last line (END) |

### Examples

```bash
# In ddpager:
j          # Move down 1 line
jjj        # Move down 3 lines
SPACE      # Page forward
b          # Page backward
d          # Half page down
u          # Half page up
g          # Go to beginning
G          # Go to end
```

---

## Search Functionality

### Search Commands

| Key | Action |
|-----|--------|
| `/pattern` | Search forward for pattern |
| `?pattern` | Search backward for pattern |
| `n` | Repeat last search in same direction |
| `N` | Repeat last search in reverse direction |

### How Search Works

1. Type `/` or `?` followed by your search pattern
2. Press `ENTER` to execute the search
3. Matches are **highlighted** with reverse video
4. If the pattern isn't found on screen, search wraps around:
   - Forward search: "search hit TOP, continuing at BOTTOM"
   - Backward search: "search hit BOTTOM, continuing at TOP"
5. Press `n` to find the next match
6. Press `N` to find the previous match (reversed direction)
7. Press `ESC` to cancel without searching

### Search Input Rules

- **Empty input + ENTER**: Reuses the previous search pattern
- **Backspace**: Delete last character
- **ESC**: Cancel search

### Examples

```bash
# In ddpager:
/error              # Search forward for "error"
?WARNING            # Search backward for "WARNING"
n                   # Find next match (same direction)
N                   # Find previous match (reversed direction)
/                   # Repeat forward search with previous pattern
```

### Search from Command Mode

You can also initiate searches using command mode:

```bash
# In ddpager:
:/pattern           # Search forward (same as /)
/?pattern           # Search backward (same as ?)
```

---

## Filter Functionality

### Filter Command

| Key | Action |
|-----|--------|
| `&` | Filter to show only lines matching a pattern |
| `&` (empty) | Clear filter and show all lines |

### How Filtering Works

1. Press `&` and type a pattern
2. Press `ENTER` to apply the filter
3. Only lines **containing** the pattern are displayed
4. The status line shows: `&pattern [X hits]`
5. All navigation (`j`, `k`, `d`, `u`, etc.) works within filtered lines
6. Press `&` with no pattern to clear the filter

### Examples

```bash
# In ddpager:
&error              # Show only lines containing "error"
&Exception         # Show only lines containing "Exception"
&                  # Clear filter, show all lines
```

### Filter Behavior

- Filtering preserves your position in the file (approximately)
- Search (`/`, `?`, `n`, `N`) works within filtered lines only
- Jump to TOP (`g`) goes to the first matching line
- Jump to END (`G`) goes to the last matching line

---

## Command Mode Commands

Press `:` to enter command mode, then type a command and press `ENTER`.

### File Navigation

| Command | Action |
|---------|--------|
| `:n` | Go to next file in the ring |
| `:p` | Go to previous file in the ring |
| `:e filename` | Open a file and add it to the ring |
| `:d` | Remove current file from the ring |
| `:x` | Examine first file in the ring |
| `:x N` | Examine N-th file in the ring |

### File Information

| Command | Action |
|---------|--------|
| `:f` | Display file information in status line |
| `=` | Shorthand for `:f` (shows filename, total lines, current position) |

### Display Options

| Command | Action |
|---------|--------|
| `:N` | Toggle line numbers on/off |

### Navigation

| Command | Action |
|---------|--------|
| `:<number>` | Jump to specific line number (1-based) |

### Search Shortcuts

| Command | Action |
|---------|--------|
| `:/pattern` | Search forward (equivalent to `/pattern`) |
| `:?pattern` | Search backward (equivalent to `?pattern`) |

### Quit

| Command | Action |
|---------|--------|
| `:q` | Quit ddpager |
| `q` | Quit ddpager (shortcut, no `:` needed) |

### Examples

```bash
# In ddpager:
:n              # Go to next file
:p              # Go to previous file
:e newfile.txt  # Open and add newfile.txt to ring
:d              # Remove current file from ring
:f              # Show file info
:x              # Examine first file
:x 3            # Examine third file
=N              # Toggle line numbers
:100            # Jump to line 100
:q              # Quit
```

### Command Mode Input

- **Backspace**: Delete last character
- **ESC**: Cancel without executing
- **ENTER**: Execute the command
- **Empty input**: Do nothing and return to view mode

---

## Multiple File Ring Operations

`ddpager` maintains a **file ring** when multiple files are provided, allowing easy navigation between them.

### Opening Multiple Files

```bash
# Open multiple files at once
ddpager file1.txt file2.txt file3.txt
```

### Ring Navigation

When multiple files are open, the status line shows the file position:

```
filename.txt (file 2 of 3)  line 50/1000  75%
```

| Command | Action |
|---------|--------|
| `:n` | Switch to next file |
| `:p` | Switch to previous file |

### Opening Files Within ddpager

Use `:e` to open additional files without restarting:

```bash
# While in ddpager:
:e otherfile.txt
```

The new file is appended to the ring and becomes the current file.

### Removing Files from Ring

Use `:d` to remove the current file from the ring:

```bash
# While in ddpager:
:d
```

**Note:** You cannot remove the last remaining file.

### File Offset Preservation

When switching between files, `ddpager` remembers your position in each file. Returning to a file restores your previous scroll position.

### Examples

```bash
# View log files together
ddpager access.log error.log

# In ddpager with multiple files:
:n              # Next file
:n              # Next file
:p              # Previous file
:e backup.txt   # Add another file
:f              # See which file you're viewing
:d              # Remove current file
```

---

## Binary File Detection

`ddpager` automatically detects binary files when opening them.

### How It Works

1. On file load, `ddpager` reads the first 512 bytes using `dd`
2. It compares the byte count from `dd` with the string length after BASH reads it
3. If BASH's version is shorter, NUL bytes were present (binary content)
4. A warning is displayed on the status line

### Binary File Warning

When a binary file is detected, the status line shows:

```
WARNING: binary file detected — display may be garbled
```

### Display Behavior

Binary files are still displayed, but:
- Content may appear garbled due to NUL bytes and control characters
- Terminal behavior may be unpredictable with binary content

### Examples

```bash
# Opening an image or executable
ddpager /usr/bin/ls
# Shows: WARNING: binary file detected — display may be garbled
```

---

## Status Line

The bottom line of the screen shows status information:

### Normal Display

```
filename.txt  line 50/1000  75%
```

Or with multiple files:

```
filename.txt (file 2 of 3)  line 50/1000  75%
```

### Status Indicators

| Indicator | Meaning |
|-----------|---------|
| `(TOP)` | Viewing the first page |
| `(END)` | Viewing the last page |
| `(empty)` | File has no content |
| `&pattern [X hits]` | Filter is active showing X matching lines |

### Examples

```
# Normal status
myfile.txt  line 1/500  (TOP)

# With filter
myfile.txt  line 10/50  40%  &error [23 hits]

# Multiple files
data.log (file 1 of 4)  line 200/10000  30%
```

---

## Input Methods

### Keyboard Input

`ddpager` reads raw keyboard input directly from the terminal. Supported inputs:

| Input Type | Keys |
|------------|------|
| Printable characters | Letters, numbers, symbols |
| Navigation keys | `j`, `k`, `Space`, `b`, `d`, `u`, `g`, `G` |
| Arrow keys | `UP`, `DOWN`, `LEFT`, `RIGHT` |
| Page navigation | `PgUp`, `PgDn`, `HOME`, `END`, `ENTER` |
| Special keys | `ESC`, `Backspace`, `Delete` |

### Stdin/Pipe Input

When no file arguments are provided, `ddpager` reads from standard input:

```bash
# All of these work:
cat file.txt | ddpager
command --with-options | ddpager
dpkg -l | ddpager
```

**Note:** stdin is read completely into memory before the pager starts. Large piped output may consume significant memory.

### Interactive Prompts

For search (`/`, `?`) and filter (`&`) patterns:
1. The prompt appears on the status line at the bottom
2. Type your pattern
3. Press `ENTER` to execute
4. Press `ESC` to cancel

---

## Help Screen

Press `h` at any time to view the help screen:

```
  ddpager 0.1.0 — BASH/dd/tput pager

  NAVIGATION
    j  Down  Enter     Forward one line
    k  Up              Backward one line
    Space  f  PgDn     Forward one page
    b  PgUp            Backward one page
    d                  Forward half page
    u                  Backward half page
    g  Home            Go to first line
    G  End             Go to last line

  SEARCH
    /pattern           Search forward
    ?pattern           Search backward
    n                  Next match (same direction)
    N                  Next match (reverse direction)

  FILTER
    &pattern           Show only matching lines
    & (empty)          Clear filter

  FILES
    :n                 Next file in ring
    :p                 Previous file in ring
    :e <file>          Open and append file to ring
    :d                 Remove current file from ring
    :f  or  =          Show file info

  OTHER
    :N                 Toggle line numbers
    :<number>          Jump to line
    h                  This help screen
    q  :q              Quit

  Press any key to return to the file...
```

---

## Keyboard Shortcut Reference

### Movement

| Key | Action |
|-----|--------|
| `j` / `DOWN` / `ENTER` | Down one line |
| `k` / `UP` | Up one line |
| `Space` / `f` / `PgDn` | Page down |
| `b` / `PgUp` | Page up |
| `d` | Half page down |
| `u` | Half page up |
| `g` / `HOME` | Go to top |
| `G` / `END` | Go to bottom |

### Search & Filter

| Key | Action |
|-----|--------|
| `/` | Search forward |
| `?` | Search backward |
| `n` | Next match (same direction) |
| `N` | Next match (reverse) |
| `&` | Filter lines |

### Files & Commands

| Key | Action |
|-----|--------|
| `:` | Enter command mode |
| `=` | Show file info |
| `q` | Quit |

### Help

| Key | Action |
|-----|--------|
| `h` | Show help screen |

---

## Exit

To exit `ddpager`, use one of these methods:

| Key | Command | Action |
|-----|---------|--------|
| `q` | | Quit immediately |
| | `:q` | Quit from command mode |
| | `:quit` | Quit from command mode |
| | `:q!` | Quit from command mode (force) |
| `Ctrl+C` | | Signal termination |

**Note:** Pressing `Ctrl+C` will terminate the program but may leave the terminal in an inconsistent state.

---

## Terminal Requirements

`ddpager` requires:

- A POSIX-compatible terminal with `tput` support
- `stty` for raw mode terminal control
- Minimum terminal width: 1 character
- Minimum terminal height: 2 lines (1 content + 1 status)

### Signals Handled

| Signal | Action |
|--------|--------|
| `WINCH` | Recalculate terminal dimensions and redraw |
| `EXIT` | Restore terminal state (cursor, screen) |

---

## Limitations

- **Large files**: Entire file is loaded into memory via `mapfile`
- **Binary files**: Display may be garbled but are detected
- **Wide characters**: Truncation doesn't account for double-width characters
- **No regex**: Search patterns are literal string matches only
- **No regex in filter**: Filter uses simple substring matching
- **No vi mode**: Standard keybindings only (not vi-style)

---

## See Also

- `less(1)` - The traditional pager that inspired ddpager
- `more(1)` - Another traditional pager
- `tput(1)` - Terminal control utility
- `dd(1)` - Data duplication utility
