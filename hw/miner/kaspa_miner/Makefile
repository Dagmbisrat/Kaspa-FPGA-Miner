MODULE = kaspa_miner
TOP    = kaspa_miner_tb
OBJDIR = /tmp/kaspa_miner_build
VECTORS = ../../core/sim/expected_vectors.mem

# Dependency paths (relative to this Makefile) -- same dependencies core.sv
# and work_controller.sv already need, plus uart_if
CORE     = ../../core
KECCAK   = ../../crypto/keccak
CSHAKE   = ../../crypto/cshake256
XOSHIRO  = ../../utils/xoshiro256pp
MATGEN   = ../../matrix/matrix_generator
MATMUL   = ../../matrix/matmul_unit
WORKCTRL = ../../work_controller
UART     = ../../io/uart

JOBS ?= 4
CSHAKE_STAGES ?= 24
MATMUL_STAGES ?= 8
CSHAKE_FOLDED ?= 0
CLK_FREQ_HZ   ?= 16000000
BAUD_RATE     ?= 1000000

SRC = \
    $(KECCAK)/rtl/keccak_round.sv \
    $(KECCAK)/rtl/keccak_f1600.sv \
    $(CSHAKE)/rtl/cshake256_core.sv \
    $(XOSHIRO)/rtl/xoshiro256pp.sv \
    $(MATGEN)/rtl/matrix_rankcheck.sv \
    $(MATGEN)/rtl/matrix_generator.sv \
    $(MATMUL)/rtl/matmul_pipelined_unit.sv \
    $(CORE)/rtl/matrix_cache.sv \
    $(CORE)/rtl/core.sv \
    $(WORKCTRL)/rtl/work_controller.sv \
    $(UART)/rtl/uart_if.sv \
    rtl/$(MODULE).sv

TB = tb/$(MODULE)_tb.sv

.PHONY: all runtest wave vectors clean help

help:
	@echo "Targets:"
	@echo "  make runtest     - Generate vectors, compile, and run the kaspa_miner TB"
	@echo "  make wave        - Run and open the waveform in GTKWave"
	@echo "  make vectors     - Regenerate hw/core's Python-reference vectors"
	@echo "  make clean       - Remove generated files"
	@echo ""
	@echo "Variables (make TARGET VAR=value) -- forwarded to the core/uart_if instances inside kaspa_miner_tb:"
	@echo "  CSHAKE_STAGES=$(CSHAKE_STAGES)   - cSHAKE pipeline depth, must divide 24"
	@echo "  MATMUL_STAGES=$(MATMUL_STAGES)   - matmul pipeline depth, must divide 64"
	@echo "  CSHAKE_FOLDED=$(CSHAKE_FOLDED)   - fold both cSHAKE instances"
	@echo "  CLK_FREQ_HZ=$(CLK_FREQ_HZ) - TB clock, for UART baud generation (fast-sim default, not the real 200MHz target)"
	@echo "  BAUD_RATE=$(BAUD_RATE)     - UART link speed"
	@echo "  JOBS=$(JOBS)             - Parallel Verilator / C++ build jobs"

$(VECTORS):
	$(MAKE) -C $(CORE) vectors

vectors: $(VECTORS)

runtest: $(VECTORS)
	verilator --binary --timing --trace -j $(JOBS) -Wno-fatal --top-module $(TOP) \
		  -GCSHAKE_STAGES=$(CSHAKE_STAGES) -GMATMUL_STAGES=$(MATMUL_STAGES) \
		  -GCSHAKE_FOLDED=$(CSHAKE_FOLDED) \
		  -GCLK_FREQ_HZ=$(CLK_FREQ_HZ) -GBAUD_RATE=$(BAUD_RATE) \
		  --Mdir $(OBJDIR) $(SRC) $(TB)
	$(OBJDIR)/V$(TOP)

wave: runtest
	gtkwave sim/$(TOP).vcd

clean:
	rm -rf $(OBJDIR) sim/$(TOP).vcd
