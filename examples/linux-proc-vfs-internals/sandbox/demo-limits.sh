#!/bin/sh
# demo-limits.sh — the cgroups + resource-limits half of Ciro S. Costa's /proc
# series, run inside a MEMORY-LIMITED container:
#   3. "Why top and free inside containers don't show the correct container memory"
#        ../upstream-tutorial/why-top-inside-container-wrong-memory.html
#   4. "Process resource limits under the hood"
#        ../upstream-tutorial/proc-pid-limits-under-the-hood.html
#
# This box was launched with a memory cap (limits.memory, swap off), so we can
# watch cgroups actually bite. Pure POSIX sh (dash + BusyBox ash). The privileged
# tracing from the articles (bpftrace on page_counter_try_charge / do_prlimit,
# bcc) needs root+BPF and is NOT here — see RUNBOOK.md.
cd "$(dirname "$0")" || exit 1
p() { printf '\n== %s ==\n' "$1"; }
CC="${CC:-gcc}"

p 'ARTICLE 3 — free reads /proc/meminfo; in a plain container that is the HOST view'
echo '   ...but Incus/LXD ships lxcfs, which overlays /proc/meminfo with the'
echo '   cgroup limit — so here free shows the CAP, not the host'"'"'s RAM:'
free -h 2>/dev/null || free
echo '   MemTotal straight from /proc/meminfo (lxcfs = the limit we set):'
grep MemTotal /proc/meminfo

p 'ARTICLE 3 — the cgroup that enforces it (modern kernels = cgroup v2 memory.max)'
# ⚠ DIVERGENCE: the 2018 article uses cgroup v1 (/sys/fs/cgroup/memory/…/
# memory.limit_in_bytes); today it is unified cgroup v2 (memory.max).
if [ -f /sys/fs/cgroup/memory.max ]; then
	echo "   cgroup v2:  /sys/fs/cgroup/memory.max = $(cat /sys/fs/cgroup/memory.max) bytes"
elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
	echo "   cgroup v1:  memory.limit_in_bytes = $(cat /sys/fs/cgroup/memory/memory.limit_in_bytes) bytes"
else
	echo '   (no memory cgroup file visible)'
fi

p 'ARTICLE 3 — free really does open /proc/meminfo (strace proof)'
strace -f -e trace=open,openat free 2>&1 | grep 'meminfo' | head -n 1

p 'ARTICLE 3 — the allocator (mem-hog.c): exceed the cap → the cgroup OOM-kills it'
$CC -Wall -o mem-hog mem-hog.c
echo '   asking for far more than the limit; the cgroup page_counter stops us:'
./mem-hog 100000
echo "   >>> mem-hog exit status: $?  (137 = 128 + SIGKILL(9) = OOM-killed)"

p 'ARTICLE 4 — ulimit -n and /proc/self/limits agree (both are prlimit under the hood)'
echo "   ulimit -n           = $(ulimit -n)"
grep 'Max open files' /proc/self/limits

p 'ARTICLE 4 — limit-open-files.c: use prlimit() to change another PID’s NOFILE'
$CC -Wall -o limit-open-files limit-open-files.c
sleep 120 & target=$!
sleep 0.3
echo "   target background pid = $target — lower its open-files limit to 12/12:"
./limit-open-files -p "$target" -s 12 -h 12
echo "   confirm through the kernel’s own view, /proc/$target/limits:"
grep 'Max open files' "/proc/$target/limits"

p 'ARTICLE 4 — raising the HARD limit needs CAP_SYS_RESOURCE (we lack it → EPERM)'
./limit-open-files -p "$target" -s 12 -h 13 || true
kill "$target" 2>/dev/null

echo
echo '== done — now read articles 3 & 4 and poke cgroups + limits yourself =='
