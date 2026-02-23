MODULE  = matmul_unit
CACHE   = ../../core/rtl/matrix_cache.sv
SRC     = rtl/$(MODULE).sv $(CACHE)
TB      = tb/matmul_tb.sv
TOP     = matmul_tb
OBJDIR  = /tmp/matmul_build
VECTORS = sim/expected_vectors.mem

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
