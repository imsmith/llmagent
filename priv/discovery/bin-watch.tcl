#!/usr/bin/env tclsh
#
# bin-watch.tcl — discovery shim for local executable commands.
#
# Sibling to avahi-llama.tcl. Where that shim watches the network for _llama._tcp
# services, this one watches directories of executables — ~/bin and friends — and
# advertises what it finds as LLMAgent tool ads on stdout.
#
# Output format: one EDN record per line, terminated by \n. Two events:
#   {:event :register :ad {...}}
#   {:event :expire  :id "..."}
#
# Usage:
#   bin-watch.tcl [--dir PATH]... [--interval SECS] [--lease SECS] [--once]
#                 [--registry PATH]
#
# Defaults: --dir ~/bin, --interval 30, --lease 120.
#
# WHY INTERROGATION IS STATIC
#
# These tools cannot be safely probed by running them. Of the 20 comma-tools in
# ~/bin, 11 have no argument parsing at all — they read $1/$2 positionally. So
# `,mkbooter --help` does not print help, it runs `dd if=--help | pv | sudo dd`,
# and `,update --help` runs `sudo apt update`. Any interrogator that executes a
# tool to learn about it will mutate the machine.
#
# Everything below is therefore derived from reading the file. Nothing here
# executes a watched tool, ever. That constraint is not a limitation to be
# removed later; it is a property of the population being watched.
#
# WHY FIDELITY IS :speculative
#
# Source extraction cannot know intent. It can see that a script calls ffmpeg
# and writes files; it cannot know the author meant it to convert webm to mp3.
# So every ad this shim emits is :speculative. A human-reviewed ad for the same
# coordinate would be :authoritative and the registry would rank it higher —
# multiple ads per coordinate are expected, per LLMAgent.ToolAd.
#
# Claiming :authoritative here would be the same failure as a traceability
# matrix asserting coverage nobody verified.
#
# HOW STALENESS WORKS
#
# Every ad carries :lease [:expires_at ...]. Each scan cycle re-emits ads for
# files that still exist, renewing the lease. A file that changes is
# re-interrogated (content hash differs) and re-advertised. A file that
# disappears stops being renewed and its lease lapses in Tools.Discovery's
# sweep — and an explicit :expire is emitted too. If this shim dies, every ad
# it published expires on its own. Nothing goes stale silently.
#
# A git HEAD change in a watched directory forces re-interrogation of every
# file in it, whether or not mtimes moved.

package require Tcl 8.6

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

set ::DIRS      {}
set ::INTERVAL  30
set ::LEASE     120
set ::ONCE      0
set ::REGISTRY  [file join $::env(HOME) bin commands.tcl]

proc usage {} {
    set fh [open [info script] r]
    set src [read $fh]
    close $fh
    foreach line [lrange [split $src "\n"] 1 end] {
        if {[string index $line 0] ne "#"} break
        puts stderr [string trimleft $line "# "]
    }
    exit 0
}

# Parsing is a proc rather than top-level code so the file can be sourced by a
# test without its options being read from the test runner's own argv.
proc parse_args {argv_list} {
    for {set i 0} {$i < [llength $argv_list]} {incr i} {
        set arg [lindex $argv_list $i]
        switch -- $arg {
            --dir      { incr i; lappend ::DIRS [file normalize [lindex $argv_list $i]] }
            --interval { incr i; set ::INTERVAL [lindex $argv_list $i] }
            --lease    { incr i; set ::LEASE [lindex $argv_list $i] }
            --registry { incr i; set ::REGISTRY [file normalize [lindex $argv_list $i]] }
            --once     { set ::ONCE 1 }
            --help - -h { usage }
            default {
                puts stderr "bin-watch: unknown option: $arg"
                exit 1
            }
        }
    }

    if {[llength $::DIRS] == 0} {
        set ::DIRS [list [file join $::env(HOME) bin]]
    }
}

# ---------------------------------------------------------------------------
# EDN emission
# ---------------------------------------------------------------------------

