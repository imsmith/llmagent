#!/usr/bin/env tclsh
#
# Tests for priv/discovery/avahi-llama.tcl: what it emits for avahi-browse
# lines, and that it renews the leases it issues.
#
# The shim guards its driver behind an argv0 check, so sourcing it here yields
# its procs without spawning avahi-browse. Input lines come from
# test/fixtures/discovery/avahi_llama_browse.txt, which is real
# `avahi-browse -p -r -t _llama._tcp` output. Do not edit it by hand.
#
# Run: tclsh test/tcl/avahi_llama_test.tcl

package require tcltest 2.5
namespace import ::tcltest::*

set here [file dirname [file normalize [info script]]]
source [file join $here .. .. priv discovery avahi-llama.tcl]

# Collect what the shim would write to stdout.
set ::out {}
proc emit {line} { lappend ::out $line }

set fh [open [file join $here .. fixtures discovery avahi_llama_browse.txt] r]
set ::lines [split [string trimright [read $fh]] "\n"]
close $fh

proc lines_of_kind {kind} {
    set found {}
    foreach l $::lines {
        if {[string index $l 0] eq $kind} { lappend found $l }
    }
    return $found
}

# Forget everything and feed lines; returns what was emitted.
proc feed {lines} {
    set ::out {}
    foreach l $lines { handle_line $l }
    return $::out
}

proc reset {} {
    array unset ::instances
    array set ::instances {}
    set ::out {}
}

# The facts a resolved line carries, read from the line itself.
proc facts {line} {
    set parts [split $line ";"]
    regexp {"model=([^"]*)"} $line -> model
    return [dict create host [lindex $parts 6] port [lindex $parts 8] model $model \
                id "mdns:_llama._tcp:[lindex $parts 6]:[lindex $parts 8]"]
}

# The matching goodbye line for a resolved line.
proc goodbye {line} {
    return "-;[join [lrange [split $line {;}] 1 5] {;}]"
}

set ::resolved [lines_of_kind "="]

test fixture-has-two-hosts {the recorded browse output resolves two hosts} -body {
    llength $::resolved
} -result 2

test resolved-lines-register {each resolved line emits one register carrying its id and model} -setup {
    reset
} -body {
    set emitted [feed $::resolved]
    set ok [expr {[llength $emitted] == 2}]
    foreach line $::resolved record $emitted {
        set f [facts $line]
        if {![string match "\{:event :register *" $record]} { set ok 0 }
        if {[string first "\"[dict get $f id]\"" $record] < 0} { set ok 0 }
        if {[string first "compute.llm.chat" $record] < 0} { set ok 0 }
        if {[string first ":model \"[dict get $f model]\"" $record] < 0} { set ok 0 }
    }
    set ok
} -result 1

test new-lines-emit-nothing {a "+" line waits for its resolved line} -setup {
    reset
} -body {
    feed [lines_of_kind "+"]
} -result {}

test renewal-re-emits-every-instance {renewal registers each remembered instance again} -setup {
    reset
    feed $::resolved
} -body {
    set ::out {}
    renew_all
    set ids {}
    foreach record $::out {
        regexp {:id "([^"]+)"} $record -> id
        lappend ids $id
    }
    set expected {}
    foreach line $::resolved { lappend expected [dict get [facts $line] id] }
    list [llength $::out] [expr {[lsort $ids] eq [lsort $expected]}]
} -result {2 1}

test goodbye-expires-and-forgets {a "-" line expires its ad and renewal no longer includes it} -setup {
    reset
    feed $::resolved
} -body {
    set first [lindex $::resolved 0]
    set second [lindex $::resolved 1]
    set expired [feed [list [goodbye $first]]]
    set ::out {}
    renew_all
    list $expired \
         [llength $::out] \
         [expr {[string first "\"[dict get [facts $second] id]\"" [lindex $::out 0]] >= 0}]
} -result [list [list "{:event :expire :id \"[dict get [facts [lindex $::resolved 0]] id]\"}"] 1 1]

test model-change-replaces {a later resolved line for the same instance replaces the remembered model} -setup {
    reset
    feed $::resolved
} -body {
    set first [lindex $::resolved 0]
    set old [dict get [facts $first] model]
    set changed [string map [list "model=$old" "model=some-other-model.gguf"] $first]
    feed [list $changed]
    set ::out {}
    renew_all
    set mine {}
    foreach record $::out {
        if {[string first "\"[dict get [facts $first] id]\"" $record] >= 0} { lappend mine $record }
    }
    list [llength $mine] \
         [expr {[string first ":model \"some-other-model.gguf\"" [lindex $mine 0]] >= 0}] \
         [expr {[string first $old [lindex $mine 0]] >= 0}]
} -result {1 1 0}

test short-line-ignored {a line with fewer than six fields is ignored} -setup {
    reset
} -body {
    set emitted [feed [list "=;eth0;IPv4"]]
    renew_all
    list $emitted $::out
} -result {{} {}}

test other-api-not-remembered {a host that is not openai-compatible is neither registered nor renewed} -setup {
    reset
} -body {
    set line [string map {"api=openai-compatible" "api=something-else"} [lindex $::resolved 0]]
    set emitted [feed [list $line]]
    renew_all
    list $emitted $::out
} -result {{} {}}

test unhealthy-host-is-withdrawn {a remembered host that reports a status other than ok is expired and forgotten} -setup {
    reset
    feed $::resolved
} -body {
    set first [lindex $::resolved 0]
    set emitted [feed [list [string map {"status=ok" "status=loading"} $first]]]
    set ::out {}
    renew_all
    list $emitted [llength $::out]
} -result [list [list "{:event :expire :id \"[dict get [facts [lindex $::resolved 0]] id]\"}"] 1]

cleanupTests
