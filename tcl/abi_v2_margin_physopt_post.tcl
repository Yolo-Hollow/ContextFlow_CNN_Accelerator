# ABI-v2 release post-phys-opt margin pass.
#
# The managed implementation run performs its first AggressiveExplore pass
# before sourcing this hook.  Vivado 2022.2 only optimizes setup paths with
# negative slack, so temporarily set 0.450 ns of setup uncertainty on the
# clock that actually reaches the accelerator.  The formal 200 MHz topology
# must resolve a 5 ns generated clock; legacy release and development-sweep
# profiles retain their dynamically resolved direct clocks.  Restore the saved
# constraint before the managed phys-opt checkpoint and route_design.

set margin_accelerator_cells [get_cells -quiet -hier -filter \
    {NAME =~ "*/accel/inst"}]
if {[llength $margin_accelerator_cells] != 1} {
    error "ABI-v2 margin phys-opt resolved [llength $margin_accelerator_cells] accelerator cells; expected exactly one"
}
set margin_accelerator_cell [get_property NAME \
    [lindex $margin_accelerator_cells 0]]
set margin_accelerator_registers [get_cells -quiet -hier -filter \
    "NAME =~ $margin_accelerator_cell/* && (REF_NAME == FDRE || REF_NAME == FDSE)"]
set margin_accelerator_clock_pins [get_pins -quiet -of_objects \
    $margin_accelerator_registers -filter {REF_PIN_NAME == C}]
if {[llength $margin_accelerator_clock_pins] == 0} {
    error "ABI-v2 margin phys-opt found no accelerator clock pins"
}

set margin_clock_names [list]
foreach margin_accelerator_clock_pin $margin_accelerator_clock_pins {
    foreach margin_clock_object [get_clocks -quiet -of_objects \
            $margin_accelerator_clock_pin] {
        set margin_clock_name [get_property NAME $margin_clock_object]
        if {$margin_clock_name ne "" &&
            [lsearch -exact $margin_clock_names $margin_clock_name] < 0} {
            lappend margin_clock_names $margin_clock_name
        }
    }
}
set margin_clock_names [lsort $margin_clock_names]
if {[llength $margin_clock_names] != 1} {
    error "ABI-v2 margin phys-opt accelerator resolves clocks '$margin_clock_names'; expected exactly one"
}
set margin_clocks [get_clocks -quiet [lindex $margin_clock_names 0]]
if {[llength $margin_clocks] != 1} {
    error "ABI-v2 margin phys-opt resolved [llength $margin_clocks] clock objects for '[lindex $margin_clock_names 0]'; expected exactly one"
}
set margin_clock [lindex $margin_clocks 0]
set margin_clock_name [get_property NAME $margin_clock]
set margin_clock_period [get_property PERIOD $margin_clock]
set margin_clock_is_generated [get_property -quiet IS_GENERATED $margin_clock]
if {![string is double -strict $margin_clock_period]} {
    error "ABI-v2 margin phys-opt accelerator clock $margin_clock_name has non-numeric period '$margin_clock_period'"
}
if {![string is boolean -strict $margin_clock_is_generated]} {
    error "ABI-v2 margin phys-opt accelerator clock $margin_clock_name has invalid IS_GENERATED='$margin_clock_is_generated'"
}
if {$margin_clock_is_generated &&
    abs(double($margin_clock_period) - 5.000) > 0.001} {
    error "ABI-v2 margin phys-opt generated accelerator clock $margin_clock_name period=$margin_clock_period ns; expected 5.000 +/- 0.001 ns"
}

set margin_pre_paths [get_timing_paths -quiet -delay_type max \
    -from $margin_clock -to $margin_clock -max_paths 1]
if {[llength $margin_pre_paths] != 1} {
    error "ABI-v2 margin phys-opt could not resolve the pre-pass setup path on $margin_clock_name"
}
set margin_saved_uu [get_property USER_UNCERTAINTY \
    [lindex $margin_pre_paths 0]]
