#!/usr/bin/perl -l
# powerset.pl (CORRECTED) — generate all 2^n subsets, one per line, unambiguously.
#
#   fixed/powerset.pl <set-file>
#
# Drop-in replacement for ../powerset.pl (Peteris Krumins, "Set Operations in
# the Unix Shell").  One character changed in the print statement:
#
#     print  @$p      ->      print "@$p"
#
# `print @$p` concatenates the list with no separator, so for the set {1, 2, 12}
# the subsets {1,2} and {12} both emit the line "12".  Quoting the array makes
# Perl join it on $" (a space), so the subsets are distinguishable — and a
# `sort -u` over the output no longer silently collapses two distinct subsets
# into one.  Elements are emitted in the same order as the original.
#
# Still exponential.  |P(S)| = 2^|S|, and that is not a bug either.

sub powset {
 return [[]] unless @_;
 my $head = shift;
 my $list = &powset;
 [@$list, map { [$head, @$_] } @$list]
}
chomp(my @e = <>);
for $p (@{powset(@e)}) {
 print "@$p";
}
