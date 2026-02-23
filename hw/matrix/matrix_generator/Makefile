MODULE  = matrix_generator
TB      = matrix_tb
TOP     = matrix_tb
OBJDIR  = /tmp/matrix_build
VECTORS = sim/expected_matrix.mem

CACHE_SRC  = ../../core/rtl/matrix_cache.sv
PRNG_SRC   = ../../utils/xoshiro256pp/rtl/xoshiro256pp.sv

RANK_OBJDIR = /tmp/matrix_rank_build

.PHONY: all runtest wave vectors ranktest clean help

help:
	@echo "Usage:"
	@echo "  make runtest     - Generate vectors, compile, and run testbench"
	@echo "  make wave        - Generate vectors, compile, run, and open waveform"
	@echo "  make vectors     - Generate test vectors from Python reference"
	@echo "  make ranktest    - Compile and run rank-check unit testbench"
	@echo "  make clean       - Remove generated files"

vectors:
	python3 sim/gen_vectors.py

runtest: vectors
	verilator --binary --timing --trace -j 0 -Wno-fatal \
		--top-module $(TOP) --Mdir $(OBJDIR) \
		rtl/$(MODULE).sv rtl/matrix_rankcheck.sv $(CACHE_SRC) $(PRNG_SRC) tb/$(TB).sv
	$(OBJDIR)/V$(TOP)

wave: runtest
	gtkwave sim/$(TOP).vcd

ranktest:
	verilator --binary --timing --trace -j 0 -Wno-fatal \
		--top-module matrix_rank_tb --Mdir $(RANK_OBJDIR) \
		rtl/matrix_rankcheck.sv $(CACHE_SRC) tb/matrix_rank_tb.sv
	$(RANK_OBJDIR)/Vmatrix_rank_tb

clean:
	rm -rf $(OBJDIR) $(RANK_OBJDIR) sim/$(TOP).vcd sim/matrix_rank_tb.vcd $(VECTORS)
