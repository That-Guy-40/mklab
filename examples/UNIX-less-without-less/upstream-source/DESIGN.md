# ddpager Design Guide

A technical deep dive into the architecture, design patterns, and implementation choices of ddpager.

---

## Table of Contents

1. [High-Level Architecture](#high-level-architecture)
2. [Component Breakdown](#component-breakdown)
3. [Key Design Patterns](#key-design-patterns)
4. [Data Flow](#data-flow)
5. [Terminal Control Protocol](#terminal-control-protocol)
6. [Input Processing Pipeline](#input-processing-pipeline)
7. [File Management Architecture](#file-management-architecture)
8. [View Abstraction Layer](#view-abstraction-layer)
9. [Binary Detection Algorithm](#binary-detection-algorithm)
10. [State Management](#state-management)

---

## High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        ddpager (main)                            │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  MAIN() - Argument parsing, setup, event loop              │  │
│  │  ┌──────────────────────────────────────────────────────┐  │  │
│  │  │  while true:                                         │  │  │
│  │  │    draw_screen()                                     │  │  │
│  │  │    key = read_key()                                  │  │  │
│  │  │    dispatch(key)                                     │  │  │
│  │  └──────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  TERMINAL LAYER                                             │  │
│  │  ┌─────────────┬──────────────┬─────────────────────────┐  │││
│  │  │cache_term-  │term_init()   │term_cleanup()           │  │││
│  │  │caps()       │stty rawmode  │stty restoration         │  │││
│  │  └─────────────┴──────────────┴─────────────────────────┘  │││
│  │  tput queries → cached escapes                              │  │
│  │  ┌─────────────┬──────────────┬─────────────────────────┐  │││
│  │  │SMCUP/RMCUP  │CIVIS/CNORM   │SGR0/BOLD/REV/DIM/EL     │  │││
│  │  └─────────────┴──────────────┴─────────────────────────┘  │││
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  STATE LAYER                                              │  │
│  │  ┌─────────────────┬─────────────────┬──────────────────┐  │││
│  │  │FILE_RING        │BUFFER           │VIEW STATE        │  │││
│  │  │ FILE_NAMES[]    │ BUFFER[]        │ OFFSET           │  │││
│  │  │ FILE_OFFSETS[]  │ BUFFER_LEN      │ PAGE_LINES       │  │││
│  │  │ FILE_IDX        │ IS_BINARY       │ LINE_NUMBERS     │  │││
│  │  │ FILE_COUNT      │                 │                  │  │││
│  │  └─────────────────┴─────────────────┴──────────────────┘  │││
│  │  ┌─────────────────┬─────────────────┬──────────────────┐  │││
│  │  │SEARCH           │FILTER           │STATUS           │  │││
│  │  │ SEARCH_PATTERN  │ FILTER_PATTERN│ MESSAGE          │  │││
│  │  │ SEARCH_DIR      │ FILTER_IDX[]    │ NEXT_KEY         │  │││
│  │  │                 │ FILTER_ACTIVE   │                  │  │││
│  │  └─────────────────┴─────────────────┴──────────────────┘  │││
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  VIEW ABSTRACTION LAYER                                   │  │
│  │  ┌─────────────────┬─────────────────┬──────────────────┐  │││
│  │  │view_len()       │view_line(n)     │view_real_lineno(n│  │││
│  │  └─────────────────┴─────────────────┴──────────────────┘  │││
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  INPUT LAYER                                              │  │
│  │  ┌─────────────────┬─────────────────┬──────────────────┐  │││
│  │  │read_key()       │read_count()     │read_prompt()     │  │││
│  │  │CSI decoding     │numeric prefixes│interactive prompt│  │││
│  │  └─────────────────┴─────────────────┴──────────────────┘  │││
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  DISPLAY LAYER                                            │  │
│  │  ┌─────────────────┬─────────────────┬──────────────────┐  │││
│  │  │draw_screen()    │draw_status_line │print_highlighted │  │││
│  │  │                 │                 │_line()           │  │││
│  │  └─────────────────┴─────────────────┴──────────────────┘  │││
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  OPERATIONS                                               │  │
│  │  ┌──────────────────────────────────────────────────────┐  │││
│  │  │Navigation: j,k,f,b,d,u,g,G,S,P                      │  │││
│  │  │Search: /,?,n,N                                      │  │││
│  │  │Filter: &                                            │  │││
│  │  │Commands: :q,:n,:p,:e,:d,:f,:N,:x,<n>               │  │││
│  │  │Files: next_file(),prev_file(),switch_file()         │  │││
│  │  │Binary: detect_binary()                              │  │││
│  │  └──────────────────────────────────────────────────────┘  │││
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## Component Breakdown

### 1. Main Function (`main()`)

**Location**: Lines 838-1045

**Responsibilities**:
- Parse command-line arguments (`-N`, `-h`, `-v`)
- Build the file ring from arguments or stdin
- Initialize terminal (via `term_init`)
- Enter event loop

**Key Decision Points**:

```bash
# Line 1002: Detect stdin vs file arguments
if [[ $# -eq 0 ]]; then
    if [[ -t 0 ]]; then
        # No arguments and not piped → error
        printf 'ddpager: missing filename...\n' >&2
        exit 1
    fi
    #stdin is piped — slurp before entering raw mode
    mapfile -t BUFFER
    FILE_NAMES=("(stdin)")
fi
```

**Why slurp stdin before raw mode?**
When `stty raw` is active, stdin reads behave differently. The pipe must be fully consumed before entering raw mode, or input gets lost.

---

### 2. Terminal Layer

**Location**: Lines 33-67

#### `cache_termcaps()`

 Queries `tput` once and caches escape sequences:

```bash
cache_termcaps() {
    TC_CLEAR=$(tput clear)
    TC_CIVIS=$(tput civis 2>/dev/null || true)
    TC_SMCUP=$(tput smcup 2>/dev/null || true)
    TC_RMCUP=$(tput rmcup 2>/dev/null || true)
    TC_SGR0=$(tput sgr0)
    TC_BOLD=$(tput bold)
    TC_REV=$(tput rev)
    TC_DIM=$(tput dim 2>/dev/null || true)
    TC_EL=$(tput el)
}
```

**Design Choice**: Query terminal capabilities once at startup rather than repeatedly. This:
- Reduces subprocess calls (performance)
- Prevents flicker from repeated `tput` invocations
- Gracefully handles missing capabilities with `|| true`

#### `term_init()`

```bash
term_init() {
    cache_termcaps
    SAVED_STTY=$(stty -g)              # Save current state
    stty -echo -icanon raw min 1 time 0 # Enter raw mode
    update_dimensions
    printf '%s' "$TC_SMCUP"             # Enter alternate screen
    printf '%s' "$TC_CIVIS"             # Hide cursor
}
```

**Raw Mode Flags**:
- `-echo`: Don't echo typed characters
- `-icanon`: Disable line buffering (read character-by-character)
- `raw`: Raw input mode
- `min 1`: Return after 1 character received
- `time 0`: No timeout (block until character)

#### `term_cleanup()`

```bash
term_cleanup() {
    printf '%s' "$TC_CNORM"    # Restore cursor
    printf '%s' "$TC_RMCUP"    # Return to normal screen
    [[ -n "$SAVED_STTY" ]] && stty "$SAVED_STTY"
}
```

**Cleanup is critical** — if the script exits without restoring terminal state, the user's terminal may remain in a broken state (no echo, cursor hidden).

**Signal Traps**:
```bash
trap 'term_cleanup' EXIT       # Normal exit, errors
trap 'update_dimensions; draw_screen' WINCH  # Window resize
```

---

### 3. State Layer

**Location**: Lines 73-102

#### File Ring State

```bash
declare -a  FILE_NAMES=()      # Array of filenames
declare -a  FILE_OFFSETS=()    # Scroll position per file
declare -i  FILE_IDX=0         # Currently active file
declare -i  FILE_COUNT=0       # Total files in ring
```

**File Offset Preservation**:
```bash
save_offset() {
    FILE_OFFSETS[$FILE_IDX]=$OFFSET
}

switch_file() {
    local -i idx="$1"
    save_offset                    # Save current position
    FILE_IDX=$idx
    load_file "${FILE_NAMES[$FILE_IDX]}"
    OFFSET=${FILE_OFFSETS[$FILE_IDX]:-0}  # Restore or default to 0
}
```

**Why Store Offsets?**
When switching between files, users expect to return to where they left off. Each file's offset is preserved independently.

#### Buffer State

```bash
declare -a  BUFFER=()          # File contents (one line per element)
declare -i  BUFFER_LEN=0       # Length of BUFFER
declare -i  OFFSET=0           # Top-of-screen view index
declare -i  IS_BINARY=0        # Binary file flag
```

**Loading with `mapfile`**:
```bash
mapfile -t BUFFER < "$file"
BUFFER_LEN=${#BUFFER[@]}
```

**Note**: The entire file is loaded into memory. This is a limitation for very large files.

#### View State

```bash
declare -i  PAGE_LINES=0       # Visible lines (TERM_LINES - 1)
declare -i  LINE_NUMBERS=0     # Toggle line numbers
```

#### Search State

```bash
declare     SEARCH_PATTERN=""  # Current search pattern
declare -i  SEARCH_DIR=1       # 1=forward, -1=backward
```

#### Filter State

```bash
declare     FILTER_PATTERN=""  # Filter pattern string
declare -a  FILTER_IDX=()      # Indices of matching lines
declare -i  FILTER_ACTIVE=0    # Filter enabled flag
```

**Filter Index Array**:
Instead of creating a filtered copy of the buffer, we store indices of matching lines. This saves memory and keeps the original buffer intact.

---

## Key Design Patterns

### 1. View Abstraction Layer

**Problem**: When a filter is active, the display should show only matching lines, but:
- Navigation should work in terms of visible lines
- Status line should show filtered counts
- Line numbers should map to original buffer positions

**Solution**: Abstract all file access through view functions:

```bash
view_len() {
    if (( FILTER_ACTIVE )); then
        printf '%d' "${#FILTER_IDX[@]}"
    else
        printf '%d' "$BUFFER_LEN"
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

view_real_lineno() {
    local -i vi=$1
    if (( FILTER_ACTIVE )); then
        if (( vi >= 0 && vi < ${#FILTER_IDX[@]} )); then
            printf '%d' $(( FILTER_IDX[vi] + 1 ))  # 1-based
        fi
    else
        printf '%d' $(( vi + 1 ))
    fi
}
```

**Benefits**:
- Display code doesn't need to know about filter state
- Search works transparently on filtered or full view
- Navigation (j, k, page) works in terms of visible lines
- Line numbers correctly map to original buffer

### 2. State Machine for Input

The input handler (`read_key`) is a simple state machine:

```
                 ┌─────────────────┐
                 │   Read 1 byte   │
                 └────────┬────────┘
                          │
                   ┌──────┴──────┐
                   │             │
              ┌────▼────┐   ┌───▼────┐
              │  EOF    │   │  ESC   │
              └─────────┘   └──┬─────┘
                               │
                          ┌────▼────┐
                          │ '['?    │
                          └──┬─────┘
                               │
                    ┌──────────▼──────────┐
                    │ CSI sequence decode │
                    │ (A=UP, B=DOWN, etc.)│
                    └─────────────────────┘
```

**Implementation**:
```bash
read_key() {
    local c
    IFS= read -rsn1 c || true

    if [[ "$c" == $'\e' ]]; then  # Escape (CSI start)
        local seq=""
        IFS= read -rsn1 -t 0.05 seq || true
        if [[ "$seq" == "[" ]]; then
            IFS= read -rsn1 -t 0.05 param || true
            case "$param" in
                A) printf 'UP' ;;
                B) printf 'DOWN' ;;
                # ... other keys
            esac
        fi
    fi

    printf '%s' "$c"
}
```

**Timeout Handling**: The `-t 0.05` parameter provides 50ms to read additional CSI characters. If no more data arrives, the function returns early.

### 3. Prompt Mode State Machine

For interactive prompts (`/`, `?`, `&`, `:`):

```
               ┌───────────────────┐
               │ Show prompt       │
               └───────┬───────────┘
                       │
                ┌──────▼───────┐
                │ Read 1 char  │
                └──────┬───────┘
                       │
         ┌─────────────┼──────────────┐
         │             │              │
    ┌────▼────┐    ┌───▼────┐    ┌───▼────┐
    │  Enter  │    │   BS   │    │  ESC   │
    └────┬────┘    └───┬────┘    └────┬───┘
         │             │              │
    ┌────▼────┐    ┌───▼────┐    ┌────▼────┐
    │  Return │    │Delete  │    │Cancel   │
    │ prompt  │    │ char   │    │ (empty) │
    └─────────┘    └────┬───┘    └─────────┘
                       │
                  ┌────▼────┐
                  │Add char │
                  └────┬────┘
                       │
                ┌──────▼───────┐
                │ Loop until   │
                │Enter,ESC,EOF │
                └──────────────┘
```

### 4. Binary Detection Heuristic

**Challenge**: BASH's `$()` command substitution strips NUL bytes. How to detect binary content without external tools?

**Technique**:

1. Use `dd` to report byte count (dd counts NULs correctly)
2. Read same bytes into BASH variable (NULs stripped)
3. Compare lengths — if variable is shorter, NULs were present

```bash
detect_binary() {
    local file="$1"
    # Step 1: Get actual byte count from dd stderr
    local dd_stderr
    dd_stderr=$(dd if="$file" of=/dev/null bs=512 count=1 2>&1)
    
    local -i actual_bytes=0 prev=""
    for word in $dd_stderr; do
        if [[ "$word" == bytes* && "$prev" =~ ^[0-9]+$ ]]; then
            actual_bytes=$prev
            break
        fi
        prev="$word"
    done

    # Step 2: Read with sentinel to preserve trailing newlines
    local sample
    sample=$(dd if="$file" bs=512 count=1 2>/dev/null; printf X)
    sample="${sample%X}"

    # Step 3: Compare
    if (( ${#sample} < actual_bytes )); then
        return 0  # binary (NULs stripped)
    fi
    return 1      # text
}
```

**Why the sentinel?** BASH also strips trailing newlines. The `printf X` trick ensures trailing newlines are preserved so only NUL stripping causes length differences.

---

## Data Flow

### File Loading

```
┌──────────────────┐
│    File Path     │
└────────┬─────────┘
         │
         ▼
┌───────────────────────────────────┐
│  detect_binary()                  │
│  ┌─────────────────────────────┐  │
│  │  dd → stderr (byte count)   │  │
│  │  dd → variable (sample)     │  │
│  │  Compare lengths             │  │
│  └─────────────────────────────┘  │
└──────────────────┬────────────────┘
                   │
          ┌────────┴────────┐
          │                 │
       Binary?          Text?
          │                 │
          │                 │
   ┌──────▼──────┐    ┌────▼──────┐
   │  IS_BINARY  │    │ mapfile   │
   │   = 1       │    │  -t BUFFER│
   └─────────────┘    └───────────┘
```

### User Input → Action

```
┌──────────────────┐
│   read_key()     │
│   (raw terminal) │
└────────┬─────────┘
         │
         ▼
┌──────────────────────────────┐
│  Key Decoded                 │
│  ┌────────────────────────┐  │
│  │ j, k, Space, etc.      │  │
│  │ Arrow keys (CSI)       │  │
│  │ /, ?, &, : (prompts)   │  │
│  │ q, h (commands)        │  │
│  └────────────────────────┘  │
└──────────────────┬───────────┘
                   │
         ┌──────────▼──────────┐
         │    dispatch(key)    │
         │    (case statement) │
         └──────────┬──────────┘
                    │
     ┌──────────────┴──────────────┐
     │                             │
     ▼                             ▼
┌──────────┐                  ┌───────────┐
│  Search  │                  │  Navigate │
│  /?nN    │                  │  jkgGfdub │
└──────────┘                  └───────────┘
```

### Filter Application

```
┌─────────────────────────────────────┐
│  User types: &error                 │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  do_filter()                        │
│  ┌───────────────────────────────┐  │
│  │  Iterate BUFFER[]             │  │
│  │  if [[ "$line" == *"$pattern"* ]]; then
│  │    FILTER_IDX+=($i)           │  │
│  │  fi                           │  │
│  └───────────────────────────────┘  │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  FILTER_IDX = [0, 3, 12, 45, ...]  │
│  (Indices of matching lines)       │
└─────────────────────────────────────┘
```

### Display Pipeline

```
┌─────────────────────────────────────┐
│  draw_screen()                      │
│  ┌───────────────────────────────┐  │
│  │  for i in 0..PAGE_LINES-1:   │  │
│  │    vi = OFFSET + i            │  │
│  │    line = view_line(vi)       │  │
│  │    print_highlighted_line()   │  │
│  └───────────────────────────────┘  │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  Terminal with highlighted matches │
└─────────────────────────────────────┘
```

---

## Terminal Control Protocol

### Command Mode Sequences

ddpager uses standard ANSI escape sequences via `tput`:

| Purpose | `tput` Call | Escape Sequence |
|---------|-------------|-----------------|
| Clear screen | `tput clear` | `\e[H\e[J` |
| Hide cursor | `tput civis` | `\e[?25l` |
| Show cursor | `tput cnorm` | `\e[?25h` |
| Enter alt screen | `tput smcup` | `\e[?1049h` |
| Exit alt screen | `tput rmcup` | `\e[?1049l` |
| Reset attributes | `tput sgr0` | `\e(B\e[m` |
| Bold | `tput bold` | `\e[1m` |
| Reverse video | `tput rev` | `\e[7m` |
| Dim | `tput dim` | `\e[2m` |
| Erase to EOL | `tput el` | `\e[K` |
| Cursor up N | `tput cup - $N` | `\e[$A` |

### Input Detection

#### Printable Keys

Read directly:
```bash
IFS= read -rsn1 c
# c = "a", "b", "1", "!", etc.
```

#### Arrow Keys (CSI sequences)

```
UP:    \e[A
DOWN:  \e[B
RIGHT: \e[C
LEFT:  \e[D
HOME:  \e[H or \e[1~
END:   \e[F or \e[4~
PGUP:  \e[5~
PGDN:  \e[6~
```

**Decoding Logic**:
1. Read `\e` (ESC)
2. Try to read next byte
3. If `[`, try to read param byte
4. Match param to key code

```bash
read_key() {
    IFS= read -rsn1 c || true
    if [[ "$c" == $'\e' ]]; then  # ESC
        IFS= read -rsn1 -t 0.05 seq || true
        if [[ "$seq" == "[" ]]; then
            IFS= read -rsn1 -t 0.05 param || true
            case "$param" in
                A) printf 'UP' ;;
                B) printf 'DOWN' ;;
                # ...
            esac
        fi
    fi
    printf '%s' "$c"
}
```

#### Function Keys (F1-F12)

Not currently supported — would require additional CSI patterns:
```
F1:    \eOP
F2:    \eOQ
F3:    \eOR
F4:    \eOS
F5:    \e[15~
F6:    \e[17~
# ...
```

### Window Resize Handling

When the terminal is resized, the kernel sends `SIGWINCH`:

```bash
trap 'update_dimensions; draw_screen' WINCH
```

**Implementation**:
```bash
update_dimensions() {
    TERM_LINES=$(tput lines)
    TERM_COLS=$(tput cols)
}
```

Then immediately redraws the screen to fit the new size.

---

## Input Processing Pipeline

### Keystroke Reception

```bash
# Line 402: read_key()
read_key() {
    local c
    IFS= read -rsn1 c || true  # Read 1 byte, raw, silent
    # ... CSI decoding ...
    printf '%s' "$c"
}
```

### Numeric Prefix Handling

Some commands support numeric prefixes (e.g., `5j` = move down 5 lines):

```bash
read_count() {
    local c count=""
    while true; do
        IFS= read -rsn1 c || true
        case "$c" in
            [0-9])
                count+="$c"
                ;;
            *)
                # Not a digit — return count and queue char
                [[ -z "$count" ]] && count=1
                NEXT_KEY="$c"
                printf '%s' "$count"
                return
                ;;
        esac
    done
}
```

**Usage**:
```bash
d)  # Half page down
    OFFSET=$(( OFFSET + $(read_count) ))
    (( OFFSET >= vlen )) && OFFSET=$(( vlen - 1 ))
    ;;
u)  # Half page up
    OFFSET=$(( OFFSET - $(read_count) ))
    (( OFFSET < 0 )) && OFFSET=0
    ;;
y)  # Scroll up N lines
    OFFSET=$(( OFFSET - $(read_count) ))
    (( OFFSET < 0 )) && OFFSET=0
    ;;
```

### Prompt Input Loop

```bash
read_prompt() {
    local prompt="$1"
    local result="" c

    term_cup "$PAGE_LINES" 0
    printf '%s' "$TC_REV"
    term_el
    printf '%s' "$prompt"
    printf '%s' "$TC_SGR0"
    printf '%s' "$TC_CNORM"   # Show cursor

    while true; do
        IFS= read -rsn1 c || true
        case "$c" in
            '')  # Enter
                break
                ;;
            $'\x7f'|$'\b')  # Backspace / DEL
                if [[ -n "$result" ]]; then
                    result="${result%?}"
                    printf '\b \b'  # Move back, erase, move back
                fi
                ;;
            $'\e')  # Escape — cancel
                result=""
                break
                ;;
            *)
                result+="$c"
                printf '%s' "$c"  # Echo input
                ;;
        esac
    done

    printf '%s' "$TC_CIVIS"   # Re-hide cursor
    printf '%s' "$result" >&2  # Output to stderr
}
```

---

## File Management Architecture

### File Ring

```bash
declare -a  FILE_NAMES=()
declare -a  FILE_OFFSETS=()
declare -i  FILE_IDX=0
declare -i  FILE_COUNT=0
```

### Operations

#### Switch File

```bash
switch_file() {
    local -i idx="$1"
    if (( idx < 0 || idx >= FILE_COUNT )); then
        set_message "No such file"
        return 1
    fi
    save_offset              # Save current offset
    FILE_IDX=$idx
    load_file "${FILE_NAMES[$FILE_IDX]}"
    OFFSET=${FILE_OFFSETS[$FILE_IDX]:-0}  # Restore
    return 0
}
```

#### Next/Prev File

```bash
next_file() {
    if (( FILE_IDX + 1 >= FILE_COUNT )); then
        set_message "(last file)"
        return 1
    fi
    switch_file $(( FILE_IDX + 1 ))
}

prev_file() {
    if (( FILE_IDX <= 0 )); then
        set_message "(first file)"
        return 1
    fi
    switch_file $(( FILE_IDX - 1 ))
}
```

#### Command Mode File Operations

```bash
do_command() {
    case "$cmd" in
        n|next)
            next_file
            ;;
        p|prev)
            prev_file
            ;;
        e\ *)
            cmd_open_file "${cmd#e }"
            ;;
        d)
            cmd_remove_file
            ;;
        x\ *)
            cmd_examine "${cmd#x }"
            ;;
        x)
            cmd_examine "1"
            ;;
        f|'=')
            cmd_file_info
            ;;
    esac
}
```

### File Ring Traversal

```bash
# User presses :n multiple times
File 0 → File 1 → File 2 → File 0 (wrap)

# Command: :x 2
Examine file at index 2 (0-based)
```

---

## View Abstraction Layer

### Problem Statement

When a filter is active:
- Display shows only matching lines
- Navigation should work in terms of visible lines
- Line numbers should map to original buffer

### Solution

All file access goes through `view_*()` functions:

```bash
view_len() {
    if (( FILTER_ACTIVE )); then
        printf '%d' "${#FILTER_IDX[@]}"
    else
        printf '%d' "$BUFFER_LEN"
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

view_real_lineno() {
    local -i vi=$1
    if (( FILTER_ACTIVE )); then
        if (( vi >= 0 && vi < ${#FILTER_IDX[@]} )); then
            printf '%d' $(( FILTER_IDX[vi] + 1 ))
        else
            printf '%d' 0
        fi
    else
        printf '%d' $(( vi + 1 ))
    fi
}
```

### Benefits

1. **Separation of concerns**: Display code doesn't know about filter state
2. **Consistency**: Navigation works identically with or without filter
3. **Correctness**: Line numbers always map to original buffer

### Example

```
Buffer: [0: "line 1", 1: "error here", 2: "line 3", 3: "error again"]
FILTER_PATTERN="error"
FILTER_IDX=[1, 3]
FILTER_ACTIVE=1

view_len() → 2 (two matching lines)
view_line(0) → "error here" (BUFFER[FILTER_IDX[0]])
view_line(1) → "error again" (BUFFER[FILTER_IDX[1]])
view_real_lineno(0) → 2 (1-based, BUFFER[1])
view_real_lineno(1) → 4 (1-based, BUFFER[3])
```

---

## Binary Detection Algorithm

### The Problem

BASH's `$()` strips NUL bytes:
```bash
sample=$(printf '\x00\x00\x00'; printf X)  # Variable is empty!
```

But `dd` counts all bytes correctly:
```bash
dd if=file bs=1 count=3 2>&1 | grep bytes
# "3 bytes copied"
```

### The Technique

1. Use `dd` to get actual byte count
2. Read same bytes into variable with sentinel
3. Compare lengths

```bash
detect_binary() {
    local file="$1"
    [[ "$file" == "(stdin)" || ! -f "$file" ]] && return 1

    # Step 1: Get actual byte count from dd stderr
    local dd_stderr
    dd_stderr=$(dd if="$file" of=/dev/null bs=512 count=1 2>&1)

    local -i actual_bytes=0 prev=""
    for word in $dd_stderr; do
        if [[ "$word" == bytes* && "$prev" =~ ^[0-9]+$ ]]; then
            actual_bytes=$prev
            break
        fi
        prev="$word"
    done

    (( actual_bytes == 0 )) && return 1  # Couldn't parse

    # Step 2: Read with sentinel to preserve trailing newlines
    local sample
    sample=$(dd if="$file" bs=512 count=1 2>/dev/null; printf X)
    sample="${sample%X}"  # Remove sentinel

    # Step 3: Compare
    if (( ${#sample} < actual_bytes )); then
        return 0  # Binary (NULs were stripped)
    fi
    return 1      # Text
}
```

### Why the Sentinel?

Bash strips both NULs AND trailing newlines from `$()`. The sentinel `printf X` ensures newlines are preserved (since `X` comes after them), so length differences are only due to NUL stripping.

**Example**:
```
File: "\x00\x00\n\n" (4 bytes: 2 NULs + 2 newlines)

Without sentinel:
sample=$(dd ...; printf X)  # $sample = "" (NULs stripped, newlines stripped)
${#sample} = 0
actual_bytes = 4
0 < 4 → binary (correct)

With sentinel:
sample=$(dd ...; printf X)  # $sample = "X" (NULs stripped, newlines preserved, then X)
sample="${sample%X}"  # $sample = ""
${#sample} = 0
actual_bytes = 4
0 < 4 → binary (correct)
```

---

## State Management

### Global Variables

```bash
# File ring
declare -a  FILE_NAMES=()
declare -a  FILE_OFFSETS=()
declare -i  FILE_IDX=0
declare -i  FILE_COUNT=0

# Buffer
declare -a  BUFFER=()
declare -i  BUFFER_LEN=0
declare -i  OFFSET=0
declare -i  IS_BINARY=0

# Display
declare -i  TERM_LINES=24
declare -i  TERM_COLS=80
declare -i  PAGE_LINES=0
declare -i  LINE_NUMBERS=0

# Search
declare     SEARCH_PATTERN=""
declare -i  SEARCH_DIR=1

# Filter
declare     FILTER_PATTERN=""
declare -a  FILTER_IDX=()
declare -i  FILTER_ACTIVE=0

# Status
declare     MESSAGE=""
declare     NEXT_KEY=""
```

### State Transitions

```
┌────────────────────────────────────────┐
│  INITIALIZATION                        │
│  ┌──────────────────────────────────┐  │
│  │ main() calls term_init()         │  │
│  │ - Cache term caps                │  │
│  │ - Enter raw mode                 │  │
│  │ - Enter alt screen               │  │
│  └──────────────────────────────────┘  │
└────────────────────┬───────────────────┘
                     │
                     ▼
┌────────────────────────────────────────┐
│  EVENT LOOP                            │
│  ┌──────────────────────────────────┐  │
│  │ while true:                      │  │
│  │   draw_screen()                  │  │
│  │   key = read_key()               │  │
│  │   dispatch(key)                  │  │
│  └──────────────────────────────────┘  │
└────────────────────┬───────────────────┘
                     │
         ┌───────────┼───────────┐
         │           │           │
         ▼           ▼           ▼
    ┌──────┐    ┌──────┐    ┌──────┐
    │  q   │    │  h   │    │ /?nN │
    └──┬───┘    └──┬───┘    └──┬───┘
         │          │          │
         ▼          ▼          ▼
    ┌─────────┐  ┌─────────┐  ┌─────────┐
    │term_    │  │show_    │  │search_  │
    │cleanup()│  │help()   │  │filter() │
    │exit 0   │  │help_    │  │apply_   │
    │         │  │screen() │  │filter() │
    └─────────┘  └─────────┘  └─────────┘
```

### State Consistency

Key invariant: `FILTER_IDX` must always match `FILTER_PATTERN`:

```bash
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

**Called on**:
- Filter pattern change: `do_filter()`
- File load: `load_file()`

---

## Summary

ddpager's design emphasizes:
1. **Minimal dependencies**: Only `bash`, `dd`, `tput`
2. **State isolation**: Clear separation between terminal, input, state, display
3. **View abstraction**: Filter mode is transparent to navigation
4. **Creative heuristics**: Binary detection without external tools
5. **Graceful degradation**: Missing `tput` capabilities use empty strings

This makes it suitable for minimal/maintenance environments where only core POSIX tools are available.
