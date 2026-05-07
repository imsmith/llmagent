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
# See docs/superpowers/specs/2026-05-07-mdns-llm-discovery.md.

package require Tcl 8.6

# In-memory map: instance-key -> ad-id, so we can emit :expire on goodbye
# records (which lack the resolved fields).
array set instances {}

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

proc emit_register {ad_id host addr port txt} {
    set model  [expr {[dict exists $txt model]  ? [dict get $txt model]  : ""}]
    set n_ctx  [expr {[dict exists $txt n_ctx]  ? [dict get $txt n_ctx]  : "0"}]
    set slots  [expr {[dict exists $txt slots]  ? [dict get $txt slots]  : "1"}]
    set api    [expr {[dict exists $txt api]    ? [dict get $txt api]    : ""}]
    set status [expr {[dict exists $txt status] ? [dict get $txt status] : "ok"}]

    if {$api ne "openai-compatible"} { return }
    if {$status ne "ok"} { return }

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

    puts "{:event :register :ad $ad}"
    flush stdout
}

proc emit_expire {ad_id} {
    puts "{:event :expire :id [edn_str $ad_id]}"
    flush stdout
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
            set instances($key) $id
            emit_register $id $host $addr $port $txt
        }
        "-" {
            if {[info exists instances($key)]} {
                emit_expire $instances($key)
                unset instances($key)
            }
        }
        default {}
    }
}

# Spawn avahi-browse as a child. -p parsable, -r resolve, no -t (long-running).
set browse "|avahi-browse -p -r _llama._tcp 2>@stderr"
set chan [open $browse r]
fconfigure $chan -buffering line

while {[gets $chan line] >= 0} {
    handle_line $line
}

close $chan
