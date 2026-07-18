#!/usr/bin/env bash
# ================================================================
# ddpager — A less-like pager using BASH builtins, dd, and tput
#
# Constraints: BASH 4+ builtins, dd, tput. No sed, awk, grep,
#              less, more, cat, or other text-processing externals.
#              socat available for optional readline integration.
#
# Features:    Forward/backward scroll, search with highlighting,
#              filter (& command), multiple file ring, : commands,
#              status line, help screen, binary file detection.
#
# Usage:       ddpager [file ...]
#              command | ddpager
# ================================================================
set -uo pipefail

readonly DDPAGER_VERSION="0.1.0"

# ================================================================
# Terminal Control — tput + stty for raw mode
# ================================================================

declare -i TERM_LINES=24 TERM_COLS=80
declare    SAVED_STTY=""

# Cached tput sequences — query once, reuse as raw escapes
declare    TC_CLEAR="" TC_CIVIS="" TC_CNORM=""
declare    TC_SMCUP="" TC_RMCUP=""
declare    TC_SGR0="" TC_BOLD="" TC_REV="" TC_DIM=""
declare    TC_EL=""

cache_termcaps() {
    TC_CLEAR=$(tput clear)
    TC_CIVIS=$(tput civis 2>/dev/null || true)
    TC_CNORM=$(tput cnorm 2>/dev/null || true)
    TC_SMCUP=$(tput smcup 2>/dev/null || true)
    TC_RMCUP=$(tput rmcup 2>/dev/null || true)
    TC_SGR0=$(tput sgr0)
    TC_BOLD=$(tput bold)
    TC_REV=$(tput rev)
    TC_DIM=$(tput dim 2>/dev/null || true)
    TC_EL=$(tput el)
}

term_init() {
    cache_termcaps
    SAVED_STTY=$(stty -g)
    stty -echo -icanon raw min 1 time 0
    update_dimensions
    printf '%s' "$TC_SMCUP"   # alternate screen buffer
    printf '%s' "$TC_CIVIS"   # hide cursor
}

term_cleanup() {
    printf '%s' "$TC_CNORM"   # restore cursor
    printf '%s' "$TC_RMCUP"   # leave alternate screen
    [[ -n "$SAVED_STTY" ]] && stty "$SAVED_STTY"
}

term_cup()  { tput cup "$1" "$2"; }
term_el()   { printf '%s' "$TC_EL"; }

update_dimensions() {
    TERM_LINES=$(tput lines)
    TERM_COLS=$(tput cols)
}

# ================================================================
# State
# ================================================================

# --- File ring ---
declare -a  FILE_NAMES=()
declare -a  FILE_OFFSETS=()
declare -i  FILE_IDX=0
declare -i  FILE_COUNT=0

# --- Current buffer ---
declare -a  BUFFER=()
declare -i  BUFFER_LEN=0
declare -i  OFFSET=0          # top-of-screen view index
declare -i  IS_BINARY=0

# --- Display ---
declare -i  PAGE_LINES=0      # TERM_LINES - 1 (status line)
declare -i  LINE_NUMBERS=0    # toggle with -N

# --- Search ---
declare     SEARCH_PATTERN=""
declare -i  SEARCH_DIR=1      # 1=forward, -1=backward

# --- Filter ---
declare     FILTER_PATTERN=""
declare -a  FILTER_IDX=()     # indices into BUFFER matching filter
declare -i  FILTER_ACTIVE=0

 # --- Status message (one-shot) ---
 declare     MESSAGE=""
 declare     NEXT_KEY=""       # Queue for pending keystrokes

 set_message() { MESSAGE="$1"; }

# ================================================================
# File Management
# ================================================================

