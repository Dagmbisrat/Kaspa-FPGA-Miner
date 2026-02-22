MODULE  = matrix_generator
TB      = matrix_tb
TOP     = matrix_tb
OBJDIR  = /tmp/matrix_build
SIM_DIR = sim
VECTORS = $(SIM_DIR)/expected_matrix.mem

CACHE_SRC  = matrix_cache.sv
PRNG_SRC   = xoshiro256pp/xoshiro256pp.sv

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
	cd $(SIM_DIR) && python3 gen_vectors.py

runtest: vectors
	verilator --binary --timing --trace -j 0 -Wno-fatal \
		--top-module $(TOP) --Mdir $(OBJDIR) \
		$(MODULE).sv $(CACHE_SRC) $(PRNG_SRC) $(SIM_DIR)/$(TB).sv
	$(OBJDIR)/V$(TOP)

wave: runtest
	gtkwave $(TOP).vcd

ranktest:
	verilator --binary --timing --trace -j 0 -Wno-fatal \
		--top-module matrix_rank_tb --Mdir $(RANK_OBJDIR) \
		matrix_rankcheck.sv $(CACHE_SRC) $(SIM_DIR)/matrix_rank_tb.sv
	$(RANK_OBJDIR)/Vmatrix_rank_tb

clean:
	rm -rf $(OBJDIR) $(RANK_OBJDIR) *.vcd $(VECTORS)
