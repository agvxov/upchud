#!/usr/bin/tclsh

set f [open "evil.txt" "w"]
close $f

puts stderr "evil.txt created"
