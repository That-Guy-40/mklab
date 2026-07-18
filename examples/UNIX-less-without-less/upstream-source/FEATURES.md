# ddpager Features

**ddpager** is a `less`-like terminal pager implemented in pure BASH using only builtins, `dd`, and `tput`. No external text-processing tools (`sed`, `awk`, `grep`, `cat`) are used.

---

## Table of Contents

1. [Core Features](#1-core-features)
2. [Terminal Capabilities](#2-terminal-capabilities)
3. [File Management](#3-file-management)
4. [Navigation](#4-navigation)
5. [Search](#5-search)
6. [Filter (`&` command)](#6-filter--command)
7. [Status Line](#7-status-line)
8. [Binary File Detection](#8-binary-file-detection)
9. [View Abstraction](#9-view-abstraction)
10. [Line Number Toggling](#10-line-number-toggling)
11. [Command Mode](#11-command-mode)
12. [Help Screen](#12-help-screen)
13. [Error Handling](#13-error-handling)
14. [Constraints & Limitations](#14-constraints--limitations)

---

## 1. Core Features

### What It Does
A full-screen terminal pager that displays file contents with `less`-style navigation.

### Internal Implementation

```bash
# The entire pager is one BASH script (~1066 lines)
# No external tools except dd and tput
set -uo pipefail  # Strict mode with pipefail
```

**Key design decisions:**
- **BASH 4+ builtins only**: Uses `mapfile` to read files into arrays, `printf` for output, `read` for input
- **`dd` for binary detection**: Only external tool besides `tput`
- **`tput` for terminal control**: Cached escape sequences for performance

### Usage Modes
```bash
ddpager file.txt              # View a single file
ddpager file1.txt file2.txt   # View multiple files (file ring)
command | ddpager             # Pipe stdin into pager
ddpager -N file.txt           # Start with line numbers visible
```

---

## 2. Terminal Capabilities

### Raw Mode Setup

The pager uses raw terminal mode to capture individual keystrokes without line buffering:

```bash
term_init() {
    cache_termcaps
    SAVED_STTY=$(stty -g)              # Save terminal state
    stty -echo -icanon raw min 1 time 0 # Raw mode: no echo, no canonical, immediate
    update_dimensions
    printf '%s' "$TC_SMCUP"             # Enter alternate screen
    printf '%s' "$TC_CIVIS"            # Hide cursor
}
```

**Flags explained:**
- `-echo`: Disable automatic character echo
- `-icanon`: Disable canonical (line-buffered) mode
- `raw`: Raw input mode
- `min 1`: Return after at least 1 character
- `time 0`: No timeout

### Cached Terminal Capabilities

Terminal escape sequences are queried once and cached:

```bash
declare TC_CLEAR TC_CIVIS TC_CNORM TC_SMCUP TC_RMCUP
declare TC_SGR0 TC_BOLD TC_REV TC_DIM TC_EL

cache_termcaps() {
    TC_CLEAR=$(tput clear)
    TC_CIVIS=$(tput civis 2>/dev/null || true)
    TC_CNORM=$(tput cnorm 2>/dev/null || true)
    TC_SMCUP=$(tput smcup 2>/dev/null || true)  # Alternate screen
    TC_RMCUP=$(tput rmcup 2>/dev/null || true)  # Exit alternate screen
    TC_SGR0=$(tput sgr0)    # Reset attributes
    TC_BOLD=$(tput bold)
    TC_REV=$(tput rev)      # Reverse video
    TC_DIM=$(tput dim 2>/dev/null || true)
    TC_EL=$(tput el)        # Erase to end of line
}
```

### Alternate Screen Buffer

The pager uses the terminal's alternate screen buffer (`smcup`/`rmcup`) so the original terminal content is preserved and restored on exit:

```bash
# On startup
printf '%s' "$TC_SMCUP"   # Switch to alternate screen

# On exit
printf '%s' "$TC_RMCUP"   # Return to normal screen
printf '%s' "$TC_CNORM"   # Restore cursor visibility
stty "$SAVED_STTY"        # Restore terminal settings
```

### Cleanup & Signal Handling

```bash
trap 'term_cleanup' EXIT   # Clean up on normal exit
trap 'update_dimensions; draw_screen' WINCH  # Handle window resize
```

The `WINCH` trap updates terminal dimensions and redraws the screen when the user resizes the window.

---

## 3. File Management

### File Ring

Multiple files are managed as a ring with independent scroll positions:

```bash
declare -a FILE_NAMES=()
declare -a FILE_OFFSETS=()  # Each file remembers its scroll position
declare -i FILE_IDX=0
declare -i FILE_COUNT=0
```

**Operations:**
- `:n` / `:next` — Go to next file
- `:p` / `:prev` — Go to previous file
- `:e <filename>` — Open and append file to ring
- `:d` — Remove current file from ring

### Saving/Restoring Offsets

Each file's scroll position is preserved when switching files:

```bash
save_offset() {
    FILE_OFFSETS[$FILE_IDX]=$OFFSET
}

switch_file() {
    local -i idx="$1"
    save_offset()              # Save current position
    FILE_IDX=$idx
    load_file "${FILE_NAMES[$FILE_IDX]}"
    OFFSET=${FILE_OFFSETS[$FILE_IDX]:-0}  # Restore or default to 0
}
```

### stdin Handling

stdin must be buffered **before** entering raw mode (since `stty raw` interferes with pipe input):

```bash
if [[ $# -eq 0 ]]; then
    if [[ -t 0 ]]; then
        printf 'ddpager: missing filename...\n' >&2
        exit 1
    fi
    # Slurp stdin BEFORE term_init
    mapfile -t BUFFER
    BUFFER_LEN=${#BUFFER[@]}
    FILE_NAMES=("(stdin)")
    FILE_COUNT=1
fi
```

---

## 4. Navigation

### Movement Modes

| Key | Action | Implementation |
|-----|--------|----------------|
| `j`, `Enter`, `↓` | Down one line | `(( OFFSET++ ))` |
| `k`, `↑` | Up one line | `(( OFFSET-- ))` |
| `Space`, `f`, `PgDn` | Forward one page | `OFFSET += PAGE_LINES` |
| `b`, `PgUp` | Backward one page | `OFFSET -= PAGE_LINES` |
| `d` | Forward half page | `OFFSET += PAGE_LINES / 2` |
| `u` | Backward half page | `OFFSET -= PAGE_LINES / 2` |
| `g`, `Home` | Go to first line | `OFFSET = 0` |
| `G`, `End` | Go to last line | `OFFSET = vlen - PAGE_LINES` |

### Clamping

The `draw_screen()` function clamps the offset to valid bounds:

```bash
if (( vlen <= PAGE_LINES )); then
    OFFSET=0
elif (( OFFSET > vlen - PAGE_LINES )); then
    OFFSET=$(( vlen - PAGE_LINES ))
fi
(( OFFSET < 0 )) && OFFSET=0
```

### CSI Sequence Decoding

Arrow keys and function keys send ANSI CSI sequences. The pager decodes them:

```bash
read_key() {
    IFS= read -rsn1 c || true
    
    if [[ "$c" == $'\e' ]]; then  # Escape character
        IFS= read -rsn1 -t 0.05 seq || true
        if [[ "$seq" == "[" ]]; then
            IFS= read -rsn1 -t 0.05 param || true
            case "$param" in
                A) printf 'UP' ;;
                B) printf 'DOWN' ;;
                C) printf 'RIGHT' ;;
                D) printf 'LEFT' ;;
                H) printf 'HOME' ;;
                F) printf 'END' ;;
                5) IFS= read -rsn1 -t 0.05 _; printf 'PGUP' ;;  # PgUp
                6) IFS= read -rsn1 -t 0.05 _; printf 'PGDN' ;;  # PgDn
            esac
        fi
    fi
}
```

**Key insight**: Uses `read -rsn1 -t 0.05` with a 50ms timeout to peek at additional characters without blocking.

---

## 5. Search

### Forward/Backward Search

```bash
search_forward() {
    local pattern="$1"
    local -i vlen start i
    vlen=$(view_len)
    start=$(( OFFSET + 1 ))  # Start from next line

    # Search from current position forward
    for (( i = start; i < vlen; i++ )); do
        if [[ "$(view_line "$i")" == *"$pattern"* ]]; then
            OFFSET=$i
            return 0
        fi
    done

    # Wrap: search from top
    for (( i = 0; i < start && i < vlen; i++ )); do
        if [[ "$(view_line "$i")" == *"$pattern"* ]]; then
            OFFSET=$i
            set_message "search hit TOP, continuing at BOTTOM"
            return 0
        fi
    done

    set_message "Pattern not found: ${pattern}"
    return 1
}
```

### Search Highlighting

Matches are highlighted using terminal reverse video:

```bash
print_highlighted_line() {
    local line="$1" maxw="$2"
    line="${line:0:$maxw}"  # Truncate first

    if [[ -z "$SEARCH_PATTERN" || "$line" != *"$SEARCH_PATTERN"* ]]; then
        printf '%s' "$line"
        return
    fi

    # Walk the line, highlighting each match
    local remaining="$line"
    while [[ "$remaining" == *"$SEARCH_PATTERN"* ]]; do
        local before="${remaining%%"$SEARCH_PATTERN"*}"
        printf '%s' "$before"
        printf '%s' "$TC_REV"           # Reverse video on
        printf '%s' "$SEARCH_PATTERN"
        printf '%s' "$TC_SGR0"          # Reset attributes
        remaining="${remaining#*"$SEARCH_PATTERN"}"
    done
    printf '%s' "$remaining"
}
```

**Technique**: Uses BASH string manipulation (`%%`, `#*`) to walk through matches. No `sed` or regex.

### Repeat Search

```bash
repeat_search() {
    local -i dir=$1  # 1=same direction, -1=reverse
    local -i effective=$(( SEARCH_DIR * dir ))
    if (( effective > 0 )); then
        search_forward "$SEARCH_PATTERN"
    else
        search_backward "$SEARCH_PATTERN"
    fi
}
```

`n` repeats in same direction, `N` reverses direction.

---

## 6. Filter (`&` Command)

### What It Does
The `&` command (like `less`) shows only lines matching a pattern, hiding non-matching lines.

### Internal Implementation

```bash
declare FILTER_PATTERN=""
declare -a FILTER_IDX=()  # Indices of matching lines
declare -i FILTER_ACTIVE=0

apply_filter() {
    FILTER_IDX=()
    if [[ -z "$FILTER_PATTERN" ]]; then
        FILTER_ACTIVE=0
        return
    fi
    FILTER_ACTIVE=1
    local -i i
    for (( i = 0; i < BUFFER_LEN; i++ )); do
        if [[ "${BUFFER[$i]}" == *"$FILTER_PATTERN"* ]]; then
            FILTER_IDX+=("$i")
        fi
    done
}
```

### Filter-Aware Display

All display functions use `view_*()` accessors (see View Abstraction section) to transparently handle filtering.

### Status Line Display

When active, the status line shows filter info with hit count:

```bash
filter_info=""
(( FILTER_ACTIVE )) && filter_info=" &${FILTER_PATTERN} [${#FILTER_IDX[@]} hits]"
```

**Empty pattern** (`&` with no input) clears the filter.

---

## 7. Status Line

The last line of the screen shows contextual information:

```
filename (file 2 of 3)  line 45/200  50%  &error [42 hits]
```

### Components

| Component | Condition | Format |
|-----------|-----------|--------|
| File name | Always | `filename` |
| File ring info | Multiple files | `(file N of M)` |
| Line position | Always | `line N/L` (L = filtered count if active) |
| Position indicator | Always | `N%` or `(TOP)` or `(END)` or `(empty)` |
| Filter info | Filter active | `&pattern [N hits]` |

### Position Calculation

```bash
if (( vlen == 0 )); then
    pct="(empty)"
elif (( OFFSET + PAGE_LINES >= vlen )); then
    pct="(END)"
elif (( OFFSET == 0 )); then
    pct="(TOP)"
else
    pct="$(( (OFFSET + PAGE_LINES) * 100 / vlen ))%"
fi
```

---

## 8. Binary File Detection

### The Challenge

BASH's `$()` command substitution **silently strips NUL bytes** and trailing newlines. This makes detecting binary files tricky.

### The Solution: Sentinel + dd stderr

```bash
detect_binary() {
    local file="$1"
    [[ "$file" == "(stdin)" || ! -f "$file" ]] && return 1

    # Step 1: Get actual byte count from dd's stderr
    local dd_stderr
    dd_stderr=$(dd if="$file" of=/dev/null bs=512 count=1 2>&1)
    
    # Parse "512 bytes (512 B) copied" or BSD format
    local -i actual_bytes=0 prev=""
    for word in $dd_stderr; do
        if [[ "$word" == bytes* && "$prev" =~ ^[0-9]+$ ]]; then
            actual_bytes=$prev
            break
        fi
        prev="$word"
    done

    # Step 2: Read bytes into variable with sentinel
    local sample
    sample=$(dd if="$file" bs=512 count=1 2>/dev/null; printf X)
    sample="${sample%X}"  # Remove sentinel

    # Step 3: Compare lengths
    if (( ${#sample} < actual_bytes )); then
        return 0  # Binary (NULs were stripped)
    fi
    return 1  # Text
}
```

### Why This Works

1. **dd reports actual bytes**: Even if NULs exist, `dd` counts them correctly in stderr
2. **Sentinel trick**: `printf X` inside subshell preserves trailing newlines that BASH would otherwise strip
3. **Length comparison**: If the read variable is shorter than expected, NUL bytes were stripped → binary file

**Only `dd` is used** — no `file` command or other external tools.

---

## 9. View Abstraction

### The Problem

When a filter is active, the display should show only matching lines, but navigation and status should work transparently as if viewing the full file.

### The Solution: View Layer

```bash
# Map view index → real buffer line number
view_real_lineno() {
    local -i vi=$1
    if (( FILTER_ACTIVE )); then
        if (( vi >= 0 && vi < ${#FILTER_IDX[@]} )); then
            printf '%d' $(( FILTER_IDX[vi] + 1 ))  # 1-based
        else
            printf '%d' 0
        fi
    else
        printf '%d' $(( vi + 1 ))
    fi
}

view_line() {
    local -i vi=$1
    if (( FILTER_ACTIVE )); then
        if (( vi >= 0 && vi < ${#FILTER_IDX[@]} )); then
            printf '%s' "${BUFFER[${FILTER_IDX[$vi]}]}"
        fi
    else
        if (( vi >= 0 && vi < BUFFER_LEN )); then
            printf '%s' "${BUFFER[$vi]}"
        fi
    fi
}

view_len() {
    if (( FILTER_ACTIVE )); then
        printf '%d' "${#FILTER_IDX[@]}"
    else
        printf '%d' "$BUFFER_LEN"
    fi
}
```

### Benefits

- **Search** works on filtered lines only
- **Navigation** is in terms of visible lines
- **Status line** shows correct line counts
- **Line numbers** map back to real buffer positions
- **No changes needed** to display or navigation code

---

## 10. Line Number Toggling

### Command

```bash
:N   # Toggle line numbers on/off
```

### Implementation

```bash
declare -i LINE_NUMBERS=0  # Default off

# In command handler:
N)
    (( LINE_NUMBERS = ! LINE_NUMBERS ))
    local state="ON"
    (( ! LINE_NUMBERS )) && state="OFF"
    set_message "Line numbers: ${state}"
    ;;
```

### Display with Line Numbers

```bash
if (( LINE_NUMBERS )); then
    local -i max_ln=$BUFFER_LEN
    gutter=$(( ${#max_ln} + 1 ))  # Width based on total lines
fi

# For each line:
real_ln=$(view_real_lineno "$vi")  # Map to actual line number
printf '%s' "$TC_DIM"
printf "%${gutter}d" "$real_ln"   # Right-aligned
printf '%s' "$TC_SGR0"
```

---

## 11. Command Mode

### Available Commands

| Command | Action |
|---------|--------|
| `:q`, `:quit`, `q` | Quit |
| `:n`, `:next` | Next file |
| `:p`, `:prev` | Previous file |
| `:e <filename>` | Open file |
| `:d` | Remove current file |
| `:f` or `=` | Show file info |
| `:N` | Toggle line numbers |
| `:<number>` | Jump to line |
| `:/pattern` | Search forward |
| `:?pattern` | Search backward |

### Implementation

```bash
do_command() {
    local cmd=""
    # Show : prompt, read input with backspace handling
    # ...
    
    # Parse with case statement
    case "$cmd" in
        q|quit|q!)    do_quit ;;
        n|next)       next_file ;;
        /*)           SEARCH_PATTERN="${cmd:1}"; search_forward ;;
        [0-9]*)       cmd_goto_line "$cmd" ;;
        *)            set_message "Unknown command: :${cmd}" ;;
    esac
}
```

### Tab-Like Completion Hints

The command mode shows available commands in the help screen, but there is no actual tab completion (would require `compgen` or readline integration). The `socat` option mentioned in the header could provide readline integration.

---

## 12. Help Screen

### Display

```bash
show_help() {
    local -a H=(
        ""
        "  ddpager ${DDPAGER_VERSION} — BASH/dd/tput pager"
        ""
        "  NAVIGATION"
        "    j  Down  Enter     Forward one line"
        "    k  Up              Backward one line"
        "    Space  f  PgDn     Forward one page"
        ...
    )
    
    printf '%s' "$TC_CLEAR"
    for (( i = 0; i < ${#H[@]} && i < TERM_LINES; i++ )); do
        term_cup "$i" 0
        printf '%s' "${H[$i]}"
    done
    
    read_key > /dev/null  # Wait for any key
}
```

### Trigger

Press `h` to show help.

---

## 13. Error Handling

### Input Validation

```bash
# File existence check
if [[ ! -f "$fname" && ! -r "$fname" ]]; then
    set_message "File not found: ${fname}"
    return 1
fi

# Numeric validation for :goto
if [[ ! "$num" =~ ^[0-9]+$ ]]; then
    set_message "Not a number: ${num}"
    return 1
fi
```

### Bounds Checking

```bash
# Clamp target line
target=$(( num - 1 ))
(( target < 0 )) && target=0
(( target >= vlen )) && target=$(( vlen - 1 ))
```

### Missing Tools

```bash
TC_CIVIS=$(tput civis 2>/dev/null || true)  # Graceful fallback
TC_DIM=$(tput dim 2>/dev/null || true)
```

If `tput` doesn't support a capability, empty strings are used instead of errors.

### Stty Restoration

```bash
term_cleanup() {
    printf '%s' "$TC_CNORM"
    printf '%s' "$TC_RMCUP"
    [[ -n "$SAVED_STTY" ]] && stty "$SAVED_STTY"
}

trap 'term_cleanup' EXIT  # Ensures cleanup even on error
```

---

## 14. Constraints & Limitations

### Requirements

| Requirement | Details |
|-------------|---------|
| **BASH 4+** | Uses `mapfile`, `declare -a`, `[[ =~ ]]` (BASH 3+) |
| **Terminal** | Must support ANSI escape sequences, alternate screen |
| **tput** | Must have terminal database (`terminfo`) |
| **dd** | Coreutils `dd` for binary detection |

### What Doesn't Work

| Limitation | Explanation |
|------------|-------------|
| **Wide characters** | Truncation uses byte count, not visual width |
| **Very large files** | Entire file loaded into BASH array — memory intensive |
| **Binary content** | May display garbled; detection only warns |
| **No regex search** | Uses simple glob patterns (`*pattern*`) |
| **No regex filter** | Filter uses substring matching only |
| **No regex highlight** | Highlighting uses literal string match |
| **No scrollback** | Uses terminal alternate screen, no scrollback buffer |
| **No mouse support** | Raw mode doesn't capture mouse events |
| **No color syntax** | Only search/selection highlighting |
| **Slow on large files** | BASH arrays have O(n) access for some operations |

### Performance Characteristics

```bash
# File loading: O(n) where n = lines
mapfile -t BUFFER < "$file"

# Search: O(n) per search
for (( i = 0; i < BUFFER_LEN; i++ )); do
    if [[ "${BUFFER[$i]}" == *"$pattern"* ]]; then

# Filter: O(n) application
for (( i = 0; i < BUFFER_LEN; i++ )); do
    if [[ "${BUFFER[$i]}" == *"$FILTER_PATTERN"* ]]; then

# Display: O(lines × pattern_length)
```

### Tools Explicitly Excluded

```bash
# From header comment:
# No sed, awk, grep, less, more, cat, or other text-processing externals
```

This is a **feature**, not a bug — the constraints force creative BASH solutions.

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────┐
│                        ddpager                               │
├─────────────────────────────────────────────────────────────┤
│  Terminal Layer (tput)                                       │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ cache_termcaps() → cached escape sequences             ││
│  │ term_init() → raw mode + alternate screen              ││
│  │ term_cleanup() → restore terminal state                ││
│  └─────────────────────────────────────────────────────────┘│
├─────────────────────────────────────────────────────────────┤
│  Input Layer                                                │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ read_key() → CSI sequence decoding                    ││
│  │ read_prompt() → line input with backspace             ││
│  └─────────────────────────────────────────────────────────┘│
├─────────────────────────────────────────────────────────────┤
│  State Layer                                                │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ FILE_NAMES[], FILE_OFFSETS[] → file ring              ││
│  │ BUFFER[] → loaded file contents                        ││
│  │ FILTER_IDX[] → filtered line indices                   ││
│  │ OFFSET → current scroll position                       ││
│  │ SEARCH_PATTERN → current search term                   ││
│  └─────────────────────────────────────────────────────────┘│
├─────────────────────────────────────────────────────────────┤
│  View Abstraction (filter-aware accessors)                  │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ view_len() → visible line count                        ││
│  │ view_line(n) → line content                            ││
│  │ view_real_lineno(n) → real line number                 ││
│  └─────────────────────────────────────────────────────────┘│
├─────────────────────────────────────────────────────────────┤
│  Display Layer                                              │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ draw_screen() → render visible lines + status          ││
│  │ draw_status_line() → file info, position, filter       ││
│  │ print_highlighted_line() → search highlighting         ││
│  └─────────────────────────────────────────────────────────┘│
├─────────────────────────────────────────────────────────────┤
│  Operations                                                 │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ Navigation: j/k/f/b/d/u/g/G                           ││
│  │ Search: / ? n N                                       ││
│  │ Filter: &                                              ││
│  │ Commands: :q :n :e :d :f :N :<n>                      ││
│  │ Files: next_file, prev_file, switch_file               ││
│  │ Binary: detect_binary (dd + sentinel trick)           ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

---

## Unique Aspects

1. **Pure BASH**: No external text processing tools — all string manipulation via BASH builtins
2. **dd-based binary detection**: Leverages `dd`'s stderr output and BASH's NUL-stripping behavior
3. **View abstraction**: Filter mode is completely transparent to navigation and display
4. **Sentinel technique**: `printf X` inside `$()` preserves trailing newlines for accurate length comparison
5. **CSI decoding**: Hand-rolled ANSI escape sequence parser for arrow/function keys
6. **Single-file implementation**: ~1066 lines of self-contained, dependency-free code
