cd overlay
source design_1_wrapper.tcl
add_files -norecurse [make_wrapper -files [get_files "[current_bd_design].bd"] -top]
update_compile_order -fileset sources_1
set_property top design_1_wrapper [current_fileset]
launch_runs impl_1 -to_step write_bitstream
wait_on_run impl_1
file copy -force ./myproj/project_1.runs/impl_1/design_1_wrapper.bit design_1_wrapper.bit
file copy -force ./myproj/project_1.srcs/sources_1/bd/design_1/hw_handoff/design_1.hwh design_1_wrapper.hwh
close_project
