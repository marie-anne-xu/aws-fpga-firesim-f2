# Static checkpoint reuse helpers. Full nested implementation validation is in progress.
proc pr_reuse_one {path} {
    set literal [string map [list \\ \\\\ \" \\\"] $path]
    set cells [get_cells -hierarchical -quiet -filter [format {NAME == "%s"} $literal]]
    if {[llength $cells] != 1} {error "PR reuse: expected exactly one cell: $path"}
    return [lindex $cells 0]
}
proc pr_reuse_leaves {path} {
    return [get_cells -hierarchical -filter "NAME =~ ${path}/* && IS_PRIMITIVE == 1 && REF_NAME != VCC && REF_NAME != GND"]
}
# Imported checkpoints can retain only a subset of source placement. The
# pre-placement phases permit this, but require the native PHY and the complete
# previously failing RAM/FF groups. Source and post-place phases remain complete.
proc pr_reuse_check_critical {paths label} {
    set converter WRAPPER/CL/dwidth_adapt_64bits_512bits_0
    set cbus WRAPPER/CL/firesim_top/top/sim/target/FireSim_/chiptop0/system/cbus
    set critical {}
    if {[lsearch -exact $paths $converter] >= 0} {
        set prefix ${converter}/inst/gen_upsizer.gen_full_upsizer.axi_upsizer_inst/USE_READ.gen_pktfifo_r_upsizer.pktfifo_read_data_inst/dw_fifogen_ar/inst_fifo_gen/gaxi_full_lite.gread_ch.grach2.axi_rach/grf.rf/gntv_or_sync_fifo.mem
        lappend critical ${prefix}/gdm.dm_gen.dm/RAM_reg_0_31_14_27/RAMB
        lappend critical ${prefix}/gdm.dm_gen.dm/RAM_reg_0_31_14_27/RAMB_D1
        lappend critical ${prefix}/goreg_dm.dout_i_reg[format {[%d]} 16]
    }
    if {[lsearch -exact $paths $cbus] >= 0} {
        lappend critical ${cbus}/wrapped_error_device/buffer/nodeOut_a_q/ram_flattened_reg_0_1_98_103/RAMA_D1
        lappend critical ${cbus}/wrapped_error_device/error/a_q/ram_flattened_reg[format {[%d]} 101]
    }
    set serial WRAPPER/CL/firesim_top/top/sim/target/FireSim_/chiptop0/system/serial_tl_domain
    if {[lsearch -exact $paths $serial] >= 0} {
        lappend critical ${serial}/phy/out_phits_out_async_io_enq_q_1/ram_flattened_reg_0_7_0_13/RAMC
        lappend critical ${serial}/phy/out_phits_out_async_io_enq_flit2phit_1/data_0_reg[format {[%d]} 0]
    }
    if {[lsearch -exact $paths WRAPPER/CL/SH_DDR] >= 0} {
        set phy [get_cells -hierarchical -filter {NAME =~ WRAPPER/CL/SH_DDR/* && REF_NAME == RXTX_BITSLICE}]
        if {[llength $phy] != 124} {error "PR reuse: expected 124 native RXTX_BITSLICE cells"}
        foreach cell $phy {lappend critical [get_property NAME $cell]}
    }
    foreach name $critical {
        set cell [pr_reuse_one $name]
        set loc [get_property LOC $cell]; set bel [get_property BEL $cell]
        if {$loc eq "" || $bel eq ""} {error "PR reuse: critical placement missing: $name"}
        if {$label eq "locked_post_opt" && (![get_property IS_LOC_FIXED $cell] || ![get_property IS_BEL_FIXED $cell])} {
            error "PR reuse: critical placement lock lost: $name"
        }
        puts "PR reuse: $label critical=$name LOC=$loc BEL=$bel"
    }
}
proc pr_reuse_audit_sites {paths pblock label {require_complete auto}} {
    if {$require_complete eq "auto"} {
        # These explicit experiment phases precede placement; missing ordinary
        # placement is legal. All other callers default to complete placement.
        set require_complete [expr {$label ni {imported_before_lock locked_post_opt}}]
    }
    set pb [get_pblocks -quiet $pblock]
    if {[llength $pb] != 1 || ![get_property EXCLUDE_PLACEMENT $pb]} {error "PR reuse: exclusion missing for $pblock"}
    puts "PR reuse: $label require_complete=$require_complete GRID_RANGES=[get_property GRID_RANGES $pb] DERIVED_RANGES=[get_property DERIVED_RANGES $pb]"
    set reserved [dict create]
    foreach site [get_sites -of_objects $pb] {dict set reserved [get_property NAME $site] 1}
    if {[dict size $reserved] == 0} {error "PR reuse: empty reserved-site collection"}
    foreach path $paths {
        set leaves [pr_reuse_leaves $path]
        if {[llength $leaves] == 0} {error "PR reuse: empty physical hierarchy $path"}
        set placed 0; set unplaced 0; set aggregates 0
        foreach cell $leaves {
            set loc [get_property LOC $cell]
            if {$loc eq ""} {
                set name [get_property NAME $cell]
                if {[get_property REF_NAME $cell] eq "OBUFTDS_DUAL_BUF"} {
                    foreach suffix {N P} {
                        set child [pr_reuse_one ${name}/${suffix}]
                        if {[get_property REF_NAME $child] ne "OBUFT" || [get_property LOC $child] eq "" || [get_property BEL $child] eq ""} {
                            error "PR reuse: incomplete differential output macro $name"
                        }
                        if {[dict exists $reserved [get_property LOC $child]]} {error "PR reuse: $label aggregate child overlaps reservation: ${name}/${suffix}"}
                    }
                    incr aggregates
                    continue
                }
                incr unplaced
                if {$require_complete} {error "PR reuse: unplaced primitive $name"}
                continue
            }
            incr placed
            if {[dict exists $reserved $loc]} {error "PR reuse: $label overlap: [get_property NAME $cell] at $loc"}
        }
        puts "PR reuse: $label $path objects=[llength $leaves] placed=$placed unplaced=$unplaced aggregate_macros=$aggregates reserved_overlap=0"
    }
    if {!$require_complete} {pr_reuse_check_critical $paths $label}
    # Report constraint completeness immediately after opt, before costly P&R.
    # This does not alter constraints or weaken any placement/route gate.
    if {$label eq "locked_post_opt" && [info exists ::output_dir]} {
        pr_reuse_report_constraint_coverage $::output_dir $label
    }
}
proc pr_reuse_snapshot_ports {} {
    set snapshot [dict create]
    foreach port [get_ports] {
        set properties [dict create]
        foreach prop {PACKAGE_PIN LOC IOSTANDARD DIRECTION} {dict set properties $prop [get_property $prop $port]}
        dict set snapshot [get_property NAME $port] $properties
    }
    return $snapshot
}
proc pr_reuse_compare_ports {snapshot strict label} {
    set changed 0
    # Exact string names avoid Tcl/Vivado glob treatment of bus brackets.
    set current_ports [dict create]
    foreach port [get_ports] {dict set current_ports [get_property NAME $port] $port}
    dict for {name properties} $snapshot {
        if {![dict exists $current_ports $name]} {error "PR reuse: missing original top-level port $name"}
        set port [dict get $current_ports $name]
        dict for {prop expected} $properties {
            set actual [get_property $prop $port]
            if {$actual ne $expected} {
                incr changed
                puts "PR reuse: $label port=$name $prop source={$expected} current={$actual}"
            }
        }
    }
    if {$strict && $changed} {error "PR reuse: $label has $changed top-level IO property differences"}
    puts "PR reuse: $label top-level IO property differences=$changed"
}
proc pr_reuse_guard_static {paths child} {
    foreach path $paths {
        pr_reuse_one $path
        if {$path eq $child || [string first ${child}/ $path] == 0 || [string first ${path}/ $child] == 0} {
            error "PR reuse: static IP overlaps child hierarchy: $path / $child"
        }
    }
}

# Discover disjoint static sibling hierarchies along the child ancestor chain.
# Select distributed-memory branches; BRAM-only branches are not affected by
# the observed LUTRAM/FF placement shapes. This matches the source inventory.
proc pr_reuse_memory_branches {container child} {
    if {[string first ${container}/ $child] != 0} {error "PR reuse: child outside container"}
    set ancestors [dict create]
    set path $child
    while {$path ne $container} {
        set path [file dirname $path]
        dict set ancestors $path 1
    }
    set roots [dict create]
    foreach cell [get_cells -hierarchical -filter {IS_PRIMITIVE == 0}] {
        set name [get_property NAME $cell]
        if {[dict exists $ancestors [file dirname $name]] && ![dict exists $ancestors $name] && $name ne $child} {
            dict set roots $name 0
        }
    }
    foreach cell [get_cells -hierarchical -filter {IS_PRIMITIVE == 1}] {
        set ref [get_property REF_NAME $cell]
        if {![string match RAM* $ref] || [string match RAMB* $ref]} {continue}
        set name [get_property NAME $cell]
        foreach root [dict keys $roots] {
            if {[string first ${root}/ $name] == 0} {dict incr roots $root; break}
        }
    }
    set selected {}
    foreach root [lsort [dict keys $roots]] {
        if {[dict get $roots $root] > 0} {lappend selected $root}
    }
    # Import MIG last: importing other checkpoints after it invalidated MIG
    # IO placement in the earlier converter/DDR assembly trial.
    set ddr ${container}/SH_DDR
    set index [lsearch -exact $selected $ddr]
    if {$index >= 0} {set selected [lreplace $selected $index $index]; lappend selected $ddr}
    if {![llength $selected]} {error "PR reuse: no distributed-memory static branches"}
    pr_reuse_guard_static $selected $child
    return $selected
}

proc pr_reuse_report_constraint_coverage {out label} {
    file mkdir $out
    check_timing -verbose -file $out/${label}_check_timing.rpt
    report_clocks -file $out/${label}_clocks.rpt
    report_exceptions -coverage -file $out/${label}_exceptions_coverage.rpt
    report_exceptions -ignored -file $out/${label}_exceptions_ignored.rpt
    puts "PR reuse: $label constraint coverage reports written"
}

proc pr_reuse_interface_signature {path} {
    set signature [dict create]
    set prefix ${path}/
    foreach pin [get_pins -of_objects [pr_reuse_one $path]] {
        set name [get_property NAME $pin]
        if {[string first $prefix $name] != 0} {error "PR reuse: unexpected boundary pin $name"}
        set relative [string range $name [string length $prefix] end]
        dict set signature $relative [get_property DIRECTION $pin]
    }
    return $signature
}
proc pr_reuse_snapshot_interfaces {paths} {
    set snapshot [dict create]
    foreach path $paths {dict set snapshot $path [pr_reuse_interface_signature $path]}
    return $snapshot
}
proc pr_reuse_compare_interface {expected path label} {
    set actual [pr_reuse_interface_signature $path]
    set missing {}; set extra {}; set changed {}
    foreach name [dict keys $expected] {
        if {![dict exists $actual $name]} {lappend missing $name; continue}
        if {[dict get $actual $name] ne [dict get $expected $name]} {lappend changed $name}
    }
    foreach name [dict keys $actual] {
        if {![dict exists $expected $name]} {lappend extra $name}
    }
    if {[llength $missing] || [llength $extra] || [llength $changed]} {
        error "PR reuse: $label interface mismatch $path missing=$missing extra=$extra direction_changed=$changed"
    }
    puts "PR reuse: $label interface $path matches [dict size $expected] pins"
}
