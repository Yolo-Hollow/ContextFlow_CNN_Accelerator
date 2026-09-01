# Structural sign-off checks for the 32-lane DSP48E2 scalar cascade.
#
# Source this file after synth_design (and optionally place_design), then call:
#
#   ::dsp_cascade_checks::check u_array 18 16 1
#
# array_cell_path may be empty when the current design's top itself is the
# cascade array.  The procedure raises a Tcl error on the first failed gate
# and returns a summary dictionary on success.
namespace eval ::dsp_cascade_checks {
    namespace export check
}

proc ::dsp_cascade_checks::_fail {message} {
    error "DSP_CASCADE_CHECK failed: $message"
}

proc ::dsp_cascade_checks::_pin_map {cell pin_base expected_width} {
    set pins [get_pins -quiet -of_objects $cell \
        -filter [format {REF_PIN_NAME =~ "%s*"} $pin_base]]
    if {[llength $pins] != $expected_width} {
        set cell_name [get_property NAME $cell]
        ::dsp_cascade_checks::_fail \
            "$cell_name has [llength $pins] $pin_base pins, expected $expected_width"
    }

    array set mapped {}
    foreach pin $pins {
        set ref_pin [get_property REF_PIN_NAME $pin]
        if {![regexp [format {^%s\[([0-9]+)\]$} $pin_base] \
                $ref_pin -> bit]} {
            ::dsp_cascade_checks::_fail \
                "unexpected $pin_base pin spelling '$ref_pin'"
        }
        if {[info exists mapped($bit)]} {
            ::dsp_cascade_checks::_fail \
                "duplicate $pin_base\[$bit\] on [get_property NAME $cell]"
        }
        set mapped($bit) $pin
    }
    for {set bit 0} {$bit < $expected_width} {incr bit} {
        if {![info exists mapped($bit)]} {
            ::dsp_cascade_checks::_fail \
                "missing $pin_base\[$bit\] on [get_property NAME $cell]"
        }
    }
    return [array get mapped]
}

proc ::dsp_cascade_checks::_check_adjacent {source_cell sink_cell lane row} {
    array set source_pins \
        [::dsp_cascade_checks::_pin_map $source_cell PCOUT 48]
    array set sink_pins \
        [::dsp_cascade_checks::_pin_map $sink_cell PCIN 48]

    # Exact bit-for-bit verification also proves that no accidental bus
    # permutation was introduced while rebuilding hierarchy.
    set source_cell_name [get_property NAME $source_cell]
    set sink_cell_name [get_property NAME $sink_cell]
    for {set bit 0} {$bit < 48} {incr bit} {
        # Rebuilt hierarchy gives every module boundary its own logical net
        # segment.  -segments expands either endpoint to the same complete
        # connection instead of incorrectly comparing only the local names.
        set source_nets [get_nets -quiet -segments \
            -of_objects $source_pins($bit)]
        set sink_nets [get_nets -quiet -segments \
            -of_objects $sink_pins($bit)]
        if {[llength $source_nets] < 1} {
            ::dsp_cascade_checks::_fail \
                "lane $lane row $row PCOUT\[$bit\] is disconnected"
        }
        if {[llength $sink_nets] < 1} {
            ::dsp_cascade_checks::_fail \
                "lane $lane row [expr {$row + 1}] PCIN\[$bit\] is disconnected"
        }
        set source_segment_names [lsort [get_property NAME $source_nets]]
        set sink_segment_names [lsort [get_property NAME $sink_nets]]
        if {$source_segment_names ne $sink_segment_names} {
            ::dsp_cascade_checks::_fail \
                "lane $lane rows $row->[expr {$row + 1}] bit $bit does not use one PCOUT/PCIN net"
        }

        set loads [get_pins -quiet -leaf -of_objects $source_nets \
            -filter {DIRECTION == IN}]
        set drivers [get_pins -quiet -leaf -of_objects $source_nets \
            -filter {DIRECTION == OUT}]
        set expected_sink_ref [format {PCIN[%d]} $bit]
        set expected_source_ref [format {PCOUT[%d]} $bit]
        set load_ok [expr {
            [llength $loads] == 1 &&
            [string first "${sink_cell_name}/" [get_property NAME $loads]] == 0 &&
            [get_property REF_PIN_NAME $loads] eq $expected_sink_ref}]
        set driver_ok [expr {
            [llength $drivers] == 1 &&
            [string first "${source_cell_name}/" [get_property NAME $drivers]] == 0 &&
            [get_property REF_PIN_NAME $drivers] eq $expected_source_ref}]
        if {!$load_ok || !$driver_ok} {
            set load_names {}
            foreach load $loads {
                lappend load_names [get_property NAME $load]
            }
            set driver_names {}
            foreach driver $drivers {
                lappend driver_names [get_property NAME $driver]
            }
            ::dsp_cascade_checks::_fail \
                "lane $lane row $row PCOUT\[$bit\] drivers '$driver_names' loads '$load_names'; expected one source/sink leaf pair"
        }
    }
}

