# riscv-pipelined-fpga

A from-scratch RV32I processor core in Verilog. Every module is hand-written RTL and covered by a self-checking testbench — verification is treated as a first-class deliverable, not an afterthought.

- **Goal** — a 5-stage pipelined RV32I core, with hazard detection and forwarding, running on a Digilent Basys 3 (Artix-7) board.
- **Where it is today** — the datapath and control modules are written and verified individually; single-cycle top-level integration is in progress. Pipelining has **not** started yet.

The repository name describes the goal. The table below describes today.

---

## Status (updated 2026-08-15)

| Done & verified | In progress | Planned (after Sep 2026) |
| --- | --- | --- |
| `alu.v` — 32-bit ALU, incl. SRA / SLTU / LUI (36/36 checks pass) | Single-cycle top-level integration: PC logic, instruction & data memory, full module wiring | Pipeline registers (IF/ID, ID/EX, EX/MEM, MEM/WB) |
| `regfile.v` — 32×32, `x0` hardwired to zero, 2 async reads / 1 sync write | | Hazard detection & forwarding |
| `imm_gen.v` — all five RV32I immediate formats (26/26 checks pass) | | Branch flush logic |
| `decoder.v` — main decoder + ALU decoder (26/26 checks pass) | | On-board demo of the core |
| `alu_regfile_top.v` — ALU + register file integration | | |
| Toolchain verified end-to-end on Basys 3 (LED passthrough on real hardware) | | |

*"Verified" means the module has a testbench in `tb/` that applies a fixed stimulus set, compares each result against an expected value computed inside the testbench, prints PASS/FAIL per case, and ends with a pass/total summary. No manual waveform inspection is needed to know whether a module still works.*

---

## Architecture (single-cycle, current integration target)

```
  PC ──► Instruction Memory ──┬──► Decoder ──────► control signals ──┐
   ▲                          │                                      │
   │                          ├──► ImmGen ───────► immediate ─────┐   │
   │                          │                                   ▼   ▼
   │                          └──► Register File ──► rs1/rs2 ──► ALU (32-bit)
   │                                    ▲                            │
   │                                    │                            ▼
   │                                    │                       Data Memory
   │                                    │                            │
   │                                    └────── write-back ◄─────────┘
   │
   └──── PC+4 / branch target ◄──────────────────────────────────────
```

---

## Build & simulate

Toolchain: [Icarus Verilog](https://steveicarus.github.io/iverilog/) + GTKWave for simulation, Vivado for synthesis and board bring-up.

```bash
iverilog -g2012 -o build/imm_gen_tb.vvp rtl/imm_gen.v tb/imm_gen_tb.v   # compile
vvp build/imm_gen_tb.vvp                                                # run, prints PASS/FAIL + summary
gtkwave build/imm_gen_tb.vcd                                            # optional: inspect waveform
```

Swap the module and testbench names to run any other unit — `alu`, `regfile`, `decoder`.

---

## Repository layout

```
rtl/                core modules
rtl/practice/       early Verilog exercises, kept as a record of the learning path
tb/                 self-checking testbenches for the core modules
tb/practice/        testbenches for the exercises
constraints/        XDC constraint files (Basys 3)
docs/build-log.md   day-by-day build log, including bugs hit and how they were found
```

---

## Roadmap

1. Single-cycle integration — connect all modules, run a hand-assembled test program (arithmetic → branch → load/store) and check every instruction against a hand-computed expectation.
2. Insert pipeline registers, split the datapath into five stages.
3. Hazard detection and forwarding.
4. Branch flush logic.
5. Basys 3 bring-up: constraints, synthesis, on-board demo of the core.

---

## Known limitations

- The core is not yet integrated; the modules above are verified in isolation, plus one ALU + register file integration.
- Instruction and data memory are behavioural models loaded with `$readmemh`, not FPGA block RAM.
- No pipelining, therefore no hazard handling yet. Control hazards in particular are a known open item, planned as step 4 above.
- RV32I base integer instruction set only. No CSRs, no interrupts, no multiply/divide extension.
