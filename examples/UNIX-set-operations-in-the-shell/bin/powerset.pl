#!/usr/bin/perl -l
# powerset.pl — generate all 2^n subsets of a set, one per line.
#
#   powerset.pl <set-file>
#
# Transcribed VERBATIM from Peteris Krumins, "Set Operations in the Unix Shell",
# where he introduces it as "a silly Perl solution" after concluding the power
# set is not easy with plain Unix tools:
#   https://catonmat.net/set-operations-in-unix-shell
# Only this header is added; the shebang carries the -l he passed to `perl -le`.
#
# ERRATUM: `print @$p` interpolates the subset's elements with NO SEPARATOR.
# For the set {1, 2, 12} the subsets {1,2} and {12} BOTH print as "12", so the
# output is ambiguous and `sort -u` will silently collapse them.  The fix is one
# character — `print "@$p"` — which joins on $" (a space).  See bin/fixed/powerset.pl.

sub powset {
 return [[]] unless @_;
 my $head = shift;
 my $list = &powset;
 [@$list, map { [$head, @$_] } @$list]
}
chomp(my @e = <>);
for $p (@{powset(@e)}) {
 print @$p;
}
