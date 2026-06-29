#!/bin/sh
# A spread of examples from Matt Might, "Sculpting text with regex, grep, sed, awk".
# Operates on the sample data beside it; with the GNU grep/sed/gawk this lab
# installs it prints the same on Debian and Alpine. Read the article, then tinker.
cd "$(dirname "$0")" || exit 1
p() { printf '\n== %s ==\n' "$1"; }   # label a section without the shell eating backslashes

p 'grep (ERE backreference): words that are a doubled string  ^(.*)\1$'
grep -E '^(.*)\1$' words

p 'grep -Ec: how many words contain a doubled letter  (.)\1'
grep -Ec '(.)\1' words

p 'egrep alternation: oo...ee or ee...oo'
grep -E 'oo.*ee|ee.*oo' words

p 'sed: substitute, then GNU \U to upper-case the match'
echo 'the cat sat on the mat' | sed 's/cat/dog/; s/\(mat\)/\U\1/'

p 'sed: delete comment lines (/^#/d), leaving the accounts'
sed '/^#/d' passwd

p 'awk -F: pattern-action — skip comments, print name + uid'
awk -F: '/^[^#]/ { print $1, $3 }' passwd

p 'awk: real users only (uid >= 1000)'
awk -F: '$3 >= 1000 { print $1 }' passwd

p 'awk: dedup preserving first-seen order  !seen[$0]++'
awk '!seen[$0]++' dupes.txt

p 'awk + sort|uniq: busiest client IPs in the access log'
awk '{ print $1 }' access_log | sort | uniq -c | sort -rn

p 'awk function: palindromes in the word list'
awk 'function rev(s,  r,i){ r=""; for (i=length(s); i>=1; i--) r=r substr(s,i,1); return r }
     length($0) > 1 && rev($0) == $0 { print }' words
