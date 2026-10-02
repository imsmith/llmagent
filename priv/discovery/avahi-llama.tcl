#!/usr/bin/env tclsh
#
# avahi-llama.tcl — discovery shim for _llama._tcp services.
#
# Wraps `avahi-browse -p -r _llama._tcp` and translates its parsable output
# into LLMAgent discovery EDN events on stdout.
#
# Output format: one EDN record per line, terminated by \n. Two events:
#   {:event :register :ad {...}}
#   {:event :expire  :id "..."}
#
# Every ad carries a 60-second lease, and the registry sweeps expired leases.
# A host is resolved once, when avahi first sees it, so the shim renews: on a
# timer it registers every host it still knows about again, with a fresh
# lease. Without that, every discovered endpoint vanishes a minute after
# start.
#
# Environment:
#   AVAHI_LLAMA_RENEW_MS    renewal interval in milliseconds (default 20000)
#   AVAHI_LLAMA_BROWSE_CMD  command to read browse output from, as a Tcl list
#                           (default: stdbuf -oL avahi-browse -p -r _llama._tcp)
#
# The driver sits behind an argv0 guard, so tests can source this file for its
# procs. See test/tcl/avahi_llama_test.tcl.
#
# See docs/superpowers/specs/2026-05-07-mdns-llm-discovery.md.

package require Tcl 8.6

# In-memory map: instance-key -> dict {id host addr port txt}. The id lets us
# emit :expire on goodbye records (which lack the resolved fields); the rest
# is what it takes to register the host again when its lease is renewed.
array set instances {}

# Everything the shim says goes through here, so a test can replace it.
proc emit {line} {
    puts $line
    flush stdout
}

proc instance_key {iface proto name type domain} {
    return "$iface|$proto|$name|$type|$domain"
}

proc ad_id {host port} {
    return "mdns:_llama._tcp:$host:$port"
}

proc parse_txt {fields} {
    set out [dict create]
    foreach kv $fields {
        set kv [string trim $kv "\""]
        if {[regexp {^([^=]+)=(.*)$} $kv -> k v]} {
            dict set out $k $v
        }
    }
    return $out
}

