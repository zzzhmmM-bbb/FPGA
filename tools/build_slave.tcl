# Slave board (board2.al) build script.
# board2.al already contains the copied sources/assets and include directories.
set root [file dirname [file normalize [info script]]]
cd $root
import_device eagle_s20.db -package EG4S20BG256
open_project board2.al
elaborate -top board2_top
read_adc pin.adc
read_sdc timing.sdc
if {[info exists ::env(BUILD_CHECK_ONLY)] && $::env(BUILD_CHECK_ONLY) eq "1"} {
    puts "PROJECT_CHECK_PASS"
    exit
}
set_param gate eram_init on
optimize_rtl
report_area -file board2_rtl.area
optimize_gate -packarea board2_gate.area
legalize_phy_inst
place
route
update_timing -mode final
report_area -io_info -file board2_phy.area
report_timing_summary -file board2_pr.timing
report_timing_status -file board2_phy.ts
bitgen -bit slave_v26_local.bit
puts "SLAVE_BUILD_COMPLETE"
exit
