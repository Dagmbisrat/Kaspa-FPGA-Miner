MODULE  = matmul_pipelined_unit
SRC     = rtl/$(MODULE).sv
TB      = tb/matmul_pipelined_tb.sv
TOP     = matmul_pipelined_tb
OBJDIR  = /tmp/matmul_pipe_build
WOBJDIR = /tmp/matmul_pipe_wired_build
VECTORS = sim/expected_vectors.mem

JOBS       ?= 4
NUM_STAGES ?= 8

.PHONY: all runtest wiretest wave vectors clean help

help:
	@echo "Targets:"
	@echo "  make all       - Alias for runtest"
	@echo "  make runtest   - Internal-matrix build (write port): gen vectors, build, run"
	@echo "  make wiretest  - Wired-matrix build (matrix_in): same vectors, INTERNAL_MATRIX=0"
	@echo "  make vectors   - Regenerate test vectors from the Python reference"
	@echo "  make wave      - Run the internal-matrix TB and open the waveform"
	@echo "  make clean     - Remove build dirs, waveform, and vectors"
	@echo ""
	@echo "Variables (make TARGET VAR=value):"
	@echo "  NUM_STAGES=$(NUM_STAGES)   - Pipeline depth, must divide 64 (1,2,4,8,16,32,64)"
	@echo "  JOBS=$(JOBS)         - Parallel Verilator / C++ build jobs"

all: runtest

$(VECTORS): sim/gen_vectors.py
	python3 sim/gen_vectors.py

vectors: $(VECTORS)

# Internal-matrix mode (default): matrix loaded via the write port.
$(OBJDIR)/V$(TOP): $(SRC) $(TB)
	verilator --binary --timing --trace -j $(JOBS) -Wno-fatal \
		  --top-module $(TOP) -GNUM_STAGES=$(NUM_STAGES) -GUSE_WIRED=0 \
		  --Mdir $(OBJDIR) $(SRC) $(TB)

runtest: $(VECTORS) $(OBJDIR)/V$(TOP)
	$(OBJDIR)/V$(TOP)

# Wired-matrix mode: matrix presented on matrix_in (INTERNAL_MATRIX=0), as in-core.
$(WOBJDIR)/V$(TOP): $(SRC) $(TB)
	verilator --binary --timing --trace -j $(JOBS) -Wno-fatal \
		  --top-module $(TOP) -GNUM_STAGES=$(NUM_STAGES) -GUSE_WIRED=1 \
		  --Mdir $(WOBJDIR) $(SRC) $(TB)

wiretest: $(VECTORS) $(WOBJDIR)/V$(TOP)
	$(WOBJDIR)/V$(TOP)

wave: runtest
	gtkwave sim/$(TOP).vcd

clean:
	rm -rf $(OBJDIR) $(WOBJDIR) sim/$(TOP).vcd $(VECTORS)
