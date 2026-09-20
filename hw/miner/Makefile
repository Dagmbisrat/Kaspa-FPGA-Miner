MODULE = work_controller
TOP    = work_controller_tb
OBJDIR = /tmp/work_controller_build
VECTORS = ../core/sim/expected_vectors.mem

# Dependency paths (relative to this Makefile) -- same dependencies core.sv itself needs
CORE     = ../core
KECCAK   = ../crypto/keccak
CSHAKE   = ../crypto/cshake256
XOSHIRO  = ../utils/xoshiro256pp
MATGEN   = ../matrix/matrix_generator
MATMUL   = ../matrix/matmul_unit

JOBS ?= 4
# Defaults to a slow FOLDED config on purpose -- see work_controller_tb.sv's
# comment: test2's found-FIFO ordering check needs register-bus pops to keep
# pace with core's admission rate, which the default unfolded config (a find
# every single cycle) never could.
CSHAKE_STAGES ?= 1
MATMUL_STAGES ?= 8
CSHAKE_FOLDED ?= 1

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
    rtl/$(MODULE).sv

TB = tb/$(MODULE)_tb.sv

.PHONY: all runtest wave vectors clean help

help:
	@echo "Targets:"
	@echo "  make runtest     - Generate vectors, compile, and run the work_controller TB"
	@echo "  make wave        - Run and open the waveform in GTKWave"
	@echo "  make vectors     - Regenerate hw/core's Python-reference vectors"
	@echo "  make clean       - Remove generated files"
	@echo ""
	@echo "Variables (make TARGET VAR=value) -- forwarded to the core instance inside work_controller_tb:"
	@echo "  CSHAKE_STAGES=$(CSHAKE_STAGES)   - cSHAKE pipeline depth, must divide 24"
	@echo "  MATMUL_STAGES=$(MATMUL_STAGES)   - matmul pipeline depth, must divide 64"
	@echo "  CSHAKE_FOLDED=$(CSHAKE_FOLDED)   - fold both cSHAKE instances (default 1: slow admission on"
	@echo "                       purpose, so test2's register-bus pops can keep pace -- see"
	@echo "                       work_controller_tb.sv's header comment before changing this)"
	@echo "  JOBS=$(JOBS)             - Parallel Verilator / C++ build jobs"

$(VECTORS):
	$(MAKE) -C $(CORE) vectors

vectors: $(VECTORS)

runtest: $(VECTORS)
	verilator --binary --timing --trace -j $(JOBS) -Wno-fatal --top-module $(TOP) \
		  -GCSHAKE_STAGES=$(CSHAKE_STAGES) -GMATMUL_STAGES=$(MATMUL_STAGES) \
		  -GCSHAKE_FOLDED=$(CSHAKE_FOLDED) \
		  --Mdir $(OBJDIR) $(SRC) $(TB)
	$(OBJDIR)/V$(TOP)

wave: runtest
	gtkwave sim/$(TOP).vcd

clean:
	rm -rf $(OBJDIR) sim/$(TOP).vcd
