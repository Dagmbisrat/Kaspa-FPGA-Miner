MODULE  = core
TOP     = core_tb
OBJDIR  = /tmp/core_build
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

.PHONY: all clean wave vectors help

help:
	@echo "Usage:"
	@echo "  make runtest     - Generate vectors, compile, and run testbench"
	@echo "  make wave        - Generate vectors, compile, run, and open waveform"
	@echo "  make vectors     - Generate test vectors from Python reference"
	@echo "  make clean       - Remove generated files"

vectors:
	python3 sim/gen_vectors.py

runtest: vectors
	verilator --binary --timing --trace -j 0 -Wno-fatal --top-module $(TOP) --Mdir $(OBJDIR) $(SRC) $(TB)
	$(OBJDIR)/V$(TOP)

wave: runtest
	gtkwave sim/$(TOP).vcd

clean:
	rm -rf $(OBJDIR) sim/$(TOP).vcd $(VECTORS)