if {$margin_saved_uu eq ""} {
    set margin_saved_uu 0.000
}
if {![string is double -strict $margin_saved_uu]} {
    error "ABI-v2 margin phys-opt cannot save USER_UNCERTAINTY=$margin_saved_uu ns on $margin_clock_name"
}
set margin_pre_wns [get_property SLACK [lindex $margin_pre_paths 0]]
puts "ABI-v2 margin phys-opt: clock=$margin_clock_name period_ns=$margin_clock_period generated=$margin_clock_is_generated saved_USER_UNCERTAINTY=$margin_saved_uu ns pre-pass WNS=$margin_pre_wns ns"

set margin_failed [catch {
    set_clock_uncertainty -setup 0.450 $margin_clock
    set margin_tight_paths [get_timing_paths -quiet -delay_type max \
        -from $margin_clock -to $margin_clock -max_paths 1]
    if {[llength $margin_tight_paths] != 1} {
        error "ABI-v2 margin phys-opt could not resolve the tightened setup path on $margin_clock_name"
    }
    set margin_tight_uu [get_property USER_UNCERTAINTY \
        [lindex $margin_tight_paths 0]]
    if {![string is double -strict $margin_tight_uu] ||
        double($margin_tight_uu) != 0.450} {
        error "ABI-v2 margin phys-opt applied USER_UNCERTAINTY=$margin_tight_uu; expected exactly 0.450 ns on $margin_clock_name"
    }
    puts "ABI-v2 margin phys-opt: tightened pre-pass USER_UNCERTAINTY=$margin_tight_uu ns WNS=[get_property SLACK [lindex $margin_tight_paths 0]] ns"

    phys_opt_design -directive AggressiveExplore

    set margin_tight_post_paths [get_timing_paths -quiet -delay_type max \
        -from $margin_clock -to $margin_clock -max_paths 1]
    if {[llength $margin_tight_post_paths] != 1} {
        error "ABI-v2 margin phys-opt could not resolve the tightened post-pass setup path on $margin_clock_name"
    }
    set margin_tight_post_uu [get_property USER_UNCERTAINTY \
        [lindex $margin_tight_post_paths 0]]
    if {![string is double -strict $margin_tight_post_uu] ||
        double($margin_tight_post_uu) != 0.450} {
        error "ABI-v2 margin phys-opt post-pass USER_UNCERTAINTY=$margin_tight_post_uu; expected exactly 0.450 ns on $margin_clock_name"
    }
    puts "ABI-v2 margin phys-opt: tightened post-pass USER_UNCERTAINTY=$margin_tight_post_uu ns WNS=[get_property SLACK [lindex $margin_tight_post_paths 0]] ns"
} margin_error margin_options]

# Tcl 8.5 has no try/finally.  Restore and verify the saved release constraint
# unconditionally, then propagate any failure from the tightened pass.
set margin_restore_failed [catch {
    set_clock_uncertainty -setup $margin_saved_uu $margin_clock
    set margin_post_paths [get_timing_paths -quiet -delay_type max \
        -from $margin_clock -to $margin_clock -max_paths 1]
    if {[llength $margin_post_paths] != 1} {
        error "ABI-v2 margin phys-opt could not resolve the restored setup path on $margin_clock_name"
    }
    set margin_restored_uu [get_property USER_UNCERTAINTY \
        [lindex $margin_post_paths 0]]
    if {$margin_restored_uu eq ""} {
        set margin_restored_uu 0.000
    }
    if {![string is double -strict $margin_restored_uu] ||
        double($margin_restored_uu) != double($margin_saved_uu)} {
        error "ABI-v2 margin phys-opt restored USER_UNCERTAINTY=$margin_restored_uu ns; expected saved value $margin_saved_uu ns on $margin_clock_name"
    }
    puts "ABI-v2 margin phys-opt: restored USER_UNCERTAINTY=$margin_restored_uu ns actual WNS=[get_property SLACK [lindex $margin_post_paths 0]] ns"
} margin_restore_error margin_restore_options]
if {$margin_restore_failed} {
    return -options $margin_restore_options \
        "ABI-v2 margin phys-opt failed to restore setup uncertainty: $margin_restore_error"
}
if {$margin_failed} {
    return -options $margin_options $margin_error
}
