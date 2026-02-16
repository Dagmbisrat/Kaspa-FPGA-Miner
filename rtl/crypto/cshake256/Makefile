MODULE  = cshake256_core
KECCAK  = ../keccak
SRC     = $(KECCAK)/keccak_round.sv $(KECCAK)/keccak_f1600.sv cshake256_absorb.sv $(MODULE).sv
TB      = cshake256_tb.sv
TOP     = cshake256_tb
OBJDIR  = /tmp/cshake256_build
VECTORS = expected_vectors.mem

.PHONY: all clean wave vectors help

help:
	@echo "Usage:"
	@echo "  make runtest     - Generate vectors, compile, and run testbench"
	@echo "  make wave        - Generate vectors, compile, run, and open waveform"
	@echo "  make vectors     - Generate test vectors from Python reference"
	@echo "  make clean       - Remove generated files"

vectors:
	python3 gen_vectors.py

runtest: vectors
	verilator --binary --timing --trace -j 0 -Wno-fatal --top-module $(TOP) --Mdir $(OBJDIR) $(SRC) $(TB)
	$(OBJDIR)/V$(TOP)

wave: runtest
	gtkwave $(TOP).vcd

clean:
	rm -rf $(OBJDIR) $(TOP).vcd $(VECTORS)
