MODULE  = core
TOP     = core_tb
OBJDIR  = /tmp/core_build
VECTORS = sim/expected_vectors.mem

# Dependency paths (relative to this Makefile)
KECCAK   = ../crypto/keccak
CSHAKE   = ../crypto/cshake256
XOSHIRO  = ../utils/xoshiro256pp
MATGEN   = ../matrix/matrix_generator
MATMUL   = ../matrix/matmul_unit

JOBS          ?= 4
CSHAKE_STAGES ?= 24    # cSHAKE pipeline layers; must divide 24
MATMUL_STAGES ?= 8     # matmul pipeline layers; must divide 64

SRC = \
    $(KECCAK)/rtl/keccak_round.sv \
    $(KECCAK)/rtl/keccak_f1600.sv \
    $(CSHAKE)/rtl/cshake256_core.sv \
    $(XOSHIRO)/rtl/xoshiro256pp.sv \
    $(MATGEN)/rtl/matrix_rankcheck.sv \
    $(MATGEN)/rtl/matrix_generator.sv \
    $(MATMUL)/rtl/matmul_pipelined_unit.sv \
    rtl/matrix_cache.sv \
    rtl/$(MODULE).sv

TB = tb/core_tb.sv

.PHONY: all runtest wave vectors clean help

help:
	@echo "Targets:"
	@echo "  make all       - Alias for runtest"
	@echo "  make runtest   - Generate vectors, build, and run the core TB"
	@echo "  make vectors   - Regenerate test vectors from the Python reference"
	@echo "  make wave      - Run the TB and open the waveform in GTKWave"
	@echo "  make clean     - Remove build dir, waveform, and vectors"
	@echo ""
	@echo "Variables (make TARGET VAR=value):"
	@echo "  CSHAKE_STAGES=$(CSHAKE_STAGES)  - cSHAKE pipeline depth, must divide 24"
	@echo "  MATMUL_STAGES=$(MATMUL_STAGES)   - matmul pipeline depth, must divide 64"
	@echo "  JOBS=$(JOBS)          - Parallel Verilator / C++ build jobs"

all: runtest

$(VECTORS): sim/gen_vectors.py
	python3 sim/gen_vectors.py

vectors: $(VECTORS)

runtest: $(VECTORS)
	verilator --binary --timing --trace -j $(JOBS) -Wno-fatal --top-module $(TOP) \
		  -GCSHAKE_STAGES=$(CSHAKE_STAGES) -GMATMUL_STAGES=$(MATMUL_STAGES) \
		  --Mdir $(OBJDIR) $(SRC) $(TB)
	$(OBJDIR)/V$(TOP)
	@python3 ../tools/fpga_estimate.py core CSHAKE_STAGES=$(CSHAKE_STAGES) MATMUL_STAGES=$(MATMUL_STAGES)

wave: runtest
	gtkwave sim/$(TOP).vcd

clean:
	rm -rf $(OBJDIR) sim/$(TOP).vcd $(VECTORS)
