# Keccak-f[1600] RTL Implementation

## Module Structure

### `keccak_round` — Single Round (Combinational)
Computes one of the 24 Keccak-f[1600] rounds. Purely combinational — no clock.

**Ports:**
| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `state` | in | 64-bit × 5×5 | Input state |
| `round_constant` | in | 64-bit | Iota round constant |
| `out` | out | 64-bit × 5×5 | Output state |

**Steps per round:**
1. **Theta** — XOR column parities into each lane
2. **Rho** — Rotate each lane by fixed offset
3. **Pi** — Permute lane positions
4. **Chi** — Non-linear bitwise mixing
5. **Iota** — XOR round constant into lane[0][0]

### `keccak_f1600` — Full Permutation (Sequential)
Wraps `keccak_round` with a round counter and state register. Iterates 24 rounds, one per clock cycle.

**Ports:**
| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `clk` | in | 1 | Clock |
| `rst` | in | 1 | Async reset |
| `start` | in | 1 | Load `state_in` and begin |
| `state_in` | in | 64-bit × 5×5 | Input state |
| `state_out` | out | 64-bit × 5×5 | Output state |
| `done` | out | 1 | High when permutation complete |

## Datapath

```
state_in ──→ [state_reg] ──→ [keccak_round] ──→ round_out ──→ [state_reg]
                                   ↑                              (next cycle)
                            RC[round_cnt]
```

- Assert `start` to load input and reset counter
- 24 clock cycles to complete
- `done` asserts after round 23

## Round Constants

24 constants applied during the iota step, one per round:
```
RC[ 0] = 0x0000000000000001    RC[12] = 0x000000008000808B
RC[ 1] = 0x0000000000008082    RC[13] = 0x800000000000008B
RC[ 2] = 0x800000000000808A    RC[14] = 0x8000000000008089
RC[ 3] = 0x8000000080008000    RC[15] = 0x8000000000008003
RC[ 4] = 0x000000000000808B    RC[16] = 0x8000000000008002
RC[ 5] = 0x0000000080000001    RC[17] = 0x8000000000000080
RC[ 6] = 0x8000000080008081    RC[18] = 0x000000000000800A
RC[ 7] = 0x8000000000008009    RC[19] = 0x800000008000000A
RC[ 8] = 0x000000000000008A    RC[20] = 0x8000000080008081
RC[ 9] = 0x0000000000000088    RC[21] = 0x8000000000008080
RC[10] = 0x0000000080008009    RC[22] = 0x0000000080000001
RC[11] = 0x000000008000000A    RC[23] = 0x8000000080008008
```

## References

- NIST FIPS 202: SHA-3 Standard
- Keccak Team: https://keccak.team/
