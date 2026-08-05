#!/usr/bin/env tclsh
#
# Tests for priv/discovery/bin-watch.tcl's static interrogation.
#
# The shim guards its driver behind an argv0 check, so sourcing it here yields
# its procs without starting a scan loop.
#
# Run: tclsh test/tcl/bin_watch_test.tcl

package require tcltest 2.5
namespace import ::tcltest::*

set here [file dirname [file normalize [info script]]]
# Overridable so the suite can be pointed at a variant of the shim — used to
# confirm these tests actually fail against unfixed extraction.
if {[info exists ::env(BINWATCH_SHIM)]} {
    set shim $::env(BINWATCH_SHIM)
} else {
    set shim [file join $here .. .. priv discovery bin-watch.tcl]
}
source $shim

set fixdir [makeDirectory binwatch_fixtures]

# Write an executable fixture and return the facts bin-watch extracts from it.
proc facts_for {name body} {
    set path [file join $::fixdir $name]
    set fh [open $path w]
    puts -nonewline $fh $body
    close $fh
    file attributes $path -permissions 0755
    return [interrogate $path]
}

# ---------------------------------------------------------------------------
# Positional parameters — read from a pass that keeps double-quoted contents
# ---------------------------------------------------------------------------

test arity-quoted {"$1" is the quoting-safe form and must still count} -body {
    dict get [facts_for quoted.sh "#!/bin/bash\ncp -- \"\$1\" \"\$2\"\n"] arity
} -result 2

test arity-unquoted {bare $1 keeps working} -body {
    dict get [facts_for unquoted.sh "#!/bin/bash\ncat \$1\n"] arity
} -result 1

test arity-braced-quoted {"${3}" counts} -body {
    dict get [facts_for braced.sh "#!/bin/bash\necho \"\${3}\"\n"] arity
} -result 3

test arity-single-quoted {'$5' does not expand in shell, so it is not a positional} -body {
    dict get [facts_for sq.sh "#!/bin/bash\necho '\$5'\n"] arity
} -result 0

test variadic-quoted {"$@" is the idiomatic form and must set variadic} -body {
    dict get [facts_for variadic.sh "#!/bin/bash\nexec ffmpeg \"\$@\"\n"] variadic
} -result 1

test variadic-absent {a script taking no varargs is not variadic} -body {
    dict get [facts_for novariadic.sh "#!/bin/bash\ncat \"\$1\"\n"] variadic
} -result 0

test arity-ignores-comments {a positional named in a comment is not an argument} -body {
    dict get [facts_for argcomment.sh "#!/bin/bash\n# takes \$9 arguments\ntrue\n"] arity
} -result 0

# ---------------------------------------------------------------------------
# Requirement extraction must not invent commands
# ---------------------------------------------------------------------------

test noise-arith-dollar {$((OPTIND-1)) is arithmetic, not a command} -body {
    lsearch -exact [dict get [facts_for arith1.sh \
        "#!/bin/bash\ngetopts \"a\" o\nshift \$((OPTIND-1))\n"] requires] "OPTIND-1"
} -result -1

test noise-arith-operand {$((byte & 2)) does not make `byte` a command} -body {
    lsearch -exact [dict get [facts_for arith2.sh \
        "#!/bin/bash\nif \[ \$((byte & 2)) -ne 0 \]; then true; fi\n"] requires] "byte"
} -result -1

test noise-arith-bare {((counter += STEP)) does not make `counter` a command} -body {
    lsearch -exact [dict get [facts_for arith3.sh \
        "#!/bin/bash\n((counter += STEP))\n"] requires] "counter"
} -result -1

test noise-arith-quoted {"$((count + 1))" inside quotes leaves no bare operand} -body {
    lsearch -exact [dict get [facts_for arith4.sh \
        "#!/bin/bash\nfetch \"\$url\" \"\$((count + 1))\" \"\$max\"\n"] requires] "count"
} -result -1

test noise-arith-nested {nested parens inside arithmetic are consumed whole} -body {
    lsearch -exact [dict get [facts_for arith5.sh \
        "#!/bin/bash\necho \$(( (width + 1) * scale ))\n"] requires] "width"
} -result -1

# Stripping arithmetic must consume the expansion and nothing beyond it. An
# unanchored `.*?` reaches across newlines, which would delete the commands
# between two arithmetic expressions — under-reporting requirements, the one
# direction this shim must never fail in.
test arith-strip-does-not-eat-neighbours {commands between two expansions survive} -body {
    set r [dict get [facts_for arithspan.sh \
        "#!/bin/bash\nx=\$((1 + 1))\nffprobe -v error a\ny=\$((2 + 2))\nmetaflac --list b\n"] requires]
    list [expr {[lsearch -exact $r ffprobe] >= 0}] [expr {[lsearch -exact $r metaflac] >= 0}]
} -result {1 1}

test noise-brace-expansion {\${duration} is a parameter reference, not a command} -body {
    lsearch -exact [dict get [facts_for brace.sh \
        "#!/bin/bash\nprintf \"%d\" \${duration}\n"] requires] "duration"
} -result -1

test noise-end-of-options {`--` after a type check is not a dependency} -body {
    lsearch -exact [dict get [facts_for endopts.sh \
        "#!/bin/bash\ntype -t -- \"\$c\"\n"] requires] "--"
} -result -1

# ---------------------------------------------------------------------------
# ...while still finding the requirements that are really there
# ---------------------------------------------------------------------------

test requires-real-commands {genuine commands survive the noise filters} -body {
    set r [dict get [facts_for real.sh \
        "#!/bin/bash\nffprobe -v error \"\$1\"\nshift \$((OPTIND-1))\nmetaflac --list \"\$1\"\n"] requires]
    list [expr {[lsearch -exact $r ffprobe] >= 0}] [expr {[lsearch -exact $r metaflac] >= 0}]
} -result {1 1}

test requires-skips-prose {commands named only in comments are not requirements} -body {
    lsearch -exact [dict get [facts_for prose.sh \
        "#!/bin/bash\n# Install it with: sudo apt install foo\ntrue\n"] requires] "apt"
} -result -1

test requires-explicit-dep-check {command -v NAME is still read as a dependency} -body {
    expr {[lsearch -exact [dict get [facts_for depcheck.sh \
        "#!/bin/bash\ncommand -v metaflac >/dev/null\n"] requires] "metaflac"] >= 0}
} -result 1

cleanupTests