# Sniff first 512 bytes with dd to detect binary content.
# Technique: bash command substitution silently strips NUL bytes.
# So we read the sample into a bash variable AND parse dd's stderr
# for the actual byte count. If the variable is shorter, NULs were
# present → binary file.  Zero external tools beyond dd.
detect_binary() {
    local file="$1"
    [[ "$file" == "(stdin)" || ! -f "$file" ]] && return 1

    # Step 1: get actual byte count from dd's stderr report.
    # dd prints lines like:  "512 bytes (512 B) copied, ..."
    # or on BSD:              "512 bytes transferred in ..."
    local dd_stderr
    dd_stderr=$(dd if="$file" of=/dev/null bs=512 count=1 2>&1)

    local -i actual_bytes=0
    local prev="" word
    for word in $dd_stderr; do
        if [[ "$word" == bytes* && "$prev" =~ ^[0-9]+$ ]]; then
            actual_bytes=$prev
            break
        fi
        prev="$word"
    done

    (( actual_bytes == 0 )) && return 1   # couldn't parse, assume text

    # Step 2: read the same bytes into a bash variable.
    # Bash strips NUL bytes AND trailing newlines from $().
    # Sentinel trick: append 'X' inside the subshell so that trailing
    # newlines are preserved; then strip the sentinel. Only NULs will
    # cause a length mismatch.
    local sample
    sample=$(dd if="$file" bs=512 count=1 2>/dev/null; printf X)
    sample="${sample%X}"

    # Step 3: compare — if shorter, NULs were stripped → binary
    if (( ${#sample} < actual_bytes )); then
        return 0   # binary
    fi
    return 1       # text
}

load_file() {
    local file="$1"
    BUFFER=()
    IS_BINARY=0

    if [[ "$file" == "(stdin)" ]]; then
        # Buffer was already loaded before term_init
        :
    elif [[ "$file" == "-" ]]; then
        mapfile -t BUFFER
        BUFFER_LEN=${#BUFFER[@]}
    else
        # Binary check via dd
        if detect_binary "$file"; then
            IS_BINARY=1
            set_message "WARNING: binary file detected — display may be garbled"
        fi
        mapfile -t BUFFER < "$file"
    fi

    BUFFER_LEN=${#BUFFER[@]}
    OFFSET=0
    apply_filter
}

save_offset() {
    FILE_OFFSETS[$FILE_IDX]=$OFFSET
}

switch_file() {
    local -i idx="$1"
    if (( idx < 0 || idx >= FILE_COUNT )); then
        set_message "No such file"
        return 1
    fi
    save_offset
    FILE_IDX=$idx
    load_file "${FILE_NAMES[$FILE_IDX]}"
    OFFSET=${FILE_OFFSETS[$FILE_IDX]:-0}
    return 0
}

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

# ================================================================
# View Abstraction — filter-aware accessors
#
# All navigation and display goes through view_*() so that
# filter mode is transparent to the rest of the code.
# ================================================================

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

# Map view index → real buffer line number (1-based, for display)
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

# ================================================================
# Display Engine
# ================================================================

# Print a line with search-pattern highlighting.
# Handles all occurrences on the line. Truncates to $TERM_COLS
# visible characters (approximate — doesn't account for wide chars).
print_highlighted_line() {
    local line="$1" maxw="$2"

    # Truncate to visible width first (before adding escapes)
    line="${line:0:$maxw}"

    if [[ -z "$SEARCH_PATTERN" || "$line" != *"$SEARCH_PATTERN"* ]]; then
        printf '%s' "$line"
        return
    fi

    # Walk the line, highlighting each match
    local remaining="$line"
    while [[ "$remaining" == *"$SEARCH_PATTERN"* ]]; do
        local before="${remaining%%"$SEARCH_PATTERN"*}"
        printf '%s' "$before"
        printf '%s' "$TC_REV"
        printf '%s' "$SEARCH_PATTERN"
        printf '%s' "$TC_SGR0"
        remaining="${remaining#*"$SEARCH_PATTERN"}"
    done
    printf '%s' "$remaining"
}

draw_screen() {
    local -i vlen
    vlen=$(view_len)
    PAGE_LINES=$(( TERM_LINES - 1 ))

    # Clamp offset
    if (( vlen <= PAGE_LINES )); then
        OFFSET=0
    elif (( OFFSET > vlen - PAGE_LINES )); then
        OFFSET=$(( vlen - PAGE_LINES ))
    fi
    (( OFFSET < 0 )) && OFFSET=0

    local -i i vi
    local line
    local -i gutter=0

    # If line numbers are on, compute gutter width
    if (( LINE_NUMBERS )); then
        local -i max_ln
        if (( FILTER_ACTIVE )); then
            max_ln=$BUFFER_LEN
        else
            max_ln=$BUFFER_LEN
        fi
        gutter=$(( ${#max_ln} + 1 ))  # digits + space
    fi

    local -i content_width=$(( TERM_COLS - gutter ))
    (( content_width < 1 )) && content_width=1

    for (( i = 0; i < PAGE_LINES; i++ )); do
        vi=$(( OFFSET + i ))
        term_cup "$i" 0
        term_el

        if (( vi < vlen )); then
            # Line number gutter (matches less: number + space)
            if (( LINE_NUMBERS )); then
                local -i real_ln
                real_ln=$(view_real_lineno "$vi")
                printf '%s' "$TC_DIM"
                printf "%${gutter}d " "$real_ln"
                printf '%s' "$TC_SGR0"
            fi

            line=$(view_line "$vi")
            print_highlighted_line "$line" "$content_width"
        else
            # Below end-of-file: tilde marker
            printf '%s~%s' "$TC_DIM" "$TC_SGR0"
        fi
    done

    draw_status_line
}

draw_status_line() {
    local -i vlen
    vlen=$(view_len)
    PAGE_LINES=$(( TERM_LINES - 1 ))

    term_cup "$PAGE_LINES" 0
    printf '%s' "$TC_REV"
    term_el

    if [[ -n "$MESSAGE" ]]; then
        printf ' %.'"$(( TERM_COLS - 1 ))"'s' "$MESSAGE"
        MESSAGE=""
    else
        local fname="${FILE_NAMES[$FILE_IDX]}"
        local pct file_info filter_info

        if (( vlen == 0 )); then
            pct="(empty)"
        elif (( OFFSET + PAGE_LINES >= vlen )); then
            pct="(END)"
        elif (( OFFSET == 0 )); then
            pct="(TOP)"
        else
            pct="$(( (OFFSET + PAGE_LINES) * 100 / vlen ))%"
        fi

        file_info=""
        (( FILE_COUNT > 1 )) && file_info=" (file $(( FILE_IDX + 1 )) of ${FILE_COUNT})"

        filter_info=""
        (( FILTER_ACTIVE )) && filter_info=" &${FILTER_PATTERN} [${#FILTER_IDX[@]} hits]"

        local status
        printf -v status " %s%s  line %d/%d  %s%s" \
            "$fname" "$file_info" \
            "$(( OFFSET + 1 ))" "$vlen" \
            "$pct" "$filter_info"
        printf '%.'"${TERM_COLS}"'s' "$status"
    fi

    printf '%s' "$TC_SGR0"
}

# ================================================================
# Input — keystroke reader with CSI sequence decoding
# ================================================================

read_key() {
    local c
    IFS= read -rsn1 c || true

    # Enter sends empty string (newline is read's delimiter)
    if [[ -z "$c" ]]; then
        printf 'ENTER'
        return
    fi

    # Escape — start of CSI sequence
    if [[ "$c" == $'\e' ]]; then
        local seq=""
        IFS= read -rsn1 -t 0.05 seq || true
        if [[ "$seq" == "[" ]]; then
            local param=""
            IFS= read -rsn1 -t 0.05 param || true
            case "$param" in
                A) printf 'UP';   return ;;
                B) printf 'DOWN'; return ;;
                C) printf 'RIGHT'; return ;;
                D) printf 'LEFT'; return ;;
                H) printf 'HOME'; return ;;
                F) printf 'END';  return ;;
                5) IFS= read -rsn1 -t 0.05 _ || true
                   printf 'PGUP'; return ;;
                6) IFS= read -rsn1 -t 0.05 _ || true
                   printf 'PGDN'; return ;;
                [0-9])
                    # Extended sequences like \e[1~ (Home), \e[4~ (End)
                    local rest=""
                    IFS= read -rsn1 -t 0.05 rest || true
                    case "${param}${rest}" in
                        "1~") printf 'HOME'; return ;;
                        "4~") printf 'END';  return ;;
                    esac
                    ;;
            esac
        fi
        printf 'ESC'
        return
    fi

     printf '%s' "$c"
}

