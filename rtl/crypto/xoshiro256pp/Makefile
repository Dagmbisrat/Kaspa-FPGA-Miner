MODULE = xoshiro256pp
SRC    = $(MODULE).sv
TB     = $(MODULE)_tb.sv
OUT    = $(MODULE)_tb

.PHONY: all clean wave help

help:
	@echo "Usage:"
	@echo "  make        - Compile and run testbench"
	@echo "  make wave   - Compile, run, and open waveform in GTKWave"
	@echo "  make clean  - Remove generated files"

all: clean
	iverilog -g2012 -o $(OUT) $(SRC) $(TB)
	vvp $(OUT)

wave: all
	gtkwave $(OUT).vcd

clean:
	rm -f $(OUT) $(OUT).vcd
