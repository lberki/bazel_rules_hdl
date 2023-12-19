# Default Yosys synthesis tcl script for the synthesize_rtl rule.
# It can be replaced by a user-defined script by overriding the synth_tcl
# argument of that rule.

# User-defined synthesis scripts need to consult the following environment
# variables for their parameters:
# FLIST = a file that lists verilog sources (one file per line)
# TOP = top module for synthesis
# LIBERTY = liberty file for the target technology library
# OUTPUT = verilog file for synthesis output
# STATS_JSON = json file for structured stats output

yosys -import

# read design
set srcs_flist_path $::env(FLIST)
set srcs_flist_file [open $srcs_flist_path "r"]
set srcs_flist_data [read $srcs_flist_file]
set srcs [split $srcs_flist_data "\n"]
puts $srcs
foreach src $srcs {
    # Skip empty lines, including the implict one after the last \n delimiter
    # for files that end with a newline.
    if {$src eq ""} continue
    if {[info exists ::env(USE_SURELOG_FRONTEND)]} {
      yosys read_systemverilog $src
    } else {
      yosys read_verilog -sv -defer $src
    }
}

# read UHDM designs
set srcs_uhdm_flist_path $::env(UHDM_FLIST)
set srcs_uhdm_flist_file [open $srcs_uhdm_flist_path "r"]
set srcs_uhdm_flist_data [read $srcs_uhdm_flist_file]
set srcs [split $srcs_uhdm_flist_data "\n"]
puts $srcs
foreach src $srcs {
    # Skip empty lines, including the implict one after the last \n delimiter
    # for files that end with a newline.
    if {$src eq ""} continue
    read_uhdm $src
}

# generic synthesis
set top $::env(TOP)
hierarchy -check -top $top
# Move proc_mux at the end of `yosys proc` to avoid inferred latches.
# See https://github.com/YosysHQ/yosys/issues/3456
# Ideally the bug would be solved in UHDM/Yosys.
yosys proc -nomux
yosys proc_mux
yosys flatten

# Remove $print cells.  These cells represent Verilog $display() tasks.
# Some place and route tools cannot handle these in the output Verilog,
# so remove them here.
yosys delete {*/t:$print}

# Remove internal only aliases for public nets and then give created instances
# useful names. At this stage it is mainly flipflops created by the `proc`
# pass.
yosys opt_clean -purge
yosys autoname

yosys synth -top $top

# Remove internal only aliases for public nets and then give created instances
# useful names. At this stage it is all the other synthesizable constructs.
# This should be done before techmapping where things can be converted
# dramatically and having useful names is helpful for debugging.
yosys opt_clean -purge
yosys autoname

# mapping to liberty
set liberty $::env(LIBERTY)
dfflibmap -liberty $liberty

if { [info exists ::env(CLOCK_PERIOD) ] } {
  abc -liberty $liberty -dff -g aig -D $::env(CLOCK_PERIOD) {*}$::env(DONT_USE_ARGS)
} else {
  abc -liberty $liberty -dff -g aig {*}$::env(DONT_USE_ARGS)
}

setundef -zero
splitnets
opt_clean -purge

if {[info exists ::env(TIEHI_CELL_AND_PORT)] && [info exists ::env(TIELO_CELL_AND_PORT)]} {
  hilomap \
        -hicell {*}[split $::env(TIEHI_CELL_AND_PORT) "/"] \
        -locell {*}[split $::env(TIELO_CELL_AND_PORT) "/"]
} elseif { [info exists ::env(TIEHI_CELL_AND_PORT)] } {
  hilomap \
        -hicell {*}$::env(TIEHI_CELL_AND_PORT)
} elseif { [info exists ::env(TIELO_CELL_AND_PORT)] } {
  hilomap \
        -locell {*}$::env(TIELO_CELL_AND_PORT)
}

# Remove internal only aliases for public nets and then give created instances
# useful names. At this stage it is anything generated by the techmapping
# passes.
yosys opt_clean -purge
yosys autoname

# write synthesized design
set output $::env(OUTPUT)
write_verilog $output

# ====== print stats / info ======
stat -liberty $liberty
if { [info exists ::env(STATS_JSON) ] } {
  tee -q -o $::env(STATS_JSON) stat -liberty $liberty -json
  yosys log Structured stats: $::env(STATS_JSON)
}
read_liberty -lib -ignore_miss_func $liberty
ltp -noff $top

yosys log -n Flop count:\
yosys select -count t:*__df* t:DFF* t:*_DFF* t:*_SDFF* t:*_ADFF* t:*dff

set base_liberty [file tail $liberty]
yosys log Liberty: $base_liberty
