# ddpager Maintenance Guide

For system administrators managing ddpager in production or minimal environments.

---

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [System Requirements](#system-requirements)
3. [Installation](#installation)
4. [Debugging](#debugging)
5. [Common Issues](#common-issues)
6. [Performance Considerations](#performance-considerations)
7. [Security](#security)
8. [Upgrading](#upgrading)
9. [Backup and Recovery](#backup-and-recovery)

---

## Quick Reference

### Required Tools

| Tool | Purpose | Minimum Version |
|------|--------|-----------------|
| `bash` | Shell interpreter | 4.0+ |
| `dd` | Binary detection | Coreutils |
| `tput` | Terminal control | ncurses |
| `stty` | Terminal settings | POSIX |

### Optional Tools

| Tool | Purpose |
|------|--------|
| `socat` | Readline integration |
| `expect` | Testing automation |

### File Locations

```
/usr/local/bin/ddpager          # Primary installation
/etc/bash_completion.d/ddpager  # Completion (if installed)
```

---

## System Requirements

### Operating System

| Platform | Verified | Notes |
|----------|----------|-------|
| Linux | Yes | GNU coreutils |
| macOS | Yes | BSD dd format differs - handled gracefully |
| FreeBSD | Yes | Use `gdd` from ports if available |
| OpenBSD | Yes | Limited testing |
| Solaris | Partial | May need `gdd` |

**Note**: ddpager requires `tput` with `terminfo` database.

### BASH Version Check

```bash
bash --version | head -1
# Expected: GNU bash, version 4.x.x or higher

# Minimal required features:
# - mapfile builtin (4.0+)
# - declare -a (3.0+)
# - [[ =~ ]] regex (3.2+)
```

### Terminal Requirements

| Capability | Purpose | Fallback |
|------------|--------|----------|
| Alternate screen | `smcup`/`rmcup` | No alternate screen (stdio interference) |
| Cursor control | `civis`/`cnorm` | Cursor may be visible |
| Color attributes | `sgr0`/`bold`/`rev` | Monochrome display |

---

## Installation

### Source Installation

```bash
# Ensure dependencies are available
which bash dd tput stty

# Copy to destination
sudo cp ddpager.sh /usr/local/bin/ddpager

# Make executable
sudo chmod +x /usr/local/bin/ddpager

# Verify installation
which ddpager
ddpager -v
```

### Package Installation (Debian/Ubuntu)

```bash
# Create package structure
sudo mkdir -p /usr/local/src/ddpager
sudo cp ddpager.sh /usr/local/src/ddpager/

# Create symlink
sudo ln -sf /usr/local/src/ddpager/ddpager.sh /usr/local/bin/ddpager
```

### Package Installation (RHEL/CentOS)

```bash
# Similar to Debian
sudo mkdir -p /usr/local/bin
sudo cp ddpager.sh /usr/local/bin/ddpager
sudo chmod +x /usr/local/bin/ddpager
```

### Bash Completion

```bash
# Create completion file
cat > /etc/bash_completion.d/ddpager <<'EOF'
_ddpager_completion() {
    local cur prev words cword
    _get_comp_words_by_ref cur prev words cword

    if [[ $cword -ge 1 ]]; then
        COMPREPLY=( $(compgen -f -- "$cur") )
    fi
}

complete -F _ddpager_completion ddpager
EOF

# Source completion
echo "source /etc/bash_completion.d/ddpager" >> /etc/bash.bashrc
```

---

## Debugging

### Enable Debug Mode

```bash
# Add to script or run with
bash -x /usr/local/bin/ddpager file.txt

# Or add to script (line 16):
set -x  # After set -uo pipefail
```

### Log Terminal State

```bash
# Save current terminal state before running
stty -g > /tmp/stty_before.txt

# Run ddpager, then immediately press Ctrl+Z to suspend

# Restore terminal state
stty $(cat /tmp/stty_before.txt)

# Check what was saved
cat /tmp/stty_before.txt
```

### Verify tput Capabilities

```bash
# List all capabilities
tput -T xterm-256color capabilities

# Test individual capabilities
tput clear
tput civis
tput cnorm
tput smcup
tput rmcup
tput bold
tput rev

# Check terminfo database
infocmp $TERM
```

### File Descriptor Debug

```bash
# Check stdin is available
ls -l /proc/$$/fd/0

# Test with strace (if available)
strace -e read,write bash ddpager file.txt 2>&1 | head -50
```

---

## Common Issues

### Issue 1: Terminal Left in Broken State

**Symptoms**:
- No echo when typing
- Cursor hidden
- Screen not cleared properly

**Cause**: Script exited without running `term_cleanup()`

**Diagnosis**:
```bash
# Check if terminal is in raw mode
stty -a | grep -E "(raw|echo)"

# Check cursor visibility
tput cnorm  # Should show cursor
```

**Fix**:
```bash
# Restore terminal Immediately
reset

# Or manually
stty sane
echo -e '\e[?25h'  # Show cursor
clear
```

**Prevention**:
```bash
# Add trap to ensure cleanup even on errors
trap 'term_cleanup' EXIT ERR
```

---

### Issue 2: Arrow Keys Not Working

**Symptoms**:
- Arrow keys print `^[[A` instead of moving
- Navigation only works with `j`, `k`

**Cause**: Terminal doesn't send standard CSI sequences, or terminfo database missing

**Diagnosis**:
```bash
# Test if cursor keys send proper sequences
cat -v
# Press arrow keys - should show ^[OA, ^[OB, ^[OC, ^[OD

# Check terminfo
infocmp $TERM | grep -E "(kUP|kDN|kRIT|kLFT)"
```

**Fix**:
```bash
# Try different terminal type
TERM=xterm ddpager file.txt

# Or export terminfo path
export TERMINO=/usr/share/terminfo
```

---

### Issue 3: Binary File Warning

**Symptoms**:
```
WARNING: binary file detected — display may be garbled
```

**Cause**: File contains NUL bytes detected by `detect_binary()`

**Diagnosis**:
```bash
# Check for NUL bytes
cat file.txt | tr -d '\0' | wc -c
wc -c file.txt

# If different, file contains NUL bytes
```

**Resolution Options**:

1. **Display anyway** (may be garbled)
2. **Convert to text**:
   ```bash
   # Remove NUL bytes (destructive!)
   tr -d '\0' < file.txt > file.txt.sansnul
   ddpager file.txt.sansnul
   ```
3. **Use hex view**:
   ```bash
   hexdump -C file.txt | ddpager
   ```

---

### Issue 4: No Response to Input

**Symptoms**:
- Screen displays but doesn't respond to keystrokes
- Script hangs on first keypress

**Cause**: `stty raw` interferes with pipe input, or file is empty

**Diagnosis**:
```bash
# Check if file has content
wc -l file.txt
cat file.txt | head -5

# Test stdin is available
echo "test" | cat
```

**Fix**:
```bash
# Ensure file exists and is readable
ls -l file.txt
test -r file.txt && echo "Readable" || echo "Not readable"

# If piped, ensure data is being sent
echo "test" | ddpager  # works?
# vs
cat file.txt | ddpager  # hangs?
```

---

### Issue 5: Search Not Finding Matches

**Symptoms**:
- Type `/pattern` and press Enter
- "Pattern not found" even when text exists

**Cause**: Search is case-sensitive, pattern may have special characters

**Diagnosis**:
```bash
# Check case
grep "Pattern" file.txt  # may differ from "pattern"

# Test glob pattern in bash
if [[ "some text Pattern here" == *"Pattern"* ]]; then
    echo "Match"
fi
```

**Workarounds**:
```bash
# Convert file to lowercase first
tr 'A-Z' 'a-z' < file.txt | ddpager
```

---

### Issue 6: File Switching Not Working

**Symptoms**:
- `:n` or `:p` doesn't change files
- Multi-file ring doesn't work

**Cause**: Files don't exist, or file ring state corrupted

**Diagnosis**:
```bash
# Check files exist
ls -l file1.txt file2.txt

# Test in debug mode
bash -x ddpager file1.txt file2.txt
# Look for FILE_NAMES assignments
```

**Fix**:
```bash
# Verify files are readable
test -r file1.txt && echo "OK" || echo "Not readable"

# Try with absolute paths
ddpager /full/path/to/file1.txt /full/path/to/file2.txt
```

---

### Issue 7: High Memory Usage

**Symptoms**:
- Script uses 100% of available memory
- Large files cause system slowdown

**Cause**: Entire file loaded into `BUFFER[]` array

**Diagnosis**:
```bash
# Check memory usage
ps aux | grep ddpager

# Estimate memory per line
echo "Memory per character: ~1 byte"
echo "Memory per line: ~100 bytes average"
echo "100K line file: ~100 MB"
```

**Workarounds**:
```bash
# Use traditional less for large files
if [[ $(wc -c < file.txt) -gt 100000000 ]]; then
    less file.txt  # >100MB
else
    ddpager file.txt
fi

# Or page through file in chunks
split -l 1000 file.txt chunk_
ddpager chunk_a*
```

---

### Issue 8: Filter Shows Wrong Line Count

**Symptoms**:
- Filter shows `&pattern [0 hits]` but matches exist
- Filter shows incorrect count

**Cause**: Filter uses `*pattern*` matching, not anchors

**Diagnosis**:
```bash
# Test exact match
if [[ "text with pattern" == *"pattern"* ]]; then
    echo "Matches *pattern*"
fi

# Test anchored match
if [[ "pattern at start" =~ ^pattern ]]; then
    echo "Matches ^pattern"
fi
```

**Note**: ddpager uses glob-style matching, not regex. Patterns:
- `*pattern*` = contains
- `pattern*` = starts with
- `*pattern` = ends with

---

## Performance Considerations

### File Loading

```bash
# Linear time: O(n) where n = lines
mapfile -t BUFFER < "$file"

# Memory: O(n * avg_line_length)
# For 1M line file with 100 char lines: ~100 MB
```

### Search Performance

```bash
# Linear per search: O(n * pattern_length)
for (( i = 0; i < BUFFER_LEN; i++ )); do
    if [[ "${BUFFER[$i]}" == *"$pattern"* ]]; then
        # match
    fi
done
```

### Optimization Strategies

```bash
# 1. Pre-filter before calling ddpager
grep "ERROR" large.log | ddpager

# 2. Use traditional pager for large files
if [[ $(wc -l < large.log) -gt 10000 ]]; then
    less large.log
else
    ddpager large.log
fi

# 3. Limit line count
head -10000 large.log | ddpager
```

---

## Security

### Input Validation

ddpager validates inputs:
```bash
# File existence
if [[ ! -f "$file" && ! "$file" == "-" ]]; then
    printf 'ddpager: %s: No such file\n' "$file" >&2
fi

# Numeric validation
if [[ ! "$num" =~ ^[0-9]+$ ]]; then
    set_message "Not a number: ${num}"
fi
```

### Privilege Escalation Risks

1. **File reading**: Only reads text files, doesn't write
2. **Command execution**: No shell eval, no command injection
3. **Environment**: Uses `mapfile`, no `eval` calls

### Safe Usage Patterns

```bash
# ✅ Safe user-provided filenames
ddpager "$userfile"

# ❌ Dangerous user-provided commands
ddpager $(cat config)  # Command substitution could inject
```

---

## Upgrading

### Version Checking

```bash
# Check current version
ddpager -v

# Expected output: ddpager 0.1.0
```

### Upgrade Procedure

```bash
# 1. Backup current version
sudo cp /usr/local/bin/ddpager /usr/local/bin/ddpager.bak

# 2. Install new version
sudo cp ddpager.sh /usr/local/bin/ddpager
sudo chmod +x /usr/local/bin/ddpager

# 3. Verify
ddpager -v

# 4. Test with a file
ddpager /etc/passwd
```

### Rollback

```bash
# If upgrade fails:
sudo mv /usr/local/bin/ddpager.bak /usr/local/bin/ddpager
sudo chmod +x /usr/local/bin/ddpager
```

---

## Backup and Recovery

### Configuration Backup

ddpager uses no external config files, but you may want to backup:

```bash
# Backup script
sudo cp /usr/local/bin/ddpager /var/backups/ddpager/

# Backup version info
echo "ddpager 0.1.0" > /var/backups/ddpager/version.txt
```

### Recovery Steps

1. **Terminal is broken**:
   ```bash
   reset
   stty sane
   echo -e '\e[?25h'
   ```

2. **Script is corrupted**:
   ```bash
   # Reinstall from backup
   sudo cp /var/backups/ddpager/ddpager /usr/local/bin/ddpager
   sudo chmod +x /usr/local/bin/ddpager
   ```

3. **Need original source**:
   ```bash
   # Check git history if available
   cd /path/to/source
   git log --oneline
   git checkout HEAD~1 ddpager.sh
   ```

---

## Troubleshooting Checklist

### First Aid Sequence

```
Problem? → Check:               → Fix:
─────────────────────────────────────────────────────────────
No display?    1. tput works?    tput clear
               2. stty sane?     reset
               3. Screen isn't   clear

No input?      1. stty raw       stty -echo -icanon raw
               2. File exists?   ls -l file

Wrong file?    1. Files readable? test -r
               2. Absolute path? cd; ddpager file

Slow?          1. File size?     split -l or less
               2. Pipe instead?  grep | ddpager
```

### Debug Commands

```bash
# Check bash version
bash --version

# Check tput
tput cols
tput lines

# Check permissions
ls -l ddpager.sh
test -x ddpager.sh && echo "Executable" || echo "Not executable"

# Check dependencies
which bash dd tput stty
```

---

## Support Information

### Diagnostics Script

```bash
#!/bin/bash
# ddpager_diag.sh - Gather diagnostic info

echo "=== ddpager Diagnostic Report ==="
echo "Date: $(date)"
echo ""

echo "=== System ==="
uname -a
echo ""

echo "=== Bash ==="
bash --version | head -1
echo ""

echo "=== Dependencies ==="
for cmd in bash dd tput stty; do
    which $cmd
    $cmd --version 2>/dev/null | head -1 || true
done
echo ""

echo "=== Terminal ==="
echo "TERM: $TERM"
tput cols
tput lines
echo ""

echo "=== Script Info ==="
ls -l /usr/local/bin/ddpager 2>/dev/null || echo "Not installed"
/usr/local/bin/ddpager -v 2>/dev/null || echo "Script not executable"
echo ""

echo "=== Test Run ==="
echo "test line 1
test line 2" | /usr/local/bin/ddpager -h || echo "Test failed"
```

### When to Escalate

Escalate to sysadmin team if:
1. Terminal cannot be restored with `stty sane`
2. Core tools (`dd`, `tput`) are missing
3. Performance issues persist after optimization
4. Security concerns identified
