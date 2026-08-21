MODULE  = matmul_pipelined_unit
SRC     = rtl/$(MODULE).sv
TB      = tb/matmul_pipelined_tb.sv
TOP     = matmul_pipelined_tb
OBJDIR  = /tmp/matmul_pipe_build

JOBS       ?= 4
NUM_STAGES ?= 8

.PHONY: all runtest wave clean help

help:
	@echo "Targets:"
	@echo "  make all       - Alias for runtest"
	@echo "  make runtest   - Build and run the pipelined matmul TB"
	@echo "  make wave      - Run the TB and open the waveform in GTKWave"
	@echo "  make clean     - Remove build dir and waveform"
	@echo ""
	@echo "Variables (make TARGET VAR=value):"
	@echo "  NUM_STAGES=$(NUM_STAGES)   - Pipeline depth, must divide 64 (1,2,4,8,16,32,64)"
	@echo "  JOBS=$(JOBS)         - Parallel Verilator / C++ build jobs"

all: runtest

$(OBJDIR)/V$(TOP): $(SRC) $(TB)
	verilator --binary --timing --trace -j $(JOBS) -Wno-fatal \
		  --top-module $(TOP) -GNUM_STAGES=$(NUM_STAGES) \
		  --Mdir $(OBJDIR) $(SRC) $(TB)

runtest: $(OBJDIR)/V$(TOP)
	$(OBJDIR)/V$(TOP)

wave: runtest
	gtkwave sim/$(TOP).vcd

clean:
	rm -rf $(OBJDIR) sim/$(TOP).vcd
