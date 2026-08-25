# Miner system layer

Top-level integration around the mining `core` IP(s):

- `rtl/miner_top.sv`     — top: transport + controller + N cores (build-time TRANSPORT)
- `rtl/work_controller.sv` — register map (work in, found FIFO out); nonce-space split; transport-agnostic
- `rtl/io/`             — swappable transport adapters (uart_if, pcie_if, axi_if)
- `tb/`                 — register-bus testbench (verify without a PHY)

Placeholder scaffold — RTL to be added in Phase 2 (Host Interface).
