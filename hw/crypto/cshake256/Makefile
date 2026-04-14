MODULE  = cshake256_core
KECCAK  = ../keccak
# Pipelined core instantiates keccak_round directly —
# keccak_f1600.sv and cshake256_absorb.sv are no longer needed.
SRC     = $(KECCAK)/rtl/keccak_round.sv rtl/$(MODULE).sv
TB      = tb/cshake256_tb.sv
TOP     = cshake256_tb
OBJDIR  = /tmp/cshake256_build
VECTORS = sim/expected_vectors.mem

# Throughput benchmark parameters (override on command line if desired)
BENCH_ITERS ?= 500
CLK_MHZ     ?= 500

.PHONY: all runtest bench wave vectors clean help

help:
	@echo "Usage:"
	@echo "  make runtest              - Generate vectors, compile, run correctness + latency"
	@echo "  make bench                - Same as runtest + throughput benchmark"
	@echo "  make bench BENCH_ITERS=N  - Benchmark with N back-to-back hashes (default 500)"
	@echo "  make bench CLK_MHZ=N      - Report throughput at N MHz (default 500)"
	@echo "  make wave                 - Run and open waveform in GTKWave"
	@echo "  make vectors              - Regenerate test vectors from Python reference"
	@echo "  make clean                - Remove generated files"

vectors:
	python3 sim/gen_vectors.py

# Compile once; both runtest and bench share the binary
$(OBJDIR)/V$(TOP): $(SRC) $(TB)
	verilator --binary --timing --trace -j 0 -Wno-fatal \
	          --top-module $(TOP) --Mdir $(OBJDIR) $(SRC) $(TB)

runtest: vectors $(OBJDIR)/V$(TOP)
	$(OBJDIR)/V$(TOP)

bench: vectors $(OBJDIR)/V$(TOP)
	$(OBJDIR)/V$(TOP) +bench +bench_iters=$(BENCH_ITERS) +clk_mhz=$(CLK_MHZ)

wave: runtest
	gtkwave sim/$(TOP).vcd

clean:
	rm -rf $(OBJDIR) sim/$(TOP).vcd $(VECTORS)
