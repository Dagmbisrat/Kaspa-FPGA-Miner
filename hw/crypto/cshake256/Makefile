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

.PHONY: all runtest throughput wave vectors clean help

help:
	@echo "Usage:"
	@echo "  make runtest              - Generate vectors, compile, run correctness + latency"
	@echo "  make throughput           - Throughput sweep across 7 batch sizes"
	@echo "  make throughput CLK_MHZ=N - Throughput sweep at N MHz (default 500)"
	@echo "  make wave                 - Run and open waveform in GTKWave"
	@echo "  make vectors              - Regenerate test vectors from Python reference"
	@echo "  make clean                - Remove generated files"

vectors:
	python3 sim/gen_vectors.py

$(OBJDIR)/V$(TOP): $(SRC) $(TB)
	verilator --binary --timing --trace -j 0 -Wno-fatal \
	          --top-module $(TOP) --Mdir $(OBJDIR) $(SRC) $(TB)

runtest: vectors $(OBJDIR)/V$(TOP)
	$(OBJDIR)/V$(TOP)

$(OBJDIR_TP)/V$(TOP_TP): $(SRC) $(TB_TP)
	verilator --binary --timing -j 0 -Wno-fatal \
	          --top-module $(TOP_TP) --Mdir $(OBJDIR_TP) $(SRC) $(TB_TP)

throughput: $(OBJDIR_TP)/V$(TOP_TP)
	$(OBJDIR_TP)/V$(TOP_TP) +clk_mhz=$(CLK_MHZ) +s_value=1

wave: runtest
	gtkwave sim/$(TOP).vcd

clean:
	rm -rf $(OBJDIR) $(OBJDIR_TP) sim/$(TOP).vcd sim/$(TOP_TP).vcd $(VECTORS)
