MODULE  = matrix_generator
CACHE    = ../../core/rtl/matrix_cache.sv
PRNG     = ../../utils/xoshiro256pp/rtl/xoshiro256pp.sv
SRC      = rtl/$(MODULE).sv rtl/matrix_rankcheck.sv $(CACHE) $(PRNG)
RANK_SRC = rtl/matrix_rankcheck.sv $(CACHE)

TB       = tb/matrix_tb.sv
TB_RANK  = tb/matrix_rank_tb.sv
TB_LAT   = tb/latency_tb.sv
TOP      = matrix_tb
TOP_RANK = matrix_rank_tb
TOP_LAT  = latency_tb

OBJDIR      = /tmp/matrix_build
OBJDIR_RANK = /tmp/matrix_rank_build
OBJDIR_LAT  = /tmp/matrix_latency_build
VECTORS     = sim/expected_matrix.mem

JOBS ?= 4

.PHONY: all runtest ranktest latency wave latencywave vectors clean help

help:
	@echo "Targets:"
	@echo "  make all         - Alias for runtest (default correctness test)"
	@echo "  make runtest     - Generate vectors, build, run the matrix generator TB"
	@echo "  make ranktest    - Build + run the rank-check unit TB"
	@echo "  make latency     - Generate vectors, build, run the latency TB"
	@echo "  make wave        - Run correctness TB and open the waveform in GTKWave"
	@echo "  make latencywave - Run the latency TB and open the waveform in GTKWave"
	@echo "  make vectors     - Regenerate test vectors from the Python reference"
	@echo "  make clean       - Remove build dirs, waveforms, and vectors"
	@echo ""
	@echo "Variables (make TARGET VAR=value):"
	@echo "  JOBS=$(JOBS)        - Parallel Verilator / C++ build jobs"

$(VECTORS): sim/gen_vectors.py
	python3 sim/gen_vectors.py

all: runtest

vectors: $(VECTORS)

$(OBJDIR)/V$(TOP): $(SRC) $(TB)
	verilator --binary --timing --trace -j $(JOBS) -Wno-fatal \
	          --top-module $(TOP) --Mdir $(OBJDIR) $(SRC) $(TB)

runtest: $(VECTORS) $(OBJDIR)/V$(TOP)
	$(OBJDIR)/V$(TOP)
	@python3 ../../tools/fpga_estimate.py matrix_generator

$(OBJDIR_RANK)/V$(TOP_RANK): $(RANK_SRC) $(TB_RANK)
	verilator --binary --timing --trace -j $(JOBS) -Wno-fatal \
	          --top-module $(TOP_RANK) --Mdir $(OBJDIR_RANK) $(RANK_SRC) $(TB_RANK)

ranktest: $(OBJDIR_RANK)/V$(TOP_RANK)
	$(OBJDIR_RANK)/V$(TOP_RANK)

$(OBJDIR_LAT)/V$(TOP_LAT): $(SRC) $(TB_LAT)
	verilator --binary --timing --trace -j $(JOBS) -Wno-fatal \
	          --top-module $(TOP_LAT) --Mdir $(OBJDIR_LAT) $(SRC) $(TB_LAT)

latency: $(VECTORS) $(OBJDIR_LAT)/V$(TOP_LAT)
	$(OBJDIR_LAT)/V$(TOP_LAT)

wave: runtest
	gtkwave sim/$(TOP).vcd

latencywave: latency
	gtkwave sim/$(TOP_LAT).vcd

clean:
	rm -rf $(OBJDIR) $(OBJDIR_RANK) $(OBJDIR_LAT) \
		sim/$(TOP).vcd sim/$(TOP_RANK).vcd sim/$(TOP_LAT).vcd $(VECTORS)