proc edn_str {s} {
    set s [string map {\\ \\\\ \" \\\"} $s]
    return "\"$s\""
}

proc edn_str_vec {items} {
    if {[llength $items] == 0} { return "\[\]" }
    set parts {}
    foreach i $items { lappend parts [edn_str $i] }
    return "\[[join $parts { }]\]"
}

proc edn_kw_vec {items} {
    if {[llength $items] == 0} { return "\[\]" }
    set parts {}
    foreach i $items { lappend parts ":$i" }
    return "\[[join $parts { }]\]"
}

proc iso {secs} {
    return [clock format $secs -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]
}

# ---------------------------------------------------------------------------
# Known-command table
#
# ,gen_cmd_registry writes commands.tcl — a Tcl data file listing every command
# reachable from the shell, with bash's own `kind` classification. Because it is
# Tcl data, tclsh can source it directly. It is used here to decide whether a
# bare word in a script names a real command or is just a word.
#
# Absent or unreadable, the shim still works; requirement extraction is simply
# less precise, and every ad says so via :extraction.
# ---------------------------------------------------------------------------

set ::KNOWN [dict create]
set ::KNOWN_LOADED 0

proc load_known {} {
    if {![file readable $::REGISTRY]} { return }
    set interp [interp create -safe]
    if {[catch {
        set fh [open $::REGISTRY r]
        set src [read $fh]
        close $fh
        $interp eval $src
        foreach entry [$interp eval {set commands}] {
            if {[dict exists $entry command] && [dict exists $entry kind]} {
                dict set ::KNOWN [dict get $entry command] [dict get $entry kind]
            }
        }
        set ::KNOWN_LOADED 1
    } err]} {
        puts stderr "bin-watch: could not load $::REGISTRY: $err"
    }
    catch {interp delete $interp}
}

# ---------------------------------------------------------------------------
# Static interrogation
# ---------------------------------------------------------------------------

# Words that look like commands but are shell syntax, not requirements.
set ::SHELL_NOISE {
    if then else elif fi for while do done case esac function return exit
    local export set unset echo cd test true false read shift eval exec
    source break continue printf declare typeset trap wait
    getopts getopt mapfile readarray readonly shopt let alias unalias
    builtin caller compgen complete dirs disown enable fc fg bg hash
    help history jobs kill logout popd pushd pwd suspend times ulimit
    umask type command until select coproc
}

# Signals that a script changes state. Deliberately over-broad: a false
# "mutates" is a tool an agent treats with unwarranted care, while a false
# "read-only" is a tool an agent runs when it should not have.
# Commands that write no matter how they are invoked.
set ::MUTATION_SIGNALS {
    rm mv cp mkfs mkdir rmdir touch chmod chown ln truncate shred
    tee install apt apt-get dpkg yum dnf pacman apk pip npm cargo
    ffmpeg convert mogrify
}

# Commands whose effect depends entirely on their arguments. Treating these as
# unconditional mutators marked ,pdfpages — three lines of
# `pdfinfo | grep | sed 's/…/'` — as writing to the filesystem, which it does
# not. The pattern must be present in the stripped code for the signal to fire.
set ::CONDITIONAL_MUTATION {
    sed   {-i}
    find  {-delete -exec}
    git   {commit push checkout reset clean rm merge rebase stash}
    tar   {-x --extract -c --create}
    rsync {--delete}
}

# Same treatment for the destructive tier. `dd if=… ` reading four bytes off a
# file is not destruction; `dd of=/dev/sdX` is. ,animated? uses the first form.
set ::CONDITIONAL_DESTRUCTIVE {
    dd     {of=}
    tar    {}
}

set ::NETWORK_SIGNALS {
    curl wget ssh scp rsync ftp nc netcat git apt apt-get pip npm
    yt yt-dlp youtube-dl fabric
}

set ::DESTRUCTIVE_SIGNALS {mkfs shred fdisk parted sgdisk wipefs}

# True when `cmd` appears in `code` alongside one of the argument patterns that
# make it dangerous. Absent a pattern list, presence alone is enough.
proc conditional_hit {code cmd patterns} {
    if {[llength $patterns] == 0} { return 0 }
    if {![regexp "\\y[string map {+ {\\+}} $cmd]\\y" $code]} { return 0 }
    foreach p $patterns {
        if {[string first $p $code] >= 0} { return 1 }
    }
    return 0
}

proc sha256_of {path} {
    if {[catch {exec sha256sum -- $path} out]} { return "" }
    return [lindex [split $out] 0]
}

# Does this name resolve to something executable on PATH? Stats files only —
# nothing is run. Used to annotate requirements, never to filter them.
proc on_path {name} {
    if {[string first "/" $name] >= 0} { return [file executable $name] }
    foreach d [split $::env(PATH) ":"] {
        if {[file executable [file join $d $name]]} { return 1 }
    }
    # Shell builtins and keywords resolve without being files.
    if {$::KNOWN_LOADED && [dict exists $::KNOWN $name]} { return 1 }
    return 0
}

# Shell variables that are not commands. OPTIND and friends appear in command
# position through arithmetic and getopts idioms.
set ::SHELL_VARS {
    OPTIND OPTARG REPLY IFS PATH HOME PWD OLDPWD SHELL USER LOGNAME
    RANDOM SECONDS LINENO FUNCNAME BASH_SOURCE PS1 PS2 PS4 TMPDIR EDITOR
}

# Tcl: external commands are reached through `exec`. Everything else in a Tcl
# script is a Tcl command, not a dependency.
proc tcl_exec_tokens {code} {
    set tokens {}
    foreach m [regexp -all -inline -- {\yexec\s+(?:-\S+\s+)*([A-Za-z0-9_][A-Za-z0-9_.-]*)} $code] {
        if {$m eq "exec" || [string match "exec*" $m]} continue
        if {[regexp {^[A-Za-z0-9_][A-Za-z0-9_.-]*$} $m] && [lsearch -exact $tokens $m] < 0} {
            lappend tokens $m
        }
    }
    # `open |cmd` is the other way out of Tcl.
    foreach m [regexp -all -inline -- {open\s+\"?\|\s*([A-Za-z0-9_][A-Za-z0-9_.-]*)} $code] {
        if {[string match "open*" $m]} continue
        if {[lsearch -exact $tokens $m] < 0} { lappend tokens $m }
    }
    return [lsort $tokens]
}

# Which extraction strategy applies to an interpreter. Guessing shell grammar
# for a Tcl or Python script produces confident nonsense — ,doc2md is Tcl and
# a shell reading of it reported proc, puts, foreach and every internal proc
# name as missing dependencies.
proc extraction_family {interp} {
    switch -glob -- $interp {
        sh - bash - dash - zsh - ksh - ash  { return shell }
        tclsh - wish - tclsh8.6 - tclsh8.7  { return tcl }
        ""                                   { return shell }
        default                              { return unsupported }
    }
}

# Commands that run another command as their argument. The interesting name is
# the one after them, not them.
set ::PREFIX_COMMANDS {sudo doas pkexec env command exec nohup time xargs nice ionice watch}

# First token of each command segment.
#
# Segments break on the operators that start a new command: newline, ; | & and
# the grouping constructs. Assignments (FOO=bar) and flags are skipped, and a
# prefix command hands off to the token after it, so `sudo apt install` yields
# both sudo and apt but not install.
#
# Existence is deliberately not consulted here. See interrogate/1.
proc command_position_tokens {code} {
    set tokens {}

    # Arithmetic expansion holds no commands. `(` normalises to a segment break
    # below, so $((OPTIND-1)), $((byte & 2)) and $((count + 1)) each strand a
    # variable name at the head of a segment, where it is read as a command and
    # reported missing. Blank the expansion whole, both the $(( )) and (( ))
    # forms.
    # Line-constrained deliberately. An unanchored `.*?` here matches across
    # newlines, so an unpaired `$((` swallows every line up to the next `))` —
    # deleting real commands and under-reporting requirements, which is the one
    # direction this shim must never fail in.
    regsub -all -line {\$\(\([^\n]*?\)\)} $code " " code
    regsub -all -line {\(\([^\n]*?\)\)} $code " " code

    # Brace parameter expansion, same mechanism: `{` and `}` normalise to
    # segment breaks, which severs the name in ${duration} from its `$` and
    # leaves a bare `duration` in command position. The non-nesting character
    # class is deliberate — an unmatched inner brace leaves the text alone
    # rather than swallowing past the end of the expansion.
    regsub -all -line {\$\{[^{}\n]*\}} $code " " code

    # Names the script defines itself. Calling your own function is not an
    # external requirement — ,cleantags called get_mp3_metadata and ,animated?
    # called is_webp_animated, and both were reported as dependencies.
    set local_defs {}
    foreach m [regexp -all -inline -line {^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)} $code] {
        if {[regexp {^[A-Za-z_][A-Za-z0-9_]*$} $m]} { lappend local_defs $m }
    }

    # `case` branch labels sit at the head of a segment once ) is a separator,
    # so h) json) *) all looked like commands. Collect them for exclusion
    # before the code is normalised.
    set case_labels {}
    foreach m [regexp -all -inline -line {^\s*\|?\s*([A-Za-z0-9_*?.-]+)\s*\)} $code] {
        if {![string match "*)*" $m]} { lappend case_labels $m }
    }
    # Normalise separators so a simple split finds segment boundaries.
    set norm [string map {
        "&&" "\n" "||" "\n" "|" "\n" ";" "\n" "(" "\n" ")" "\n"
        "`" "\n" "\$(" "\n" "{" "\n" "}" "\n"
    } $code]

    foreach segment [split $norm "\n"] {
        set words [regexp -all -inline {[^\s]+} $segment]
        set idx 0
        while {$idx < [llength $words]} {
            set w [lindex $words $idx]
            # Keywords after which a VARIABLE NAME follows, not a command.
            # `for cmd in dd od` names the loop variable cmd; `local OPTIND`
            # names a variable. Treating the next word as a command reported
            # cmd, song, byte and OPTIND as dependencies. Nothing further in
            # the segment is command position either.
            if {[lsearch -exact {for select read local declare export unset readonly typeset} $w] >= 0} {
                break
            }
            # Keywords after which a COMMAND follows.
            if {[lsearch -exact {if then else elif do while until case in esac fi done ! time} $w] >= 0} {
                incr idx
                continue
            }
            # Assignment prefix: FOO=bar cmd
            if {[regexp {^[A-Za-z_][A-Za-z0-9_]*=} $w]} { incr idx; continue }
            # Redirections and flags are never the command.
            if {[string index $w 0] in [list "-" ">" "<" "\$" "\"" "'"]} { incr idx; continue }
            if {$w eq ""} { incr idx; continue }

            set base [file tail $w]
            # A plausible command name: letters/digits/._- only, at least two
            # characters unless it resolves on PATH. Single letters and things
            # containing + or .. are case labels, arithmetic, or ranges.
            set plausible [expr {
                [regexp {^[A-Za-z0-9_][A-Za-z0-9_.-]*$} $base] &&
                ![string match "*..*" $base] &&
                ([string length $base] > 1 || [on_path $base])
            }]

            if {$plausible &&
                [lsearch -exact $::SHELL_NOISE $base] < 0 &&
                [lsearch -exact $::SHELL_VARS $base] < 0 &&
                [lsearch -exact $local_defs $base] < 0 &&
                [lsearch -exact $case_labels $base] < 0} {
                if {[lsearch -exact $tokens $base] < 0} { lappend tokens $base }
            }
            # A prefix command delegates to the next word; everything else ends
            # the search for this segment.
            if {[lsearch -exact $::PREFIX_COMMANDS $base] >= 0} { incr idx; continue }
            break
        }
    }
    return $tokens
}

# Replace comments and string literals with spaces, leaving executable code.
#
# Without this, scanning raw source treats prose as requirements. Observed on
# ,cleantags, which "required" as, from and install — all from comments and one
# echo string reading "Install it with: sudo apt install ...". That last one
# also inflated its blast radius to :system on the strength of a suggestion the
# script prints rather than a command it runs.
#
# Command substitutions inside double quotes ARE code and are preserved:
# $(basename "$0") must keep basename. Single-quoted text never expands in
# shell, so it is dropped whole.
#
# `#` opens a comment only at command position — start of input or after
# whitespace or a separator. This protects $#, ${#var} and a#b, which are not
# comments in any of the languages here.
# Blank out here-document bodies.
#
# A heredoc is a string literal that quoting rules do not cover, and usage/help
# text is very often written as one. Observed on ,animated?, whose help text
# line "use exit code only" contributed `code` as a requirement because `code`
# happens to name a real binary on this machine.
#
# Handles <<WORD, <<-WORD, <<'WORD' and <<"WORD". The body ends at a line whose
# only content is the delimiter (leading whitespace allowed, which is correct
# for <<- and harmless otherwise).
proc strip_heredocs {src} {
    set out {}
    set pending {}
    foreach line [split $src "\n"] {
        if {[llength $pending] > 0} {
            set delim [lindex $pending 0]
            if {[string trim $line] eq $delim} {
                set pending [lrange $pending 1 end]
            }
            lappend out ""
            continue
        }
        foreach m [regexp -all -inline {<<-?\s*(?:\"([^\"]+)\"|'([^']+)'|([A-Za-z_][A-Za-z0-9_]*))} $line] {
            # regexp -all -inline returns the whole match then each group; only
            # keep non-empty capture groups.
            if {$m eq "" || [string match "<<*" $m]} continue
            lappend pending $m
        }
        lappend out $line
    }
    return [join $out "\n"]
}

# With `keep_strings` set, double-quoted contents survive instead of being
# blanked. Requirement extraction wants them gone — an echoed "sudo apt install"
# is prose, not a command. Positional-parameter extraction wants them kept,
# because "$1" and "$@" are the correct quoting-safe forms and blanking them
# reports arity 0 and variadic false for every careful script. Two scans, two
# inputs.
#
# Single-quoted text is blanked in both modes: '$1' does not expand in shell,
# so keeping it would invent positionals that the script never receives.
# Blank a `$(( ... ))` arithmetic expansion, honouring nested parens, and
# return the index just past it.
#
# This has to happen here rather than by regex afterwards, because only the
# scanner knows the context. Inside double quotes the `$(` of `$((` otherwise
# reads as a command substitution and the expansion is left half-stripped as
# `(count + 1`, whose bare `(` then normalises to a segment break and strands
# `count` in command position.
# Returns the index just past the closing `))`, or -1 when the expansion does
# not close on the line it opened.
#
# Refusing to cross a newline is the point. An unpaired `$((` — one written
# inside a quoted string, say — would otherwise consume every line up to the
# next `))` anywhere in the file, deleting real commands and under-reporting
# requirements. A multi-line arithmetic expansion is legal but rare; leaving one
# unstripped costs at most a spurious token, which is the safe direction.
proc arith_end {src i} {
    set n [string length $src]
    incr i
    set depth 0
    while {$i < $n} {
        set c [string index $src $i]
        if {$c eq "\n"} { return -1 }
        if {$c eq "("} {
            incr depth
        } elseif {$c eq ")"} {
            incr depth -1
        }
        incr i
        if {$depth == 0} { return $i }
    }
    return -1
}

proc strip_noise {src {keep_strings 0}} {
    set src [strip_heredocs $src]
    set out [string repeat " " 0]
    set n [string length $src]
    set i 0
    set prev ""
    # Stack of contexts: normal, dquote. Single quotes and comments are
    # consumed inline rather than pushed.
    set stack [list normal]

    while {$i < $n} {
        set c [string index $src $i]
        set ctx [lindex $stack end]

        # Escapes carry through in both normal and double-quoted context.
        if {$c eq "\\" && $i + 1 < $n} {
            append out "  "
            set prev ""
            incr i 2
            continue
        }

        # Arithmetic holds no commands in any context. Not blanked when strings
        # are being kept: that pass reads positionals, and $(($1 + 1)) is a real
        # reference to $1.
        if {!$keep_strings && $c eq "\$" &&
            [string range $src [expr {$i + 1}] [expr {$i + 2}]] eq "(("} {
            set end [arith_end $src $i]
            if {$end > 0} {
                append out [string repeat " " [expr {$end - $i}]]
                set i $end
                set prev " "
                continue
            }
        }

        if {$ctx eq "normal"} {
            # Comment, only at command position.
            # Braces are deliberately NOT comment-position triggers: ${#arr} is
            # parameter expansion, and treating that # as a comment silently
            # swallowed the rest of the line. A genuine comment after a brace
            # always has whitespace before it.
            # NB: an explicit list, not a `string match` character class. In a
            # braced pattern Tcl does not interpret \t and \n as escapes, so
            # {[ \t\n;|&]} silently means "space, backslash, t, n, ; | &" and a
            # comment at the start of a line — after a newline — is not matched.
            # That bug left whole comment lines in the extracted code.
            if {$prev in [list "" " " "\t" "\n" ";" "|" "&"] && $c eq "#"} {
                while {$i < $n && [string index $src $i] ne "\n"} {
                    append out " "
                    incr i
                }
                set prev "\n"
                continue
            }
            if {$c eq "'"} {
                append out " "
                incr i
                while {$i < $n && [string index $src $i] ne "'"} {
                    append out " "
                    incr i
                }
                if {$i < $n} { append out " "; incr i }
                set prev " "
                continue
            }
            if {$c eq "\""} {
                append out " "
                lappend stack dquote
                set prev " "
                incr i
                continue
            }
            # Close a command substitution and return to the enclosing string.
            if {[llength $stack] > 1 && ($c eq ")" || $c eq "`")} {
                append out " "
                set stack [lrange $stack 0 end-1]
                set prev " "
                incr i
                continue
            }
            append out $c
            set prev $c
            incr i
            continue
        }

        # Inside double quotes: drop text, keep command substitutions.
        if {$c eq "\""} {
            append out " "
            set stack [lrange $stack 0 end-1]
            set prev " "
            incr i
            continue
        }
        if {$c eq "\$" && [string index $src [expr {$i + 1}]] eq "("} {
            append out "  "
            lappend stack normal
            set prev "("
            incr i 2
            continue
        }
        if {$c eq "`"} {
            append out " "
            lappend stack normal
            set prev "`"
            incr i
            continue
        }
        if {$keep_strings} { append out $c } else { append out " " }
        set prev " "
        incr i
    }

    return $out
}

proc interrogate {path} {
    set facts [dict create]
    dict set facts path $path
    dict set facts name [file tail $path]
    dict set facts sha256 [sha256_of $path]

    if {[catch {
        set fh [open $path r]
        fconfigure $fh -encoding utf-8
        set src [read $fh]
        close $fh
    }]} {
        dict set facts unreadable 1
        return $facts
    }

    set lines [split $src "\n"]
    set first [lindex $lines 0]

    # The shebang is read from the raw first line, before stripping, because
    # `#!` is the one `#` in the file that is not a comment.
    # Everything after this point reads CODE, not prose.
    set code [strip_noise $src]
    # Positionals are read from a pass that keeps double-quoted contents; see
    # strip_noise. Requirements must not be read from this one.
    set argcode [strip_noise $src 1]

    # --- interpreter, from the shebang ---
    if {[regexp {^#!\s*(\S+)(?:\s+(\S+))?} $first -> bin arg]} {
        set interp [file tail $bin]
        if {$interp eq "env" && $arg ne ""} { set interp [file tail $arg] }
        dict set facts interpreter $interp
    } else {
        # No shebang at all. This is a real portability defect — the file runs
        # under whatever shell happens to invoke it. Recorded, not guessed.
        dict set facts interpreter ""
        dict set facts no_shebang 1
    }

    # --- requirements, by command position ---
    #
    # Detection must NOT depend on the command existing. Gating on "is this on
    # PATH" makes a missing dependency invisible, which inverts the purpose:
    # ,ew is `yt --transcript $1 | fabric ...` and `yt` is not installed on
    # this machine, so an existence-gated scan reported :requires [] for a tool
    # that cannot run at all.
    #
    # So: take the first token of each command segment, whatever it is, then
    # separately record whether it resolves here.
    set family [extraction_family [dict get $facts interpreter]]
    dict set facts family $family

    switch -- $family {
        shell { set requires [command_position_tokens $code] }
        tcl   { set requires [tcl_exec_tokens $code] }
        default {
            # No grammar for this language. Say so rather than emit a shell
            # reading of a Python file.
            set requires {}
        }
    }

    # Explicit dependency checks are requirements too, and they are not in
    # command position. ,animated? does `for cmd in dd od; do command -v ...`,
    # which is the idiomatic way to declare a hard dependency in shell.
    foreach dep [regexp -all -inline -- {(?:command\s+-v|which|type\s+-t?)\s+\"?\$?\{?([A-Za-z0-9_./+-]+)} $code] {
        if {[string match "command*" $dep] || [string match "which*" $dep] || [string match "type*" $dep]} continue
        # `type -t -- "$c"` is a classification idiom, and the capture class
        # includes `-`, so the end-of-options marker arrives here looking like a
        # dependency. No flag is a command.
        if {[string index $dep 0] eq "-"} continue
        if {[regexp {^[A-Za-z_][A-Za-z0-9_]*$} $dep] && [regexp "for\\s+$dep\\s+in\\s+(\[^;\\n\]+)" $code -> items]} {
            # The check is on a loop variable — the real dependencies are the
            # words the loop iterates over.
            foreach item $items {
                if {[regexp {^[A-Za-z0-9_./+-]+$} $item] && [lsearch -exact $requires $item] < 0} {
                    lappend requires $item
                }
            }
        } elseif {[lsearch -exact $requires $dep] < 0} {
            lappend requires $dep
        }
    }

    set requires [lsort -unique $requires]

    # Which of them actually resolve on this host. Recorded, never used to
    # filter — a missing requirement is the finding, not something to hide.
    set missing {}
    foreach r $requires {
        if {![on_path $r]} { lappend missing $r }
    }
    dict set facts missing $missing

    set mutates 0
    set networked 0
    set destructive 0
    set privileged 0

    # Signals are read from command-position tokens only. A word appearing as
    # an argument does not make a script dangerous; `apt` in `sudo apt install`
    # does, and `install` (also a real binary) does not.
    foreach base $requires {
        if {$base eq "sudo" || $base eq "doas" || $base eq "pkexec"} { set privileged 1 }
        if {[lsearch -exact $::MUTATION_SIGNALS $base] >= 0} { set mutates 1 }
        if {[lsearch -exact $::NETWORK_SIGNALS $base] >= 0} { set networked 1 }
        if {[lsearch -exact $::DESTRUCTIVE_SIGNALS $base] >= 0} { set destructive 1 }
    }

    dict set facts requires $requires
    dict set facts mutates $mutates
    dict set facts networked $networked
    dict set facts destructive $destructive
    dict set facts privileged $privileged

    # --- arity, from positional parameter references ---
    set maxarg 0
    foreach m [regexp -all -inline {\$\{?([1-9][0-9]?)\}?} $argcode] {
        if {[string is integer -strict $m] && $m > $maxarg} { set maxarg $m }
    }
    dict set facts arity $maxarg
    dict set facts variadic [expr {[regexp {\$[@*]} $argcode] ? 1 : 0}]

    # --- can this reading be trusted? ---
    # eval and variable-as-command defeat static extraction. Saying so is the
    # difference between an honest short requires list and a misleading one.
    set incomplete 0
    if {[regexp {\beval\b} $code]}                { set incomplete 1 }
    if {[regexp {(^|[;|&]\s*)\$[A-Za-z_]} $code]} { set incomplete 1 }
    if {[regexp {\$\(\s*\$} $code]}             { set incomplete 1 }
    dict set facts extraction_incomplete $incomplete

    return $facts
}

# ---------------------------------------------------------------------------
# Ad construction
# ---------------------------------------------------------------------------

proc coordinate_for {name} {
    # No invented taxonomy. A flat, honest namespace: these are local commands,
    # and that is all static reading can establish. Categorisation is a job for
    # a higher-fidelity ad.
    set slug [string map {" " "-"} $name]
    return "command.local.$slug"
}

proc blast_radius {facts} {
    if {[dict get $facts extraction_incomplete]} {
        return "{:scope :unknown :reason \"static extraction incomplete\"}"
    }
    if {[dict get $facts destructive] || [dict get $facts privileged]} {
        return "{:scope :system :reversible false}"
    }
    if {[dict get $facts mutates]} {
        return "{:scope :filesystem :reversible :unknown}"
    }
    return "{:scope :none}"
}

# Every ad declares :action, never :query.
#
# LLMAgent.Tool.Adapter documents :query as "pure, idempotent, no side effects".
# Running a binary is I/O, and the claim that a particular binary is harmless is
# an inference drawn from reading its source — exactly the sort of unverified
# assertion :fidelity exists to flag. Labelling a guess as purity inverts that.
#
# The distinction is not lost: it lives in :blast_radius, where it is honestly
# presented as an inference. A consumer wanting harmless tools filters on
# {:scope :none} rather than trusting a purity claim.
proc kinds_for {facts} {
    return {action}
}

proc ad_id_for {path} {
    return "bin:$path"
}

proc emit_register {facts} {
    set path [dict get $facts path]
    set name [dict get $facts name]
    set now  [clock seconds]

    set ad "{:id [edn_str [ad_id_for $path]]"
    append ad " :coordinate [edn_str [coordinate_for $name]]"
    append ad " :kinds [edn_kw_vec [kinds_for $facts]]"
    append ad " :binding \[:exec {:argv \[[edn_str $path]\] :interpreter [edn_str [dict get $facts interpreter]]}\]"

    append ad " :operational {:actions {\"run\" {:arity [dict get $facts arity]"
    append ad " :variadic [expr {[dict get $facts variadic] ? "true" : "false"}]}}"
    append ad " :requires [edn_str_vec [dict get $facts requires]]"
    # Requirements that do not resolve on this host. An empty list means the
    # tool's dependencies are satisfied HERE; it says nothing about elsewhere.
    append ad " :missing [edn_str_vec [dict get $facts missing]]"
    append ad " :networked [expr {[dict get $facts networked] ? "true" : "false"}]}"

    append ad " :constraint {:idempotency {} :blast_radius [blast_radius $facts]}"

    append ad " :affordance {:declared \[\] :learned \[\] :open true}"

    # Source-extracted, never authored. See the header.
    append ad " :fidelity :speculative"

    append ad " :provenance {:source [edn_str "bin-watch:[file dirname $path]"]"
    append ad " :produced_at [edn_str [iso $now]]"
    append ad " :based_on [edn_str_vec [list "sha256:[dict get $facts sha256]"]]"
    append ad " :signature nil}"

    append ad " :lease \[:expires_at [edn_str [iso [expr {$now + $::LEASE}]]]\]"

    append ad " :meta {:extraction [expr {[dict get $facts family] eq "unsupported" ? ":unsupported" : ([dict get $facts extraction_incomplete] ? ":incomplete" : ":complete")}]"
    append ad " :language [edn_str [dict get $facts interpreter]]"
    if {[dict exists $facts no_shebang]} {
        append ad " :no_shebang true"
    }
    append ad "}"
    append ad "}"

    puts "{:event :register :ad $ad}"
    flush stdout
}

proc emit_expire {path} {
    puts "{:event :expire :id [edn_str [ad_id_for $path]]}"
    flush stdout
}

# ---------------------------------------------------------------------------
# Watching
# ---------------------------------------------------------------------------

# path -> sha256 last advertised
set ::SEEN [dict create]
# dir -> git HEAD last observed
set ::HEADS [dict create]

proc git_head {dir} {
    if {[catch {exec git -C $dir rev-parse HEAD 2>/dev/null} head]} { return "" }
    return [string trim $head]
}

proc executables_in {dir} {
    set out {}
    if {![file isdirectory $dir]} { return $out }
    foreach f [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $f]} continue
        if {![file executable $f]} continue
        # Documentation living beside a tool is not a tool.
        switch -glob -- [file tail $f] {
            *.md - *.feature - *.test-guide.md - *.orig - *.bak { continue }
        }
        lappend out $f
    }
    return [lsort $out]
}

proc scan_once {} {
    set live {}

    foreach dir $::DIRS {
        # A git commit in a watched directory forces re-interrogation of
        # everything in it, regardless of mtime. This is the "version control
        # triggers a new interrogation" rule.
        set head [git_head $dir]
        set forced 0
        if {$head ne ""} {
            if {![dict exists $::HEADS $dir] || [dict get $::HEADS $dir] ne $head} {
                set forced 1
                dict set ::HEADS $dir $head
            }
        }

        foreach path [executables_in $dir] {
            lappend live $path
            set facts [interrogate $path]
            if {[dict exists $facts unreadable]} continue

            set sha [dict get $facts sha256]
            set known [expr {[dict exists $::SEEN $path] ? [dict get $::SEEN $path] : ""}]

            # Re-advertise when the content changed, when git moved, or when the
            # lease needs renewing — which is every cycle.
            if {$forced || $sha ne $known || 1} {
                emit_register $facts
                dict set ::SEEN $path $sha
            }
        }
    }

    # Anything previously advertised and now gone gets an explicit expire, in
    # addition to its lease lapsing on its own.
    foreach path [dict keys $::SEEN] {
        if {[lsearch -exact $live $path] < 0} {
            emit_expire $path
            dict unset ::SEEN $path
        }
    }
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

# Exit when whoever spawned us goes away.
#
# Port.open/2 does not kill the external program when the port closes. A shim
# that never reads stdin therefore outlives the BEAM that spawned it, keeps
# scanning on its timer, and keeps writing to a stdout nobody is reading — which
# is where `error writing "stdout": broken pipe` comes from. Noticing EOF on
# stdin is the shim's half of the fix; LLMAgent.Discovery.PortAdapter kills the
# OS process for the case where the VM dies too abruptly to close anything.
#
# This requires an event loop, which is why the scan timer below is an `after`
# callback with a vwait rather than a bare blocking `after`.
proc watch_stdin {} {
    fconfigure stdin -blocking 0
    fileevent stdin readable {
        if {[eof stdin]} { exit 0 }
        # Nothing is expected on stdin; drain it so the handler does not respin.
        read stdin
    }
}

proc tick {} {
    scan_once
    after [expr {$::INTERVAL * 1000}] tick
}

proc main {} {
    parse_args $::argv
    load_known

    if {$::ONCE} {
        scan_once
        exit 0
    }

    watch_stdin
    tick
    vwait ::forever
}

# Run the driver only when executed directly, so tests can source this file for
# its procs without starting a scan loop.
if {[info exists ::argv0] &&
    [file normalize $::argv0] eq [file normalize [info script]]} {
    main
}
