# Create the isolated Vitis 2022.2 ABI-v2 candidate platform/application.
# The artifact manifest is verified before Vitis consumes the selected XSA.

set script_dir [file dirname [file normalize [info script]]]
set sw_dir [file dirname $script_dir]
set root [file dirname [file dirname $sw_dir]]
set workspace [file normalize [file join $root build_vitis_2022_2_abi_v2_candidate]]
set xsa [file normalize [file join $root build_system_xck26_kv260_abi_v2_release conv_accel_ps_dma_minimal.xsa]]
set manifest [file normalize [file join $workspace abi_v2_candidate_manifest.json]]
set check_only 0

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg in {-workspace -xsa -manifest}} {
        incr i
        if {$i >= [llength $argv]} {
            error "$arg requires a value"
        }
        set value [file normalize [lindex $argv $i]]
        switch -- $arg {
            -workspace { set workspace $value }
            -xsa { set xsa $value }
            -manifest { set manifest $value }
        }
    } elseif {$arg eq "-check_only"} {
        set check_only 1
    } else {
        error "unknown argument: $arg"
    }
}

if {[string first "abi_v2_candidate" [string tolower [file tail $workspace]]] < 0} {
    error "ABI v2 workspace basename must contain abi_v2_candidate: $workspace"
}
if {[string equal -nocase [file tail $workspace] "build_vitis_2022_2"]} {
    error "refusing to use the legacy ABI-v1 workspace: $workspace"
}
foreach {label path} [list XSA $xsa {candidate manifest} $manifest] {
    if {![file isfile $path]} {
        error "$label not found: $path"
    }
}

set python [auto_execok python]
if {$python eq ""} {
    error "python is required for ABI v2 candidate artifact verification"
}
set verifier [file join $script_dir abi_v2_candidate_artifacts.py]
if {![file isfile $verifier]} {
    error "candidate artifact verifier not found: $verifier"
}
set verify_command [list $python $verifier verify \
    --manifest $manifest --phase build \
    --expect-workspace $workspace --expect-xsa $xsa]
if {[catch {exec {*}$verify_command} verify_output]} {
    error "candidate build-input verification failed: $verify_output"
}
puts $verify_output

set fingerprint_command [list $python $verifier fingerprint --file $xsa]
if {[catch {exec {*}$fingerprint_command} xsa_sha256]} {
    error "cannot fingerprint candidate XSA: $xsa_sha256"
}
set xsa_sha256 [string trim $xsa_sha256]
if {![regexp {^[0-9a-f]{64}$} $xsa_sha256]} {
    error "candidate XSA fingerprint is malformed: $xsa_sha256"
}

set platform_name conv_accel_abi_v2_candidate_platform
set app_name conv_accel_abi_v2_candidate
set proc_name psu_cortexa53_0
set domain_name standalone_domain
set marker [file join $workspace .abi_v2_candidate_workspace]
set marker_contents "profile=abi_v2_candidate\nabi_version=2\nvitis_version=2022.2\nxsa_sha256=$xsa_sha256\n"
set platform_exists [file exists [file join $workspace $platform_name]]
set app_exists [file exists [file join $workspace $app_name]]
if {$platform_exists != $app_exists} {
    error "candidate workspace is partial; use a fresh explicit workspace: $workspace"
}
if {$platform_exists && ![file isfile $marker]} {
    error "candidate workspace has no XSA-bound marker; use a fresh explicit workspace: $workspace"
}
if {!$platform_exists && [file exists $marker]} {
    error "candidate workspace has a stale marker; use a fresh explicit workspace: $workspace"
}
if {$platform_exists} {
    set marker_stream [open $marker r]
    set actual_marker [read $marker_stream]
    close $marker_stream
    if {$actual_marker ne $marker_contents} {
        error "candidate workspace marker mismatch: $marker"
    }
}

if {$check_only} {
    puts "PASS: ABI v2 candidate project configuration"
    puts "Workspace: $workspace"
    puts "XSA: $xsa"
    puts "Manifest: $manifest"
    exit 0
}

file mkdir $workspace
setws $workspace
if {$platform_exists} {
    puts "Reusing XSA-hash-verified candidate platform/application"
} else {
    platform create -name $platform_name -hw $xsa -proc $proc_name \
        -os standalone -arch 64-bit
    platform active $platform_name
    domain active $domain_name
    platform generate
    app create -name $app_name -platform $platform_name -domain $domain_name \
        -template {Empty Application}
}
importsources -name $app_name -path [file join $sw_dir src] -soft-link
set marker_stream [open $marker w]
puts -nonewline $marker_stream $marker_contents
close $marker_stream

puts "PASS: Vitis 2022.2 ABI v2 candidate project created"
puts "Workspace: $workspace"
puts "Platform: $platform_name"
puts "Application: $app_name"
puts "XSA: $xsa"
