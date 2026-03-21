MODULE  = core
TOP     = core_tb
TOP_BENCH = core_bench_tb
OBJDIR  = /tmp/core_build
OBJDIR_BENCH = /tmp/core_bench_build
VECTORS = sim/expected_vectors.mem

# Dependency paths (relative to this Makefile)
KECCAK   = ../crypto/keccak
CSHAKE   = ../crypto/cshake256
XOSHIRO  = ../utils/xoshiro256pp
MATGEN   = ../matrix/matrix_generator
MATMUL   = ../matrix/matmul_unit

SRC = \
    $(KECCAK)/rtl/keccak_round.sv \
    $(KECCAK)/rtl/keccak_f1600.sv \
    $(CSHAKE)/rtl/cshake256_absorb.sv \
    $(CSHAKE)/rtl/cshake256_core.sv \
    $(XOSHIRO)/rtl/xoshiro256pp.sv \
    $(MATGEN)/rtl/matrix_rankcheck.sv \
    $(MATGEN)/rtl/matrix_generator.sv \
    $(MATMUL)/rtl/matmul_unit.sv \
    rtl/matrix_cache.sv \
    rtl/$(MODULE).sv

TB = tb/core_tb.sv

.PHONY: all clean wave vectors bench bench_wave help

help:
	@echo "Usage:"
	@echo "  make runtest     - Generate vectors, compile, and run testbench"
	@echo "  make wave        - Generate vectors, compile, run, and open waveform"
	@echo "  make vectors     - Generate test vectors from Python reference"
	@echo "  make bench       - Compile and run benchmark testbench"
	@echo "  make bench_wave  - Compile, run benchmark, and open waveform"
	@echo "  make clean       - Remove generated files"

vectors:
	python3 sim/gen_vectors.py

runtest: vectors
	verilator --binary --timing --trace -j 0 -Wno-fatal --top-module $(TOP) --Mdir $(OBJDIR) $(SRC) $(TB)
	$(OBJDIR)/V$(TOP)

wave: runtest
	gtkwave sim/$(TOP).vcd

bench:
	verilator --binary --timing --trace -j 0 -Wno-fatal --top-module $(TOP_BENCH) --Mdir $(OBJDIR_BENCH) $(SRC) tb/$(TOP_BENCH).sv
	$(OBJDIR_BENCH)/V$(TOP_BENCH)

bench_wave: bench
	gtkwave sim/$(TOP_BENCH).vcd

clean:
	rm -rf $(OBJDIR) $(OBJDIR_BENCH) sim/$(TOP).vcd sim/$(TOP_BENCH).vcd $(VECTORS)
