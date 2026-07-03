#!/bin/sh
# demo.sh — a hands-on tour of Ciro S. Costa's two /proc articles (ops.tips):
#   1. "What is /proc?"                       ../upstream-tutorial/what-is-slash-proc.html
#   2. "How is /proc able to list process IDs?" ../upstream-tutorial/how-is-proc-able-to-list-pids.html
#
# It runs the pieces you can actually run in an unprivileged container: read a
# few synthesized /proc files, watch open()/getdents64 with strace, and compile
# + run the article's own two C programs. It also spotlights TWO things the
# articles describe but a *container* makes vividly concrete:
#   • /proc is virtual — files report size 0 and are generated on read;
#   • here /proc/meminfo & friends are served by lxcfs (a FUSE filesystem),
#     literally proving procfs content is *computed*, not stored on a disk.
#
# Pure POSIX sh so it runs the same under dash (Debian) and BusyBox ash (Alpine).
# The privileged bits from the articles (echo 3 >/proc/sys/vm/drop_caches, bcc
# trace.py / bpftrace funccount) need root+BPF and are NOT here — see RUNBOOK.md.
cd "$(dirname "$0")" || exit 1
p() { printf '\n== %s ==\n' "$1"; }
CC="${CC:-gcc}"

p 'ARTICLE 1 — /proc is virtual: files are generated on read, not stored'
echo '   ls reports size 0 for a kernel-native procfs file — nothing on disk:'
ls -l /proc/self/status
echo '   ...yet it is full of content the instant the kernel produces it on read:'
head -n 3 /proc/self/status

p 'ARTICLE 1 — a file descriptor is an index into a per-process table'
# Hold a file open in a background process, then read ITS /proc/<pid>/fd.
sleep 30 </etc/hostname & bg=$!
sleep 1
echo "   background pid $bg has these open fds (0/1/2 = stdin/stdout/stderr):"
ls -l "/proc/$bg/fd" 2>/dev/null
kill "$bg" 2>/dev/null

p "ARTICLE 1 — the C program (open-fd.c): open() returns the next free fd"
: > /tmp/file.txt
$CC -Wall -o open-fd open-fd.c && ./open-fd

p 'ARTICLE 1 — per-process limits, also synthesized on read (/proc/self/limits)'
grep -E 'Max open files|Max processes' /proc/self/limits

p 'ARTICLE 2 — ls /proc = openat(O_DIRECTORY) + getdents64 (see the syscalls)'
mkdir -p /tmp/ciro
echo '   strace of `ls /tmp/ciro`, filtered to the two syscalls that matter:'
# (GNU ls uses openat(); BusyBox ls uses the older open() — match the
#  O_DIRECTORY open by its flags, not the syscall name — see MANUAL_TESTING.md.)
strace -f -e trace=open,openat,getdents64,getdents ls /tmp/ciro 2>&1 \
	| grep -E 'open(at)?\(.*O_DIRECTORY|getdents' | head -n 4

p "ARTICLE 2 — the C program (list-pids.c): call getdents64 on /proc ourselves"
$CC -Wall -o list-pids list-pids.c && {
	echo '   numeric entries the kernel synthesized for us are PIDs:'
	./list-pids /proc | grep -E '^[0-9]+$' | sort -n | tr '\n' ' '
	echo
}

p 'GEM — those numbers ARE the live PIDs, listed straight from the /proc dir'
ls -d /proc/[0-9]* 2>/dev/null | sed 's:/proc/::' | sort -n | tr '\n' ' '; echo

p 'GEM — in THIS container /proc/meminfo is served by lxcfs (a FUSE fs)'
if grep -q 'lxcfs' /proc/mounts 2>/dev/null; then
	echo '   Some /proc files are not just computed by the kernel but *overridden*'
	echo '   by lxcfs to report the container’s cgroup limits — Ciro’s "generated'
	echo '   on read" thesis made physical (note: unlike a native procfs file,'
	echo '   these FUSE-backed files even advertise a real size):'
	grep 'lxcfs' /proc/mounts | grep -E 'meminfo|cpuinfo|uptime' | head -n 3
	ls -l /proc/meminfo
else
	echo '   (no lxcfs mount visible here — the size-0 point above still holds:'
	echo '    the kernel generates every byte of a /proc file when you read it.)'
fi

echo
echo '== done — now read the two articles and poke /proc yourself =='
