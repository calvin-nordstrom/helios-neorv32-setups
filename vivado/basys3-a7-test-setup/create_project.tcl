# Create Vivado project and generate bitstream
# Usage: vivado -mode batch -source create_project.tcl

set board "basys3"
# Directory of this Tcl script (works in GUI/batch)
set script_dir [file dirname [file normalize [info script]]]

# Build absolute path from the script location + relative
set repo_abs   [file normalize [file join $script_dir .. vivado-board-dependencies new board_files]]

# Set it
set_param board.repoPaths [list $repo_abs]

# Create and clear output directory
set outputdir work
file mkdir $outputdir

set files [glob -nocomplain "$outputdir/*"]
if {[llength $files] != 0} {
    puts "deleting contents of $outputdir"
    file delete -force {*}[glob -directory $outputdir *]; # clear folder contents
} else {
    puts "$outputdir is empty"
}

switch $board {
  "basys3" {
    set a7part "xc7a35tcpg236-1"
    set a7prj ${board}-test-setup
  }
}

# Create project
create_project -part $a7part $a7prj $outputdir

set_property board_part digilentinc.com:${board}:part0:1.2 [current_project]
set_property target_language VHDL [current_project]

# Define filesets
# --- Patch NEORV32 files in-place (enable GPTMR) ---
# Root of NEORV32 RTL (relative to this script)
set neorv32_rtl_dir "./../../neorv32/rtl"

# Patterns:
#  - declaration: IO_GPTMR_EN : boolean := false;
#  - generic map: IO_GPTMR_EN => false
set pattern_decl {IO_GPTMR_EN\s*:\s*boolean\s*:=\s*false}
set repl_decl    {IO_GPTMR_EN           : boolean                        := true}
set pattern_map  {IO_GPTMR_EN\s*=>\s*false}
set repl_map     {IO_GPTMR_EN      => true}

# List of files to patch: {subdir filename}
set files_to_patch {
    {core              neorv32_package.vhd}
    {core              neorv32_top.vhd}
    {system_integration neorv32_vivado_ip.vhd}
}

foreach spec $files_to_patch {
    lassign $spec subdir fname
    set file [file join $neorv32_rtl_dir $subdir $fname]

    if {![file exists $file]} {
        puts "Skipping missing file $file"
        continue
    }

    set fd [open $file r]
    set fc [read $fd]
    close $fd

    # Apply both substitutions
    set n1 [regsub -all $pattern_decl $fc $repl_decl fc]
    set n2 [regsub -all $pattern_map  $fc $repl_map  fc]

    puts "Patched [expr {$n1 + $n2}] occurrence(s) in $file"

    set fd [open $file w]
    puts -nonewline $fd $fc
    close $fd
}


## Core: NEORV32
add_files [glob ./../../neorv32/rtl/core/*.vhd]
set_property library neorv32 [get_files [glob ./../../neorv32/rtl/core/*.vhd]]

## Design: processor subsystem template (local version with modified reset polarity)
set fileset_design neorv32_test_setup_bootloader.vhd

## Constraints
set fileset_constraints [glob ./*.xdc]

## Simulation-only sources
set fileset_sim [list ./../../neorv32/sim/neorv32_tb.vhd ./../../neorv32/sim/sim_uart_rx.vhd]

# Add source files
# --- Import and patch NEORV32 bootloader template for Basys3 ---
set neorv32_dir "./../../neorv32"
set src_file "$neorv32_dir/rtl/test_setups/neorv32_test_setup_bootloader.vhd"
set dst_file "$outputdir/neorv32_test_setup_bootloader.vhd"

if {[file exists $src_file]} {
    puts "Reading and patching $src_file for Basys3..."
    set fd [open $src_file r]
    set fc [read $fd]
    close $fd

    # Adjust IMEM size
    regsub -all {IMEM_SIZE\s*:\s*natural\s*:=\s*[0-9\*]+;} \
        $fc {IMEM_SIZE       : natural := 64*1024;} fc

    # Adjust DMEM size
    regsub -all {DMEM_SIZE\s*:\s*natural\s*:=\s*[0-9\*]+} \
        $fc {DMEM_SIZE       : natural := 64*1024} fc

    # Invert reset polarity
    regsub -all {rstn_i\s*=>\s*rstn_i} \
        $fc {rstn_i      => not(rstn_i)} fc

    # Write the modified copy into the project folder
    set out_fd [open $dst_file w]
    puts -nonewline $out_fd $fc
    close $out_fd
    puts "Patched file written to $dst_file"
} else {
    puts "Source file $src_file not found — skipping patch."
}

# Make Vivado use the patched copy
set fileset_design $dst_file

## Design
add_files $fileset_design

## Constraints
add_files -fileset constrs_1 $fileset_constraints

## Simulation-only
add_files -fileset sim_1 $fileset_sim

# Run synthesis, implementation and bitstream generation
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set_param board.repoPaths “”
