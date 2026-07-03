#!/bin/sh
# demo-observe.sh — observe *running* processes through /proc, the last two of
# Ciro S. Costa's /proc series:
#   5. "Using /proc to get a process' current stack trace"
#        ../upstream-tutorial/using-procfs-to-get-process-stack-trace.html
#   6. "How Linux creates sockets and counts them"
#        ../upstream-tutorial/how-linux-creates-sockets.html
#
# Runs as the non-root `learner`. The unprivileged jewels work here: /proc/<pid>/
# wchan names the kernel function a blocked process sits in, and sockets are
# visible as socket:[inode] fds counted in sockstat. The privileged extras (the
# full /proc/<pid>/stack, gdb/gstack userspace backtrace, `ip netns`) need root /
# CAP_SYS_ADMIN / CAP_SYS_PTRACE — shown here failing, with the root commands in
# RUNBOOK.md / MANUAL_TESTING.md. Pure POSIX sh (dash + BusyBox ash).
cd "$(dirname "$0")" || exit 1
p() { printf '\n== %s ==\n' "$1"; }
CC="${CC:-gcc}"

########################  ARTICLE 5 — a process' stack  ########################

p 'ARTICLE 5 — a TCP server that BLOCKS in accept(); what is it doing?'
$CC -Wall -o accept accept.c
./accept & apid=$!
sleep 1
echo "   /proc/$apid/status — it is asleep:"
grep '^State' "/proc/$apid/status"

p 'ARTICLE 5 — /proc/<pid>/wchan: the KERNEL function it is parked in (unprivileged!)'
printf '   wchan = '; cat "/proc/$apid/wchan"; echo
echo '   → inet_csk_accept: it is blocked inside the kernel accept path. That one'
echo '     word is the top frame of the kernel stack, free to any user.'

p 'ARTICLE 5 — the FULL kernel stack (/proc/<pid>/stack) needs CAP_SYS_ADMIN'
printf '   cat /proc/%s/stack → ' "$apid"; cat "/proc/$apid/stack" 2>&1 | head -1
echo '   (blocked here; as root on a host it prints inet_csk_accept → …'
echo '    → __sys_accept4 → do_syscall_64. The USERSPACE stack — main → accept —'
echo '    comes from gdb/gstack, which also need root/CAP_SYS_PTRACE in this'
echo '    ptrace_scope=1 container. See RUNBOOK.md for the root commands.)'
kill "$apid" 2>/dev/null

########################  ARTICLE 6 — sockets  #################################

p 'ARTICLE 6 — socket() returns an fd that appears as socket:[inode]'
$CC -Wall -o socket socket.c
./socket 1 3600 & s1=$!
sleep 1
echo "   /proc/$s1/fd (fd 3 is the socket the program made):"
ls -l "/proc/$s1/fd" | grep 'socket:'
kill "$s1" 2>/dev/null

p 'ARTICLE 6 — the article''s 100-socket variant: watch /proc/<pid>/net/sockstat'
./socket 100 3600 & s2=$!
sleep 1
echo "   socket:[inode] fds held by pid $s2 (the 100 we opened):"
ls -l "/proc/$s2/fd" | grep -c 'socket:'
echo "   the kernel's own tally, /proc/$s2/net/sockstat:"
grep 'sockets: used' "/proc/$s2/net/sockstat"
kill "$s2" 2>/dev/null

p 'ARTICLE 6 — strace: the socket(2) syscall itself, returning a small fd'
strace -f -e trace=socket ./socket 1 0 2>&1 | grep 'socket(' | head -1

echo
echo '== done — read articles 5 & 6; `ip netns` + /proc/<pid>/stack want root =='