proc edn_str {s} {
    # Quote a string for EDN — escape backslashes and double-quotes.
    set s [string map {\\ \\\\ \" \\\"} $s]
    return "\"$s\""
}

# Whether a host's TXT record describes something we can register: an
# OpenAI-compatible server that says it is ready.
proc registrable {txt} {
    set api    [expr {[dict exists $txt api]    ? [dict get $txt api]    : ""}]
    set status [expr {[dict exists $txt status] ? [dict get $txt status] : "ok"}]
    return [expr {$api eq "openai-compatible" && $status eq "ok"}]
}

proc emit_register {ad_id host addr port txt} {
    set model  [expr {[dict exists $txt model]  ? [dict get $txt model]  : ""}]
    set n_ctx  [expr {[dict exists $txt n_ctx]  ? [dict get $txt n_ctx]  : "0"}]
    set slots  [expr {[dict exists $txt slots]  ? [dict get $txt slots]  : "1"}]

    if {![registrable $txt]} { return }

    set api_host "http://$addr:$port"
    set now      [clock format [clock seconds]    -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]
    set expires  [clock format [expr {[clock seconds] + 60}] -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]

    set ad "{:id [edn_str $ad_id]"
    append ad " :coordinate \"compute.llm.chat\""
    append ad " :kinds \[:generate\]"
    append ad " :binding \[:openai_chat {:api_host [edn_str $api_host] :model [edn_str $model]}\]"
    append ad " :operational {:actions {\"chat\" {:concurrency $slots}} :model_id [edn_str $model]}"
    append ad " :constraint  {:idempotency {} :blast_radius {}}"
    append ad " :affordance  {:declared \[{:intent :long_context :n_ctx $n_ctx}\] :learned \[\] :open true}"
    append ad " :fidelity    :authoritative"
    append ad " :provenance  {:source \"mdns/_llama._tcp\" :produced_at [edn_str $now] :based_on \[\] :signature nil}"
    append ad " :lease       \[:expires_at [edn_str $expires]\]"
    append ad "}"

    emit "{:event :register :ad $ad}"
}

proc emit_expire {ad_id} {
    emit "{:event :expire :id [edn_str $ad_id]}"
}

# Register every host we still know about again, extending its lease. The
# registry treats a register for an id it already holds as an update.
proc renew_all {} {
    global instances
    foreach key [array names instances] {
        set i $instances($key)
        emit_register [dict get $i id] [dict get $i host] [dict get $i addr] [dict get $i port] [dict get $i txt]
    }
}

proc handle_line {line} {
    global instances
    set parts [split $line ";"]
    if {[llength $parts] < 6} { return }

    set kind [lindex $parts 0]
    set iface  [lindex $parts 1]
    set proto  [lindex $parts 2]
    set name   [lindex $parts 3]
    set type   [lindex $parts 4]
    set domain [lindex $parts 5]
    set key [instance_key $iface $proto $name $type $domain]

    switch -- $kind {
        "+"  {
            # New service. Wait for the matching "=" (resolved) line to register.
        }
        "=" {
            # Resolved record:
            # =;iface;proto;name;type;domain;hostname;address;port;txt0 txt1 ...
            if {[llength $parts] < 9} { return }
            set host [lindex $parts 6]
            set addr [lindex $parts 7]
            set port [lindex $parts 8]
            # Column 9 is a single string of space-separated, double-quoted
            # TXT records: `"n_ctx=262144" "slots=4" ...`. Pass it directly
            # so parse_txt's foreach iterates each quoted record as a list
            # element. lrange would wrap it back into a 1-element list and
            # break the iteration.
            set txt [parse_txt [lindex $parts 9]]
            set id   [ad_id $host $port]
            if {[registrable $txt]} {
                # A later resolved line for the same instance replaces what
                # we remember — this is how a host changing its model shows.
                set instances($key) [dict create id $id host $host addr $addr port $port txt $txt]
                emit_register $id $host $addr $port $txt
            } elseif {[info exists instances($key)]} {
                # A host we registered now says it is not ready: withdraw it
                # rather than keep renewing a lease on its behalf.
                emit_expire [dict get $instances($key) id]
                unset instances($key)
            }
        }
        "-" {
            if {[info exists instances($key)]} {
                emit_expire [dict get $instances($key) id]
                unset instances($key)
            }
        }
        default {}
    }
}

# Spawn avahi-browse as a child. -p parsable, -r resolve, no -t (long-running).
# `stdbuf -oL` forces avahi-browse to line-buffer stdout. Without it,
# avahi block-buffers when piped (non-TTY); under a BEAM Erlang Port nothing
# ever triggers a flush, so the shim looks silent even though records are
# arriving. Standalone runs with `| head -3` got SIGPIPE which flushed the
# buffer — that masked this for a while.
proc main {} {
    global chan env

    if {[info exists env(AVAHI_LLAMA_BROWSE_CMD)]} {
        set cmd $env(AVAHI_LLAMA_BROWSE_CMD)
    } else {
        set cmd {stdbuf -oL avahi-browse -p -r _llama._tcp}
    }
    set chan [open "|$cmd 2>@stderr" r]
    fconfigure $chan -buffering line -blocking 0

    # Read avahi-browse as an event rather than a blocking `gets` loop, so the
    # same event loop can also watch stdin and run the renewal timer. In
    # non-blocking mode `gets` returns -1 both for "no complete line yet" and
    # for EOF; only the latter means we are done.
    fileevent $chan readable {
        if {[gets $chan line] >= 0} {
            handle_line $line
        } elseif {[eof $chan]} {
            shutdown
        }
    }

    # Exit when whoever spawned us goes away.
    #
    # Port.open/2 does not kill the external program when the port closes, so
    # a shim that never reads stdin outlives the BEAM, keeps browsing, and
    # keeps holding the stdout it inherited. That is what produces both the
    # accumulating tclsh processes and `error writing "stdout": broken pipe` —
    # and, because the inherited pipe never reaches EOF, it hangs anything
    # reading it, `mix test` included. LLMAgent.Discovery.PortAdapter kills
    # the OS process on orderly shutdown; this covers the abrupt exits where
    # terminate/2 never runs.
    fconfigure stdin -blocking 0
    fileevent stdin readable {
        if {[eof stdin]} { shutdown }
        # Nothing is expected on stdin; drain it so the handler does not respin.
        read stdin
    }

    set renew_ms 20000
    if {[info exists env(AVAHI_LLAMA_RENEW_MS)] && [string is integer -strict $env(AVAHI_LLAMA_RENEW_MS)]
        && $env(AVAHI_LLAMA_RENEW_MS) > 0} {
        set renew_ms $env(AVAHI_LLAMA_RENEW_MS)
    }
    renew_tick $renew_ms

    vwait ::forever
}

proc renew_tick {ms} {
    renew_all
    after $ms [list renew_tick $ms]
}

# Tcl does not kill a command pipeline's children when the interpreter exits,
# so exiting without this leaves avahi-browse running — the same leak one level
# down. Signal the pipeline before going.
proc shutdown {} {
    global chan
    catch {
        foreach p [pid $chan] { exec kill -TERM $p }
    }
    catch {close $chan}
    exit 0
}

if {[info exists ::argv0] &&
    [file normalize $::argv0] eq [file normalize [info script]]} {
    main
}
