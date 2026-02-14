MODULE = xoshiro256pp
SRC    = $(MODULE).sv
TB     = $(MODULE)_tb.sv
OUT    = $(MODULE)_tb
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
	iverilog -g2012 -o $(OUT) $(SRC) $(TB)
	vvp $(OUT)

wave: runtest
	gtkwave $(OUT).vcd

clean:
	rm -f $(OUT) $(OUT).vcd $(VECTORS)
