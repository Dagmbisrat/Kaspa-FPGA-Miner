# Miner floorplan (implementation only - build.tcl reads it after synthesis,
# so REUSE_SYNTH builds pick it up too).
#
# Each folded cSHAKE (~9.6k LUTs, 4 chained Keccak rounds) gets its own
# region at ~2x its size, reserved for it alone (EXCLUDE_PLACEMENT). Unconstrained,
# the placer packed Cshake2 too tightly at the top of the chip and routing
# ran out of tracks there. Slice rows 50 per clock region, 4 LUTs per slice.

# Top-left, clock regions X0Y5-X0Y6: 80 x 60 slices = 19.2k LUTs
create_pblock pb_cshake2
add_cells_to_pblock pb_cshake2 [get_cells u_miner/u_core/Cshake2]
resize_pblock pb_cshake2 -add {SLICE_X0Y290:SLICE_X79Y349}
set_property EXCLUDE_PLACEMENT 1 [get_pblocks pb_cshake2]

# Top-right, clock regions X1Y5-X1Y6: 66 x 70 slices = 18.5k LUTs
create_pblock pb_cshake1
add_cells_to_pblock pb_cshake1 [get_cells u_miner/u_core/Cshake1]
resize_pblock pb_cshake1 -add {SLICE_X80Y280:SLICE_X145Y349}
set_property EXCLUDE_PLACEMENT 1 [get_pblocks pb_cshake1]