proc ::dsp_cascade_checks::check {array_cell_path rows cols placed} {
    if {![string is integer -strict $rows] || $rows < 1} {
        ::dsp_cascade_checks::_fail "ROWS must be a positive integer"
    }
    if {![string is integer -strict $cols] || $cols < 1} {
        ::dsp_cascade_checks::_fail "COLS must be a positive integer"
    }
    if {![string is boolean -strict $placed]} {
        ::dsp_cascade_checks::_fail "placed must be a Tcl boolean"
    }
    set placed [expr {$placed ? 1 : 0}]

    set scope ""
    if {$array_cell_path ne "" && $array_cell_path ne "."} {
        set scope_cells [get_cells -quiet $array_cell_path]
        if {[llength $scope_cells] != 1} {
            ::dsp_cascade_checks::_fail \
                "array path '$array_cell_path' resolved to [llength $scope_cells] cells"
        }
        set scope [get_property NAME $scope_cells]
    }

    set dsp_cells {}
    foreach cell [get_cells -quiet -hier -filter {REF_NAME == DSP48E2}] {
        set cell_name [get_property NAME $cell]
        if {$scope eq "" || [string match "${scope}/*" $cell_name]} {
            lappend dsp_cells $cell
        }
    }

    set lanes [expr {$cols * 2}]
    set expected_dsps [expr {$rows * $lanes}]
    if {[llength $dsp_cells] != $expected_dsps} {
        ::dsp_cascade_checks::_fail \
            "scope '$scope' has [llength $dsp_cells] DSP48E2 cells, expected $expected_dsps"
    }

    array set stage_cell {}
    array set lane_count {}
    foreach cell $dsp_cells {
        set cell_name [get_property NAME $cell]
        if {![regexp {lane_gen\[([0-9]+)\].*u_lane/.*row_stage\[([0-9]+)\].*u_mac_stage/u_dsp48e2$} \
                $cell_name -> lane row]} {
            ::dsp_cascade_checks::_fail \
                "DSP '$cell_name' does not match lane_gen/u_lane/row_stage hierarchy"
        }
        if {$lane < 0 || $lane >= $lanes || $row < 0 || $row >= $rows} {
            ::dsp_cascade_checks::_fail \
                "DSP '$cell_name' decoded out-of-range lane=$lane row=$row"
        }
        set key "$lane,$row"
        if {[info exists stage_cell($key)]} {
            ::dsp_cascade_checks::_fail \
                "duplicate DSP for lane $lane row $row"
        }
        set stage_cell($key) $cell
        if {![info exists lane_count($lane)]} {
            set lane_count($lane) 0
        }
        incr lane_count($lane)
    }

    for {set lane 0} {$lane < $lanes} {incr lane} {
        if {![info exists lane_count($lane)] ||
            $lane_count($lane) != $rows} {
            set actual 0
            if {[info exists lane_count($lane)]} {
                set actual $lane_count($lane)
            }
            ::dsp_cascade_checks::_fail \
                "lane $lane has $actual DSP stages, expected $rows"
        }
        for {set row 0} {$row < $rows} {incr row} {
            if {![info exists stage_cell($lane,$row)]} {
                ::dsp_cascade_checks::_fail \
                    "lane $lane is missing row $row"
            }
        }
    }

    set checked_links 0
    for {set lane 0} {$lane < $lanes} {incr lane} {
        for {set row 0} {$row < $rows - 1} {incr row} {
            ::dsp_cascade_checks::_check_adjacent \
                $stage_cell($lane,$row) \
                $stage_cell($lane,[expr {$row + 1}]) \
                $lane $row
            incr checked_links
        }
    }

    set placed_lanes 0
    if {$placed} {
        for {set lane 0} {$lane < $lanes} {incr lane} {
            set lane_x ""
            set previous_y ""
            for {set row 0} {$row < $rows} {incr row} {
                set loc [get_property LOC $stage_cell($lane,$row)]
                if {![regexp {^DSP48E2_X([0-9]+)Y([0-9]+)$} \
                        $loc -> x y]} {
                    ::dsp_cascade_checks::_fail \
                        "lane $lane row $row has invalid/unplaced LOC '$loc'"
                }
                if {$row == 0} {
                    set lane_x $x
                } elseif {$x != $lane_x} {
                    ::dsp_cascade_checks::_fail \
                        "lane $lane changes DSP column X$lane_x -> X$x at row $row"
                }
                if {$row > 0 && abs($y - $previous_y) != 1} {
                    ::dsp_cascade_checks::_fail \
                        "lane $lane rows [expr {$row - 1}]->$row use non-contiguous Y$previous_y/Y$y"
                }
                set previous_y $y
            }
            incr placed_lanes
        }
    }

    set summary [dict create \
        scope $scope rows $rows cols $cols lanes $lanes \
        dsp_count [llength $dsp_cells] cascade_links $checked_links \
        placed_checked $placed placed_lanes $placed_lanes]
    puts "DSP_CASCADE_CHECK PASS scope='$scope' rows=$rows cols=$cols lanes=$lanes dsp=[llength $dsp_cells] links=$checked_links placed=$placed"
    return $summary
}