# Draw a pending numeric-prefix indicator in the status line.
# Called as the user types digits like 10j / 25G.
show_pending_count() {
    local count_str="$1"
    PAGE_LINES=$(( TERM_LINES - 1 ))
    term_cup "$PAGE_LINES" 0
    printf '%s' "$TC_REV"
    term_el
    printf ' :%s' "$count_str"
    printf '%s' "$TC_SGR0"
}

# Read a visible line from the user (for search prompts, : commands).
# Shows the prompt at the status-line position. Returns the typed
# string on stdout. ESC cancels (returns empty).
read_prompt() {
    local prompt="$1"
    local result="" c

    PAGE_LINES=$(( TERM_LINES - 1 ))
    term_cup "$PAGE_LINES" 0
    printf '%s' "$TC_REV"
    term_el
    printf '%s' "$prompt"
    printf '%s' "$TC_SGR0"
    printf '%s' "$TC_CNORM"   # show cursor for typing

    while true; do
        IFS= read -rsn1 c || true
        case "$c" in
            '')  # Enter
                break
                ;;
            $'\x7f'|$'\b')  # Backspace / DEL
                if [[ -n "$result" ]]; then
                    result="${result%?}"
                    printf '\b \b'
                fi
                ;;
            $'\e')  # Escape — cancel
                result=""
                break
                ;;
            *)
                result+="$c"
                printf '%s' "$c"
                ;;
        esac
    done

    printf '%s' "$TC_CIVIS"   # re-hide cursor
    printf '%s' "$result" >&2
}

# ================================================================
# Search
# ================================================================

