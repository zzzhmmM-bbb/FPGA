set root [file dirname [file normalize [info script]]]
set build $root
cd [file join $build src td_project]
import_device eagle_s20.db -package EG4S20BG256
open_project HDMI1.4b_Transmitter_v1.0.al
elaborate -top top
read_adc ../user_source/constraints_source/pin.adc
read_sdc ../user_source/constraints_source/timing.sdc
read_sdc -ip rfifo_32_32_512 ../user_source/hdl_source/IP/afifo_32_16_256.tcl
read_sdc -ip wfifo_32_32_512 ../user_source/hdl_source/IP/afifo_16_32_256.tcl
# Official TD V6.2 p278: lower control-set threshold for area.
set_param rtl min_control_set 8
optimize_rtl
# Densely packed EG4S20: retain room below the router's 90% hold-fix limit.
# TD Tcl Command User Guide 4.2.2 lists high packing effort / more_lut_pair.
set_param gate pack_effort high
optimize_gate -packarea guide_gate.area
# SWUG106 section 4.2.20: local placement only; all timing checks retained.
read_adc ../user_source/constraints_source/slot_local.adc
legalize_phy_inst
write_verilog guide_mapped.v
set_param place pack_mode more_lut_pair
place
# Preserve the placed design for targeted routing diagnostics/retries.
export_db guide_placed.db
# The default automatic hold repair is skipped above 90% slice utilization.
# Request it explicitly for this densely packed EG4S20 design.
set_param route fix_hold on
set_param route effort routability
route
update_timing -mode final
report_area -io_info -file guide_phy.area
report_timing_summary -file guide_pr.timing
report_timing_status -file guide_phy.ts
export_db guide_routed.db
write_verilog guide_routed.v
report_param -detail -file guide_parameters.txt
bitgen -bit main_vowel_fixed.bit
puts "VOWEL_FIXED_BUILD_COMPLETE"
exit
