MODULE = uart_if
SRC    = rtl/$(MODULE).sv
TB     = tb/$(MODULE)_tb.sv
TOP    = $(MODULE)_tb
OBJDIR = /tmp/uart_if_build

JOBS ?= 4

.PHONY: all runtest wave clean help

help:
	@echo "Targets:"
	@echo "  make runtest     - Compile and run the uart_if testbench (no PHY needed)"
	@echo "  make wave        - Run and open the waveform in GTKWave"
	@echo "  make clean       - Remove generated files"

runtest:
	verilator --binary --timing --trace -j $(JOBS) -Wno-fatal --top-module $(TOP) \
		  --Mdir $(OBJDIR) $(SRC) $(TB)
	$(OBJDIR)/V$(TOP)

wave: runtest
	gtkwave sim/$(TOP).vcd

clean:
	rm -rf $(OBJDIR) sim/$(TOP).vcd