search_forward() {
    local pattern="$1"
    local -i vlen start i
    vlen=$(view_len)
    start=$(( OFFSET + 1 ))

    for (( i = start; i < vlen; i++ )); do
        if [[ "$(view_line "$i")" == *"$pattern"* ]]; then
            OFFSET=$i
            return 0
        fi
    done

    # Wrap
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

search_backward() {
    local pattern="$1"
    local -i vlen start i
    vlen=$(view_len)
    start=$(( OFFSET - 1 ))

    for (( i = start; i >= 0; i-- )); do
        if [[ "$(view_line "$i")" == *"$pattern"* ]]; then
            OFFSET=$i
            return 0
        fi
    done

    # Wrap
    for (( i = vlen - 1; i > start; i-- )); do
        if [[ "$(view_line "$i")" == *"$pattern"* ]]; then
            OFFSET=$i
            set_message "search hit BOTTOM, continuing at TOP"
            return 0
        fi
    done

    set_message "Pattern not found: ${pattern}"
    return 1
}

do_search() {
    local -i dir=$1   # 1=forward, -1=backward
    local prompt
    (( dir > 0 )) && prompt="/" || prompt="?"

    local pattern=""
    local c
    local -i vlen
    vlen=$(view_len)
    PAGE_LINES=$(( TERM_LINES - 1 ))
    
    # Show prompt at status line
    term_cup "$PAGE_LINES" 0
    printf '%s' "$TC_REV"
    term_el
    printf '%s' "$prompt"
    printf '%s' "$TC_SGR0"
    printf '%s' "$TC_CNORM"   # show cursor
    
    # Read pattern
    while true; do
        IFS= read -rsn1 c || true
        case "$c" in
            '')  # Enter - end of input
                break
                ;;
            $'\x7f'|$'\b')  # Backspace / DEL
                if [[ -n "$pattern" ]]; then
                    pattern="${pattern%?}"
                    printf '\b \b'
                fi
                ;;
            $'\e')  # Escape - cancel
                pattern=""
                break
                ;;
            *)
                pattern+="$c"
                printf '%s' "$c"
                ;;
        esac
    done
    
    printf '%s' "$TC_CIVIS"   # re-hide cursor

    # Empty input → reuse previous pattern
    [[ -z "$pattern" ]] && pattern="$SEARCH_PATTERN"

    if [[ -z "$pattern" ]]; then
        set_message "No search pattern"
        return 1
    fi

    SEARCH_PATTERN="$pattern"
    SEARCH_DIR=$dir

    if (( dir > 0 )); then
        search_forward "$pattern"
    else
        search_backward "$pattern"
    fi
}

repeat_search() {
    local -i dir=$1   # 1=same direction, -1=reverse
    if [[ -z "$SEARCH_PATTERN" ]]; then
        set_message "No previous search"
        return 1
    fi

    local -i effective=$(( SEARCH_DIR * dir ))
    if (( effective > 0 )); then
        search_forward "$SEARCH_PATTERN"
    else
        search_backward "$SEARCH_PATTERN"
    fi
}

# ================================================================
# Filter (less's & command)
# ================================================================

do_filter() {
    local pattern=""
    local c
    local -i vlen
    vlen=$(view_len)
    PAGE_LINES=$(( TERM_LINES - 1 ))
    
    # Show prompt at status line
    term_cup "$PAGE_LINES" 0
    printf '%s' "$TC_REV"
    term_el
    printf '&'
    printf '%s' "$TC_SGR0"
    printf '%s' "$TC_CNORM"   # show cursor
    
    # Read pattern
    while true; do
        IFS= read -rsn1 c || true
        case "$c" in
            '')  # Enter - end of input
                break
                ;;
            $'\x7f'|$'\b')  # Backspace / DEL
                if [[ -n "$pattern" ]]; then
                    pattern="${pattern%?}"
                    printf '\b \b'
                fi
                ;;
            $'\e')  # Escape - cancel
                pattern=""
                break
                ;;
            *)
                pattern+="$c"
                printf '%s' "$c"
                ;;
        esac
    done
    
    printf '%s' "$TC_CIVIS"   # re-hide cursor

    FILTER_PATTERN="$pattern"
    OFFSET=0
    apply_filter

    if [[ -z "$pattern" ]]; then
        set_message "Filter removed"
    else
        set_message "${#FILTER_IDX[@]} matching lines"
    fi
}

# ================================================================
# : Command Mode
# ================================================================

