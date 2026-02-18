MODULE  = matrix_generator
TB      = matrix_tb
TOP     = matrix_tb
OBJDIR  = /tmp/matrix_build
VECTORS = expected_matrix.mem

CACHE_SRC  = matrix_cache.sv
PRNG_SRC   = ../crypto/xoshiro256pp/xoshiro256pp.sv

.PHONY: all runtest wave vectors clean help

help:
	@echo "Usage:"
	@echo "  make runtest     - Generate vectors, compile, and run testbench"
	@echo "  make wave        - Generate vectors, compile, run, and open waveform"
	@echo "  make vectors     - Generate test vectors from Python reference"
	@echo "  make clean       - Remove generated files"

vectors:
	python3 gen_vectors.py

runtest: vectors
	verilator --binary --timing --trace -j 0 -Wno-fatal \
		--top-module $(TOP) --Mdir $(OBJDIR) \
		$(MODULE).sv $(CACHE_SRC) $(PRNG_SRC) $(TB).sv
	$(OBJDIR)/V$(TOP)

wave: runtest
	gtkwave $(TOP).vcd

clean:
	rm -rf $(OBJDIR) $(TOP).vcd $(VECTORS)
