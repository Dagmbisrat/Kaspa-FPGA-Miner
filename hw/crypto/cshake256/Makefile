MODULE  = cshake256_core
KECCAK  = ../keccak
# Pipelined core instantiates keccak_round directly —
# keccak_f1600.sv and cshake256_absorb.sv are no longer needed.
SRC     = $(KECCAK)/rtl/keccak_round.sv rtl/$(MODULE).sv
TB      = tb/cshake256_tb.sv
TB_TP   = tb/throughput_tb.sv
TOP     = cshake256_tb
TOP_TP  = throughput_tb
OBJDIR    = /tmp/cshake256_build
OBJDIR_TP = /tmp/cshake256_tp_build
VECTORS = sim/expected_vectors.mem

CLK_MHZ ?= 500
JOBS    ?= 4
NUM_STAGES ?= 24

.PHONY: all runtest throughput wave vectors clean help

help:
	@echo "Targets:"
	@echo "  make runtest     - Generate vectors, build, run correctness + latency"
	@echo "  make throughput  - Build + run the throughput / timing benchmark"
	@echo "  make wave        - Run correctness TB and open the waveform in GTKWave"
	@echo "  make vectors     - Regenerate test vectors from the Python reference"
	@echo "  make clean       - Remove build dirs, waveforms, and vectors"
	@echo ""
	@echo "Variables (make TARGET VAR=value):"
	@echo "  NUM_STAGES=$(NUM_STAGES)  - Keccak pipeline layers; must divide 24 (1,2,3,4,6,8,12,24)"
	@echo "                  sets ROUNDS_PER_STAGE = 24/NUM_STAGES = critical-path / Fmax knob"
	@echo "  CLK_MHZ=$(CLK_MHZ)    - Assumed clock for the throughput MH/s column"
	@echo "  JOBS=$(JOBS)        - Parallel Verilator / C++ build jobs"
	@echo ""
	@echo "throughput plusarg: +clk_mhz=N   (hash mode is compile-time: -GS_VALUE=0|1 -GDATA_80BYTE=0|1)"

vectors:
	python3 sim/gen_vectors.py

$(OBJDIR)/V$(TOP): $(SRC) $(TB)
	verilator --binary --timing --trace -j $(JOBS) -Wno-fatal -GNUM_STAGES=$(NUM_STAGES) \
	          --top-module $(TOP) --Mdir $(OBJDIR) $(SRC) $(TB)

runtest: vectors $(OBJDIR)/V$(TOP)
	$(OBJDIR)/V$(TOP)
	@python3 ../../tools/fpga_estimate.py cshake256_pipelined_core NUM_STAGES=$(NUM_STAGES)

$(OBJDIR_TP)/V$(TOP_TP): $(SRC) $(TB_TP)
	verilator --binary --timing -j $(JOBS) -Wno-fatal -GNUM_STAGES=$(NUM_STAGES) \
	          --top-module $(TOP_TP) --Mdir $(OBJDIR_TP) $(SRC) $(TB_TP)

throughput: $(OBJDIR_TP)/V$(TOP_TP)
	$(OBJDIR_TP)/V$(TOP_TP) +clk_mhz=$(CLK_MHZ)

wave: runtest
	gtkwave sim/$(TOP).vcd

clean:
	rm -rf $(OBJDIR) $(OBJDIR_TP) sim/$(TOP).vcd sim/$(TOP_TP).vcd $(VECTORS)