do_command() {
    local cmd=""
    local c
    local -i vlen
    vlen=$(view_len)
    PAGE_LINES=$(( TERM_LINES - 1 ))
    
    # Show command prompt at status line
    term_cup "$PAGE_LINES" 0
    printf '%s' "$TC_REV"
    term_el
    printf ':'
    printf '%s' "$TC_SGR0"
    printf '%s' "$TC_CNORM"   # show cursor
    
    # Read command line
    while true; do
        IFS= read -rsn1 c || true
        case "$c" in
            '')  # Enter - end of command
                break
                ;;
            $'\x7f'|$'\b')  # Backspace / DEL
                if [[ -n "$cmd" ]]; then
                    cmd="${cmd%?}"
                    printf '\b \b'
                fi
                ;;
            $'\e')  # Escape - cancel
                cmd=""
                break
                ;;
            *)
                cmd+="$c"
                printf '%s' "$c"
                ;;
        esac
    done
    
    printf '%s' "$TC_CIVIS"   # re-hide cursor
    
    [[ -z "$cmd" ]] && return 0
    
    # Strip leading/trailing whitespace
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    cmd="${cmd%"${cmd##*[![:space:]]}"}"

    case "$cmd" in
        q|quit|q!)
            do_quit
            ;;
        n|next)
            next_file
            ;;
        p|prev)
            prev_file
            ;;
        x\ *)
            cmd_examine "${cmd#x }"
            ;;
        x)
            cmd_examine "1"
            ;;
        e\ *)
            cmd_open_file "${cmd#e }"
            ;;
        e)
            set_message "Usage: :e <filename>"
            ;;
        d)
            cmd_remove_file
            ;;
        f)
            cmd_file_info
            ;;
        N)
            # Toggle line numbers
            (( LINE_NUMBERS = ! LINE_NUMBERS ))
            local state="ON"
            (( ! LINE_NUMBERS )) && state="OFF"
            set_message "Line numbers: ${state}"
            ;;
        /*)
            SEARCH_PATTERN="${cmd:1}"
            SEARCH_DIR=1
            search_forward "$SEARCH_PATTERN"
            ;;
        '?'*)
            SEARCH_PATTERN="${cmd:1}"
            SEARCH_DIR=-1
            search_backward "$SEARCH_PATTERN"
            ;;
        [0-9]*)
            cmd_goto_line "$cmd"
            ;;
        *)
            set_message "Unknown command: :${cmd}"
            ;;
    esac
}

cmd_open_file() {
    local fname="$1"
    # Trim leading whitespace
    fname="${fname#"${fname%%[![:space:]]*}"}"
    # Trim trailing whitespace
    fname="${fname%"${fname##*[![:space:]]}"}"

    if [[ ! -f "$fname" && ! -r "$fname" ]]; then
        set_message "File not found: ${fname}"
        return 1
    fi

    save_offset
    FILE_NAMES+=("$fname")
    FILE_OFFSETS+=(0)
    FILE_COUNT=${#FILE_NAMES[@]}
    FILE_IDX=$(( FILE_COUNT - 1 ))
    load_file "$fname"
    set_message "Opened: ${fname}"
}

cmd_remove_file() {
    if (( FILE_COUNT <= 1 )); then
        set_message "Cannot remove last file"
        return 1
    fi

    local -i i
    local -a new_names=() new_offsets=()
    for (( i = 0; i < FILE_COUNT; i++ )); do
        if (( i != FILE_IDX )); then
            new_names+=("${FILE_NAMES[$i]}")
            new_offsets+=("${FILE_OFFSETS[$i]}")
        fi
    done
    FILE_NAMES=("${new_names[@]}")
    FILE_OFFSETS=("${new_offsets[@]}")
    FILE_COUNT=${#FILE_NAMES[@]}
    (( FILE_IDX >= FILE_COUNT )) && FILE_IDX=$(( FILE_COUNT - 1 ))
    load_file "${FILE_NAMES[$FILE_IDX]}"
    OFFSET=${FILE_OFFSETS[$FILE_IDX]:-0}
}

cmd_file_info() {
    local fname="${FILE_NAMES[$FILE_IDX]}"
    local -i vlen
    vlen=$(view_len)
    local info
    printf -v info "%s: %d lines" "$fname" "$BUFFER_LEN"
    (( FILTER_ACTIVE )) && printf -v info "%s (%d shown)" "$info" "$vlen"
    (( FILE_COUNT > 1 )) && printf -v info "%s [file %d of %d]" "$info" \
        "$(( FILE_IDX + 1 ))" "$FILE_COUNT"
    set_message "$info"
}

cmd_examine() {
    local num="${1:-1}"
    
    # Validate that num is a number
    if [[ ! "$num" =~ ^[0-9]+$ ]]; then
        set_message "Not a number: ${num}"
        return 1
    fi
    
    # Convert to 0-based index and validate bounds
    local -i idx=$(( num - 1 ))
    if (( idx < 0 || idx >= FILE_COUNT )); then
        set_message "No such file: ${num}"
        return 1
    fi
    
    save_offset
    FILE_IDX=$idx
    load_file "${FILE_NAMES[$FILE_IDX]}"
    OFFSET=${FILE_OFFSETS[$FILE_IDX]:-0}
}

cmd_goto_line() {
    local num="$1"
    if [[ ! "$num" =~ ^[0-9]+$ ]]; then
        set_message "Not a number: ${num}"
        return 1
    fi
    local -i vlen target
    vlen=$(view_len)
    target=$(( num - 1 ))    # 1-based → 0-based
    (( target < 0 )) && target=0
    (( target >= vlen )) && target=$(( vlen - 1 ))
    (( target < 0 )) && target=0
    OFFSET=$target
}

# ================================================================
# Help Screen
# ================================================================

show_help() {
    local -a H=(
        ""
        "  ddpager ${DDPAGER_VERSION} — BASH/dd/tput pager"
        ""
         "  NAVIGATION   (most commands accept a numeric prefix)"
         "    Nj  Down  Enter    Forward N lines (default 1)"
         "    Nk  Up             Backward N lines (default 1)"
         "    Ny                 Backward N lines (default 1)"
         "    Nu                 Backward N lines (default half page)"
         "    N Space  Nf  PgDn  Forward N lines / one page if no count"
         "    Nb  PgUp           Backward N lines / one page if no count"
         "    Nd                 Forward N lines (default half page)"
         "    Ng  Home           Go to line N (default 1)"
         "    NG  End            Go to line N (default last)"
         "    Nn                 Repeat search N times (forward)"
         "    NN                 Repeat search N times (reverse)"
         "    r                  Repaint the screen"
         ""
         "    Example: 10j = 10 lines down, 25G = jump to line 25,"
         "             3n  = next 3 search matches."
        ""
        "  SEARCH"
        "    /pattern           Search forward"
        "    ?pattern           Search backward"
        "    n                  Next match (same direction)"
        "    N                  Next match (reverse direction)"
        ""
        "  FILTER"
        "    &pattern           Show only matching lines"
        "    & (empty)          Clear filter"
        ""
        "  FILES"
        "    :n                 Next file in ring"
        "    :p                 Previous file in ring"
        "    :e <file>          Open and append file to ring"
        "    :d                 Remove current file from ring"
        "    :x                 Examine first file in ring"
        "    :x N               Examine N-th file in ring"
        "    :f  or  =          Show file info"
        ""
        "  LIVE / EXTERNAL"
        "    F                  Follow file (tail -f); any key aborts"
        "    v                  Edit current file in \$VISUAL / \$EDITOR"
        "    ^G                 Show name, line range, bytes, percent"
        ""
        "  OTHER"
        "    :N                 Toggle line numbers"
        "    :<number>          Jump to line"
        "    h                  This help screen"
        "    q  :q              Quit"
        ""
        "  Press any key to return to the file..."
    )

    printf '%s' "$TC_CLEAR"
    local -i i
    for (( i = 0; i < ${#H[@]} && i < TERM_LINES; i++ )); do
        term_cup "$i" 0
        printf '%s' "${H[$i]}"
    done

    read_key > /dev/null
}

# ================================================================
# Follow Mode (F) — tail -f
# ================================================================

do_follow() {
    local fname="${FILE_NAMES[$FILE_IDX]}"
    if [[ "$fname" == "(stdin)" ]]; then
        set_message "Cannot follow stdin"
        return 1
    fi

    local -i vlen
    vlen=$(view_len)
    PAGE_LINES=$(( TERM_LINES - 1 ))
    OFFSET=$(( vlen - PAGE_LINES ))
    (( OFFSET < 0 )) && OFFSET=0

    while true; do
        draw_screen

        # Replace status line with follow indicator
        term_cup "$PAGE_LINES" 0
        printf '%s' "$TC_REV"
        term_el
        local follow_status
        printf -v follow_status " %s  Waiting for data... (press any key to abort)" "$fname"
        printf '%.'"${TERM_COLS}"'s' "$follow_status"
        printf '%s' "$TC_SGR0"

        local c
        if IFS= read -rsn1 -t 0.5 c 2>/dev/null; then
            set_message "Follow mode ended"
            return 0
        fi

        local -i prev_len=$BUFFER_LEN
        mapfile -t BUFFER < "$fname"
        BUFFER_LEN=${#BUFFER[@]}
        if (( BUFFER_LEN != prev_len )); then
            apply_filter
            vlen=$(view_len)
            OFFSET=$(( vlen - PAGE_LINES ))
            (( OFFSET < 0 )) && OFFSET=0
        fi
    done
}

# ================================================================
# External Editor (v)
# ================================================================

do_edit() {
    local fname="${FILE_NAMES[$FILE_IDX]}"
    if [[ "$fname" == "(stdin)" ]]; then
        set_message "Cannot edit stdin"
        return 1
    fi
    if [[ ! -w "$fname" ]]; then
        set_message "File not writable: ${fname}"
        return 1
    fi

    local editor="${VISUAL:-${EDITOR:-vi}}"
    local -a editor_argv=()
    read -ra editor_argv <<< "$editor"
    if (( ${#editor_argv[@]} == 0 )); then
        set_message "No editor configured (set EDITOR or VISUAL)"
        return 1
    fi

    local -i lineno
    if (( FILTER_ACTIVE )); then
        lineno=$(view_real_lineno "$OFFSET")
    else
        lineno=$(( OFFSET + 1 ))
    fi
    (( lineno < 1 )) && lineno=1

    # Leave pager UI: restore cursor, leave alt-screen, restore stty
    printf '%s' "$TC_CNORM"
    printf '%s' "$TC_RMCUP"
    [[ -n "$SAVED_STTY" ]] && stty "$SAVED_STTY"

    "${editor_argv[@]}" "+${lineno}" "$fname" || true

    # Re-enter pager UI
    stty -echo -icanon raw min 1 time 0
    update_dimensions
    printf '%s' "$TC_SMCUP"
    printf '%s' "$TC_CIVIS"

    load_file "$fname"
    OFFSET=$(( lineno - 1 ))
    (( OFFSET < 0 )) && OFFSET=0
    set_message "Reloaded after edit"
}

# ================================================================
# Extended File Info (Ctrl-G)
# ================================================================

cmd_file_info_full() {
    local fname="${FILE_NAMES[$FILE_IDX]}"
    local -i vlen
    vlen=$(view_len)
    PAGE_LINES=$(( TERM_LINES - 1 ))

    local -i bytes=0 i
    for (( i = 0; i < BUFFER_LEN; i++ )); do
        bytes=$(( bytes + ${#BUFFER[$i]} + 1 ))
    done

    local pct
    if (( vlen == 0 )); then
        pct="?"
    elif (( OFFSET + PAGE_LINES >= vlen )); then
        pct="100%"
    else
        pct="$(( (OFFSET + PAGE_LINES) * 100 / vlen ))%"
    fi

    local -i last_line=$(( OFFSET + PAGE_LINES ))
    (( last_line > vlen )) && last_line=$vlen

    local info
    printf -v info "%s  lines %d-%d/%d  bytes %d  %s" \
        "$fname" "$(( OFFSET + 1 ))" "$last_line" "$vlen" "$bytes" "$pct"
    (( FILE_COUNT > 1 )) && printf -v info "%s [file %d of %d]" "$info" \
        "$(( FILE_IDX + 1 ))" "$FILE_COUNT"
    set_message "$info"
}

# ================================================================
# Quit
# ================================================================

do_quit() {
    term_cleanup
    exit 0
}

# ================================================================
# Usage / Args
# ================================================================

usage() {
    printf 'Usage: ddpager [OPTIONS] [file ...]\n'
    printf '       command | ddpager\n\n'
    printf 'Options:\n'
    printf '  -N          Start with line numbers on\n'
    printf '  -h          Show this help\n'
    printf '  -v          Show version\n'
    exit 0
}

# ================================================================
# Main
# ================================================================

main() {
    # --- Parse options ---
    while [[ $# -gt 0 && "$1" == -* ]]; do
        case "$1" in
            -N)  LINE_NUMBERS=1; shift ;;
            -h)  usage ;;
            -v)  printf 'ddpager %s\n' "$DDPAGER_VERSION"; exit 0 ;;
            --)  shift; break ;;
            -*)  printf 'ddpager: unknown option: %s\n' "$1" >&2; exit 1 ;;
        esac
    done

    # --- Build file ring (clear arrays first) ---
    FILE_NAMES=()
    FILE_OFFSETS=()
    FILE_IDX=0
    FILE_COUNT=0

    if [[ $# -eq 0 ]]; then
        if [[ -t 0 ]]; then
            printf 'ddpager: missing filename (try "ddpager -h")\n' >&2
            exit 1
        fi
        # Reading from pipe/stdin — must slurp before entering raw mode
        mapfile -t BUFFER
        BUFFER_LEN=${#BUFFER[@]}
        FILE_NAMES=("(stdin)")
        FILE_OFFSETS=(0)
        FILE_COUNT=1
    else
        local arg
        for arg in "$@"; do
            if [[ ! -f "$arg" ]]; then
                printf 'ddpager: %s: No such file\n' "$arg" >&2
                continue
            fi
            FILE_NAMES+=("$arg")
            FILE_OFFSETS+=(0)
        done
        FILE_COUNT=${#FILE_NAMES[@]}
        if (( FILE_COUNT == 0 )); then
            printf 'ddpager: no valid files\n' >&2
            exit 1
        fi
    fi

    # --- Load first file (skip if stdin already loaded) ---
    if [[ "${FILE_NAMES[0]}" != "(stdin)" ]]; then
        load_file "${FILE_NAMES[0]}"
    else
        apply_filter
    fi

    # --- Terminal setup ---
    term_init
    trap 'term_cleanup' EXIT
    trap 'update_dimensions; draw_screen' WINCH

    # Multi-file opening message
    if (( FILE_COUNT > 1 )); then
        set_message "Opened ${FILE_COUNT} files — :n/:p to navigate"
    fi

     # --- Event loop ---
     while true; do
         draw_screen

         local key
         if [[ -n "$NEXT_KEY" ]]; then
             key="$NEXT_KEY"
             NEXT_KEY=""
         else
             key=$(read_key)
         fi

         local -i vlen
         vlen=$(view_len)
         PAGE_LINES=$(( TERM_LINES - 1 ))

         # --- Numeric prefix (vi/less style: 10j, 25G, 3n, ...) ---
         # First digit must be 1-9 so bare "0" isn't consumed.
         local count_str=""
         if [[ "$key" =~ ^[1-9]$ ]]; then
             count_str="$key"
             show_pending_count "$count_str"
             while true; do
                 key=$(read_key)
                 if [[ "$key" =~ ^[0-9]$ ]]; then
                     count_str+="$key"
                     show_pending_count "$count_str"
                 else
                     break
                 fi
             done
         fi
         local -i has_count=0 cnt=1
         if [[ -n "$count_str" ]]; then
             has_count=1
             cnt=$((10#$count_str))
             (( cnt < 1 )) && cnt=1
         fi

        case "$key" in
            # --- Quit ---
            q)          do_quit ;;

            # --- Help ---
            h)          show_help ;;

            # --- Single-line navigation (counted) ---
            j|DOWN|ENTER)
                OFFSET=$(( OFFSET + cnt ))
                if (( OFFSET + PAGE_LINES > vlen )); then
                    OFFSET=$(( vlen - PAGE_LINES ))
                fi
                (( OFFSET < 0 )) && OFFSET=0
                ;;
            k|UP)
                OFFSET=$(( OFFSET - cnt ))
                (( OFFSET < 0 )) && OFFSET=0
                ;;

            # --- Page / counted navigation ---
            ' '|f|PGDN)
                if (( has_count )); then
                    OFFSET=$(( OFFSET + cnt ))
                else
                    OFFSET=$(( OFFSET + PAGE_LINES ))
                fi
                ;;
            b|PGUP)
                if (( has_count )); then
                    OFFSET=$(( OFFSET - cnt ))
                else
                    OFFSET=$(( OFFSET - PAGE_LINES ))
                fi
                (( OFFSET < 0 )) && OFFSET=0
                ;;

            # --- Half-page forwards (count overrides) ---
            d)
                if (( has_count )); then
                    OFFSET=$(( OFFSET + cnt ))
                else
                    OFFSET=$(( OFFSET + PAGE_LINES / 2 ))
                fi
                ;;

            # --- Half-page backwards (count overrides) ---
            u)
                if (( has_count )); then
                    OFFSET=$(( OFFSET - cnt ))
                else
                    OFFSET=$(( OFFSET - PAGE_LINES / 2 ))
                fi
                (( OFFSET < 0 )) && OFFSET=0
                ;;

            # --- Counted backward scroll ---
            y)
                OFFSET=$(( OFFSET - cnt ))
                (( OFFSET < 0 )) && OFFSET=0
                ;;

            # --- Top / goto (Ng = goto line N, g = first line) ---
            g|HOME)
                if (( has_count )); then
                    OFFSET=$(( cnt - 1 ))
                    (( OFFSET >= vlen )) && OFFSET=$(( vlen - 1 ))
                    (( OFFSET < 0 )) && OFFSET=0
                else
                    OFFSET=0
                fi
                ;;

            # --- Bottom / goto (NG = goto line N, G = last line) ---
            G|END)
                if (( has_count )); then
                    OFFSET=$(( cnt - 1 ))
                    (( OFFSET >= vlen )) && OFFSET=$(( vlen - 1 ))
                    (( OFFSET < 0 )) && OFFSET=0
                else
                    OFFSET=$(( vlen - PAGE_LINES ))
                    (( OFFSET < 0 )) && OFFSET=0
                fi
                ;;

            # --- Search ---
            /)      do_search 1  || true ;;
            '?')    do_search -1 || true ;;

            # --- Search repeat (counted: 3n = next 3 matches) ---
            n)
                local -i r
                for (( r = 0; r < cnt; r++ )); do
                    repeat_search 1 || break
                done
                ;;
            N)
                local -i r2
                for (( r2 = 0; r2 < cnt; r2++ )); do
                    repeat_search -1 || break
                done
                ;;

            # --- Repaint screen ---
            r)      continue ;;

            # --- Filter ---
            '&')    do_filter ;;

            # --- Command mode ---
            :)      do_command ;;

            # --- File info shortcut (matches less) ---
            =)      cmd_file_info ;;

            # --- Extended file info (Ctrl-G) ---
            $'\x07') cmd_file_info_full ;;

            # --- Follow mode (tail -f) ---
            F)      do_follow ;;

            # --- Edit current file in $EDITOR ---
            v)      do_edit ;;

            # --- Ignore everything else ---
            *)      ;;
        esac
    done
}

main "$@"
