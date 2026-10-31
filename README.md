# AXI4-Lite GPIO UVM Verification

A SystemVerilog/UVM verification environment for the ZipCPU `axilgpio` AXI4-Lite GPIO peripheral. The project exercises independent AXI4-Lite channels, GPIO register semantics, synchronized inputs, sticky change detection, interrupt behavior, response backpressure, ordered pipelining, and reset recovery.

The current environment is a strong verification-development milestone, not a formal sign-off. It includes a self-checking reference model, protocol and functional assertions, functional coverage, directed and randomized tests, and a VCS/URG regression flow. Remaining closure items are documented below.

## Status at a glance

| Area | Current status |
|---|---|
| AXI4-Lite master agent | Active/passive UVM agent；保留 legacy/limited/v3，并新增显式 v4 channel mode：bounded Dispatcher、独立 AW/W/AR workers、ordered B/R collectors、single Publisher 与 epoch reset |
| GPIO agent | Active/passive stimulus and cycle-by-cycle observation |
| Reference model | C2 independent cycle model for GPIO output, input synchronization, `CHANGED`, `MASK`, `INT`, and registered `o_int`; expected values never come from DUT internal data |
| Checking | External AW/W/AR accepted queues, real internal commit/snapshot timing, ordered/qualified responses, pin checking, reset epochs, and orphan/duplicate/missing audits |
| Assertions | AXI stability/response checks, reset checks, synchronizer checks, interrupt relation, W1C/sticky checks, and activation cover properties |
| Functional coverage | C3.4 keeps every scored bin and raises the expanded default-GPIO object from 98.73% to 99.18%; W1C cross is 6/8 and the zero-cycle response bin remains open |
| Coverage infrastructure | C3.3 is frozen at `v4.0-c3.3-baseline`; the reviewed C3.4 matrix has 7 isolated builds, 51 reproducible runs, 12 compatible merge groups, and strict DUT/parameter/component/negative claim separation |
| Pipelining and stress | v4 controlled slave proves write/read depth 3, 4, 8 and reset at actual 2/2; GPIO DUT v3 depth-2/3 stress still observes max 2, and the objects are not merged |
| RAL | Planned, not implemented |
| Formal sign-off | Not claimed; the `MASK` polarity conflict and coverage/parameter gaps remain open |

## DUT overview

The DUT is a 32-bit AXI4-Lite GPIO peripheral derived from the ZipCPU WB2AXIP project. The default testbench configuration is:

| Parameter | Value |
|---|---:|
| `C_AXI_ADDR_WIDTH` | 5 |
| `C_AXI_DATA_WIDTH` | 32 |
| `OPT_SKIDBUFFER` | 1 |
| `OPT_LOWPOWER` | 0 |
| `NOUT` | 30 |
| `NIN` | 5 |
| `DEFAULT_OUTPUT` | 0 |

With `NIN > 0`, the register map is:

| Address | Register | Access | Implemented behavior |
|---:|---|---|---|
| `0x00` | `LOAD` | RW / read alias | Replace strobed output bytes; reads return the current output |
| `0x04` | `SET` | RW / read alias | Set written output bits; reads return the current output |
| `0x08` | `CLEAR` | RW / read alias | Clear written output bits; reads return the current output |
| `0x0C` | `TOGGLE` | RW / read alias | Toggle written output bits; reads return the current output |
| `0x10` | `INPUT` | RO | Return the synchronized GPIO input |
| `0x14` | `CHANGED` | W1C | Sticky input-change status; a concurrent hardware change wins over software clear |
| `0x18` | `MASK` | RW | Interrupt-control bits; current RTL behavior is described in the open issue below |
| `0x1C` | `INT` | RO | Return the implemented active interrupt vector |

`WSTRB` is honored byte by byte. Address bits `[1:0]` are ignored, so unaligned addresses alias their containing 32-bit word. The DUT always returns AXI `OKAY`; it has no `SLVERR` or `DECERR` path. With `NIN=0`, the upper four word addresses alias the four output operations and `o_int` remains low.

## Verification architecture

```mermaid
flowchart LR
    AXIS[AXI sequences] --> AXIQ[AXI sequencer] --> AXID[AXI driver]
    GPIOS[GPIO sequences] --> GPIOQ[GPIO sequencer] --> GPIOD[GPIO driver]
    AXID --> AXIF[axi4l_if]
    GPIOD --> GPIOIF[gpio_if]
    AXIF <--> DUT[axilgpio DUT]
    GPIOIF <--> DUT
    AXIF --> AXIM[AXI monitor]
    AXIF --> C2M[C2 accepted-request tracker]
    ADAPTER[Read-only commit/snapshot adapter] --> C2M
    GPIOIF --> GPIOM[GPIO monitor]
    C2M -->|commit/snapshot events + accepted payload| SCB[Cycle-aware scoreboard]
    AXIM -->|completed response events| SCB
    GPIOM -->|cycle samples| SCB
    AXIM --> COV[Functional coverage]
    GPIOM --> COV
    SVA[Bound SVA] --> DUT
```

The C2 path deliberately separates external acceptance, internal execution, and response completion:

- the tracker independently queues AW/W/AR handshakes and pairs the oldest AW with the oldest W;
- only real `WRITE_COMMIT`/`READ_SNAPSHOT` events drive state prediction and read-data snapshots;
- B/R completion events check response status, ordering, latency, and data;
- the GPIO monitor supplies a common cycle reference for input, output, interrupt, and reset checking.

The adapter exposes only the two timing predicates, never DUT register/read data. A `+C2_BLACKBOX`
fallback derives events at acceptance and retains end-to-end checking, but cannot make cycle-exact claims
when B/R backpressure separates acceptance from commit/snapshot.

### Main components

- `tb/axi_agent/`: reusable AXI4-Lite sequence item, sequencer, driver, monitor, interface, and agent.
- `tb/gpio_agent/`: reusable GPIO stimulus and observation agent.
- `tb/env/axi4l_gpio_scoreboard.sv`: cycle-aware reference model and ordered request/response checker.
- `tb/env/axi4l_c2_timing_monitor.sv`: epoch-aware accepted tracker, event correlation, response eligibility, and orphan/duplicate/missing checks.
- `tb/coverage/axi4l_gpio_coverage.sv`: accepted-transaction and observed-GPIO covergroups.
- `tb/assertions/`: bound AXI, reset, synchronizer, W1C, and interrupt assertions/covers.
- `tb/sequences/`: single-access, pipelined, mid-reset, and stress sequences.
- `tb/tests/`: shared test package/base, with deterministic tests under `directed/` and randomized tests under `random/`.

## What is checked today

### AXI4-Lite protocol and transport

- independent AW and W timing: same-cycle, AW-first, and W-first;
- VALID/payload stability while AW, W, AR, B, or R is stalled;
- ordered AW/W pairing and ordered B/R association without AXI IDs;
- response backpressure and request-side skid-buffer stalls;
- `OKAY` BRESP/RRESP checking;
- configurable pipelined driver credits and response queues;
- no lost, duplicated, or late response in the v3 stress audit;
- reset flushing of requests, pending responses, and credits.
- current-epoch FIFO qualification for commit/snapshot and B/R, including orphan, duplicate, missing, and stale-event diagnostics.

### GPIO functionality

- `LOAD`, `SET`, `CLEAR`, and `TOGGLE` operations;
- byte-enable behavior, including `WSTRB=0` preservation;
- output alias reads and zeroing above `NOUT`;
- the digital `i_gpio -> q_gpio -> qq_gpio` sampling pipeline;
- rising/falling input changes and sticky `CHANGED` accumulation;
- W1C behavior, including deterministic same-cycle hardware-set/software-clear collisions;
- `MASK`, active interrupt bits, and the registered `o_int` relationship using the RTL's current polarity;
- writes to read-only `INPUT`/`INT` addresses do not directly change output or mask state.

Digital simulation checks the synchronizer's sampled behavior only. It does not prove metastability probability, MTBF, or capture of pulses shorter than a clock period.

## Test inventory

| Test | Purpose |
|---|---|
| `axi4l_smoke_test` | Baseline output operations, partial writes, aliases, and AW/W timing |
| `gpio_agent_smoke_test` | GPIO stimulus/monitor path smoke test |
| `axi4l_gpio_v2_directed_test` | Directed full-path GPIO input, `CHANGED`, W1C, mask, interrupt, and isolation checking |
| `axi4l_gpio_v2_random_test` | Seeded randomized AXI/GPIO functional traffic |
| `axi4l_gpio_bit34_coverage_test` | Directed rise/fall and sticky-status coverage for input bits 3 and 4 |
| `axi4l_gpio_w1c_hw_collision_test` | Deterministic same-bit W1C plus hardware-set collision on all implemented input bits |
| `axi4l_request_stall_test` | Deterministic AW/W/AR payload stability when DUT request buffering fills |
| `axi4l_v3_pipelined_test` | Ordered write/read overlap with delayed responses and AW/W order variations |
| `axi4l_v3_mid_reset_test` | Six reset-in-flight scenarios plus a checked post-reset recovery after each scenario |
| `axi4l_v3_stress_test` | 104-request pipeline/backpressure stress, read snapshots, FIFO ordering, credit accounting, and drain checks |
| `axi4l_v4_lifecycle_unit_test` | Terminal/credit/epoch/reset 的隔离单元测试 |
| `axi4l_v4_channel_pipeline_test` | 受控 depth-8 slave；跨事务 AW/W overlap、W-before-AW、mixed traffic、stall stability 与实际 8/8 outstanding |
| `axi4l_v4_response_order_test` | 受控 depth-4 slave；无 AXI ID 条件下的方向 FIFO response association |
| `axi4l_v4_depth3_test` | 受控 depth-3 组件级边界运行 |
| `axi4l_v4_reset_test` | AW-only、W-only、pending B/R、credit wait、normal-but-unpublished、actual write/read depth2-both reset、exactly-once 与逐场景 recovery |
| `axi4l_c2_timing_test` | Non-zero buffered SET/CLEAR/TOGGLE, B/R backpressure, delayed snapshot, intervening write, same-edge read/write, and reset while buffered |
| `axi4l_c3_2_coverage_test` | Six legal writable registers x all 16 explicit WSTRB patterns, AW/W gap/backpressure classes, and MASK/IRQ path; seed 21 |
| `axi4l_c3_2_timing_closure_test` | Scoreboard-checked 1/short/moderate real commit/read-snapshot latency closure; seed 22 |
| `axi4l_c3_2_reset_context_test` | Observed W-only/accepted-write/accepted-read reset entry and checked recovery; seed 23 |
| `axi4l_c2_checker_selftest` | Commit and snapshot orphan/duplicate/missing, stale, and unqualified B/R fault injection without expected-error regression pollution |
| `axi4l_c3_3_parameter_test` | Isolated NIN/NOUT/skid/low-power/default-output configurations, output change/no-change, zero strobe, and address aliases |
| `axi4l_bad_slave_selftest` | Eight controlled early/unstable/stale/duplicate/missing protocol faults with self-checked detector sensitivity |
| `axi4l_c3_4_dut_closure_test` | Checker-verified unaligned aliases, AWADDR[1] toggles, independent AW/W gaps, held VALID, B/R stalls, buffered writes, W1C timing combinations, and alias reads |
| `axi4l_c3_4_v4_payload_test` | Controlled-slave 5-bit address/data/WSTRB/PROT payload closure with response association, stability, depth-8 and exactly-once checks before coverage sampling |

The mid-reset test covers a partial write, pending B response, pending R response, mixed read/write activity, credit wait, and reset after completed B/R boundaries.

## Running the project

### Requirements

- Linux shell environment
- GNU Make
- Synopsys VCS with UVM 1.2 support
- Synopsys URG for coverage reporting
- Python 3.11 (available as `python3.11` in the validated Rocky 8.10 image)

The checked Makefile defaults to VCS `V-2023.12-SP1` under `/opt/Synopsys/vcs/V-2023.12-SP1`. Override `VCS_HOME` when the installation is elsewhere.

```bash
cd sim

# Baseline smoke test
make smoke

# Individual feature tests
make v2_directed
make v2_random
make v3_pipelined
make v3_mid_reset
make v3_stress
make v3_stress_depth3

# v4 lifecycle + channel pipeline/component tests
make v4_lifecycle_unit
make v4_channel_pipeline
make v4_response_order
make v4_depth3
make v4_reset

# C2 cycle-exact integration and isolated checker sensitivity tests
make c2

# Existing v2/v3/v4 plus C2 regression
make regression

# Instrumented seven-test coverage run and URG report
make coverage
```

C3.1 infrastructure and full grouped run:

    make coverage_manifest_selftest
    make coverage_manifest
    make coverage_v4

Optional C3.1 subsets use a fresh output name, for example:

    make coverage_v4_gpio C3_OUT=c3_1_gpio_run
    make coverage_v4_bfm C3_OUT=c3_1_bfm_run
    make coverage_v4_checker C3_OUT=c3_1_checker_run

C3.2 full run uses a distinct output tree and leaves C3.1 untouched:

    make coverage_c3_2

Optional GPIO-only execution also requires a fresh output name:

    make coverage_c3_2_gpio C3_2_OUT=c3_2_gpio_review

C3.3 resolves the inherited plan into seven isolated builds, 28 runs, and ten
compatible merge groups. Always choose a fresh output directory:

    make coverage_c3_3 C3_3_OUT=c3_3_parameter_negative_review

C3.4 adds the two checked directed tests, a current-source legacy seven-test
control group, and a separate v4 full-suite group. It resolves to 7 builds,
51 runs, and 12 compatible merge groups. Always choose a fresh output directory:

    make c3_4_dut_closure
    make c3_4_v4_payload
    make coverage_c3_4 C3_4_OUT=c3_4_coverage_closure_review

Example with a different VCS installation:

```bash
make coverage VCS_HOME=/path/to/synopsys/vcs/V-2023.12-SP1
```

Example custom test/seed:

```bash
make smoke RUN_OPTS="+UVM_TESTNAME=axi4l_gpio_v2_random_test \
  +UVM_VERBOSITY=UVM_LOW +ntb_random_seed=42"
```

The preserved legacy dashboard is `sim/coverage_report/dashboard.html`.
C3.1 writes `sim/c3_1_coverage/manifest.json`, `overview.md`, four
independent merged VDBs, and per-group dashboards under `reports/`; it does
not overwrite the legacy report.

### Regression versus coverage targets

C3.2 writes `sim/c3_2_coverage/` by default; the final recorded verification
run for this stage is `sim/c3_2_coverage_verified/`.

C3.3 writes `sim/c3_3_parameter_negative/` by default. The final recorded
verification run is `sim/c3_3_parameter_negative_verified_clean/`; it reports
7/7 builds, 28/28 runs, and 10/10 merges PASS with aggregate UVM W/E/F 0/0/0
and runtime SVA failures 0; all seven compile logs have zero VCS warnings/errors.

C3.4 writes `sim/c3_4_coverage_closure/` by default. The reviewed evidence is
`sim/c3_4_coverage_closure_reviewed_final/`; it reports 7/7 builds, 51/51 runs,
and 12/12 merges PASS, every run exit 0 with UVM W/E/F 0/0/0 and runtime SVA
failures 0. Generated VDB/log/HTML artifacts remain ignored.

The regression and coverage targets are complementary:

- `make regression` runs 15 tests: smoke/GPIO smoke, v2 directed/random, v3 pipeline/reset/stress, five v4 lifecycle/component/reset tests, C2 timing, W1C collision, and the isolated checker self-test.
- `make coverage` runs v2 directed, v2 random with seed 1, bit 3/4 closure, W1C collision, request-stall closure, and v3 stress at configured depths 2 and 3.
- `make coverage_v4` runs 18 manifest rows and merges GPIO DUT (12),
  controlled slave (4), lifecycle component (1), and checker self-test (1)
  separately. The controlled-slave report is not a GPIO DUT RTL claim.

## Recorded coverage snapshot

- `make coverage_c3_2` resolves the C3.2 overlay into 21 rows: the unchanged
  C3.1 inventory plus three GPIO closure rows at seeds 21/22/23. It preserves
  the same four incompatible coverage-object boundaries.

The repository contains the following URG report snapshot:

| Field | Recorded value |
|---|---|
| Date | 2026-10-30 17:36:09 |
| User | `ray` |
| Tool | VCS/URG `V-2023.12-SP1` |
| Command | `urg -dir coverage.vdb -report coverage_report` |
| Number of tests | 7 |

The seven instrumented runs are:

1. `axi4l_gpio_v2_directed_test`
2. `axi4l_gpio_v2_random_test` with seed 1
3. `axi4l_gpio_bit34_coverage_test`
4. `axi4l_gpio_w1c_hw_collision_test`
5. `axi4l_request_stall_test`
6. `axi4l_v3_stress_test` with depth 2
7. `axi4l_v3_stress_test` with depth 3

### Total coverage

| Score | Line | Condition | Toggle | FSM | Branch | Assert | Group |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 80.45 | 81.58 | 66.99 | 60.31 | — | 76.56 | 97.26 | 100.00 |

### Hierarchical coverage

| Instance | Score | Line | Condition | Toggle | FSM | Branch | Assert |
|---|---:|---:|---:|---:|---:|---:|---:|
| `tb_top` | 77.09 | 81.58 | 66.99 | 60.31 | — | 76.56 | 100.00 |
| `uvm_pkg` | 33.33 | — | — | — | — | — | 33.33 |

### Module-definition coverage

| Score | Line | Condition | Toggle | FSM | Branch | Assert |
|---:|---:|---:|---:|---:|---:|---:|
| 78.04 | 80.65 | 65.33 | 67.36 | — | 79.59 | 97.26 |

URG did not report a scored FSM metric, so the blank field is shown as `—`; it must not be interpreted as 0% or 100%. The group score applies only to the two functional covergroups currently implemented. It does **not** mean that every item in `docs/coverage_plan.txt` is covered. Assertion detail reports 41 assertions: 39 successes, 0 failures, and 2 unattempted UVM-internal assertions; all 32 cover properties matched (32/32). Assertion coverage is an activation metric, not a formal pass-rate claim.

The code-coverage score is lower than the previous snapshot because the v4 controlled-slave and component-test code is now compiled while the preserved seven-run GPIO/v3 coverage target does not execute the v4 component tests. This is reported as a real instrumentation-scope effect, not as a regression failure.

The report does not embed a Git revision or a complete parameter matrix. Treat these values as a reproducible project snapshot rather than formal sign-off evidence.

## Development evolution

`/home/ray/AXI4_Lite_New` is an independent local Git repository beginning with the `v4.0-b2-baseline` checkpoint. It does not inherit the old project's history and has no configured remote. Earlier stages below are reconstructed from the design notes, class names, implemented tests, and the read-only v3.2 backup; they are development milestones, not a claim of tag-by-tag Git history.

| Milestone | Main change |
|---|---|
| v1 smoke baseline | Reusable AXI and GPIO agents; independent AW/W driving; completed-transaction monitoring; output-operation model; smoke tests |
| v2 functional model | Split request/response monitor streams; cycle tags; request-time state prediction; AR-time read snapshots; cycle-by-cycle GPIO/input/interrupt model; directed/random tests; SVA and functional coverage |
| v3 pipelining | Configurable ordered pipelined mode, per-channel credits, independent request issue/response retirement, response queues, and an overlap proof test |
| v3.1 reset robustness | Mid-transaction reset injection, queue/credit flushing, aborted-transaction handling, and six post-reset recovery checks |
| v3.2 stress/closure milestone | Long depth-2/depth-3 runs, 104-request audit, simultaneous B/R stalls, snapshot-hold checking, deterministic W1C collision and request-stall closure tests, and the recorded URG merge |
| v4.0-B2 channel pipeline | One-credit-per-request bounded dispatch, atomic AW/W commit, independent AW/W/AR workers, ordered B/R association, single terminal Publisher, epoch/reset barrier, and controlled-slave depth 3/4/8 proof |
| v4.0-C2 cycle-exact checking | Minimal read-only timing adapter, accepted-request tracker, independent GPIO golden model, commit/snapshot-driven scoreboard, checker self-test, and real VCS regression |
| v4.0-C3.1/C3.2 coverage | Manifest-driven compatible grouping plus observed functional closure and a frozen local C3.2 checkpoint |
| v4.0-C3.3 parameter/negative | Six checked GPIO parameter configurations, dedicated eight-fault bad-slave detector, expanded C2/W1C/reset selftests, and evidence-based code-gap analysis |

The “v3.2” name is a project milestone used to describe the current stress/reset/pipelining state; it is not presently a Git tag.

## Repository layout

```text
.
├── dut/rtl/                 # DUT and skid-buffer RTL
├── original/zipcpu/         # Preserved upstream RTL copies
├── tb/
│   ├── axi_agent/           # AXI4-Lite UVM agent
│   ├── gpio_agent/          # GPIO UVM agent
│   ├── env/                 # Environment and scoreboard
│   ├── coverage/            # Functional covergroups
│   ├── assertions/          # Bound SVA
│   ├── sequences/           # Reusable stimulus sequences
│   ├── tests/               # UVM tests
│   ├── ral/                 # Reserved for future RAL work; currently empty
│   └── tb_top.sv            # Clock/reset, DUT, interfaces, and UVM startup
├── sim/
│   ├── Makefile             # VCS build, regression, and coverage targets
│   ├── filelist.f           # Compile order and include paths
│   └── coverage_report/     # Recorded URG HTML report
└── docs/                    # Plan, requirements, issues, traceability, and report template
```

## Known limitations and open issues

1. **`MASK` polarity is unresolved (`SPEC-MASK-001`).** DUT comments describe `1` as masking an interrupt, while the implemented expression is `r_mask & changed`, so `1` behaves as an enable. The scoreboard and SVA intentionally follow the RTL behavior until the design/specification owner resolves the conflict.
2. **C3.4 functional coverage is not final sign-off.** The expanded default GPIO object is 99.18%; W1C is 6/8 at the data/strobe/hardware-change cross, and parameter groups remain isolated reachability evidence rather than being merged to inflate Overall.
3. **One GPIO response-latency bin remains uncovered.** Passive accepted-to-completed-response latency cannot be zero in the current registered sampling model. The bin is retained and unexcluded; code coverage also remains below sign-off levels.
4. **The reviewed C3.3 matrix is finite.** NIN=0, NIN/NOUT=1, NOUT=32, SKID=0, LOWPOWER=1, and a non-zero default value pass, but it is not an exhaustive Cartesian product.
5. **RAL is not implemented.** The plan describes alias, volatile, and W1C modeling, but `tb/ral/` is currently empty.
6. **Stress depth 3 is configured but the present DUT run observes a maximum outstanding depth of 2.** This is still useful for credit and backpressure checking, but it is not evidence of three simultaneously accepted requests.
7. **Black-box fallback is intentionally weaker.** The default C2 path is cycle-exact white-box; `+C2_BLACKBOX` retains end-to-end checks but cannot distinguish acceptance from delayed commit/snapshot under B/R backpressure.
8. **C3.4 provenance is automated.** The overlay records build signatures, real parameters, test/seed/driver/outcome/log/DB/report and exact exit/UVM/SVA results; machine-readable gap triage distinguishes hit, parameter-only, constant-waiver-candidate, and unresolved items.
9. **Sign-off documents are not closed.** `docs/verification_report.md` remains a template, and plan/traceability statuses have not been updated to match all implemented tests.
10. **Repository is local-only.** The B2 checkpoint/tag and local history exist, but there is intentionally no remote; generated VCS artifacts remain untracked and no push is performed.
11. **C3 closure is still not sign-off.** C3.4 improves real DUT and v4 infrastructure coverage without exclusions, but waiver approval, retained timing bins, `SPEC-MASK-001`, and the final verification report remain open.

## Roadmap

- Resolve `SPEC-MASK-001` in writing and align RTL comments, checks, and documentation.
- Review the retained response-latency/depth-2 gaps and finish the partial data-category, W1C, and alias crosses without exclusions lacking rationale.
- Use the C3.1 baseline and C3.2 grouped manifests/reports as the evidence base; do not reuse the historical seven-run URG snapshot as C2/v4 closure.
- Implement a UVM register model with explicit alias prediction and volatile/W1C handling.
- Add more randomized seeds, reset-in-stress scenarios, and coverage-directed closure tests.
- Review code/assertion exclusions and close or justify uncovered legal behavior.
- Extend parameter sampling only where a reviewed boundary adds value; keep incompatible VDBs isolated.
- Complete the traceability matrix and final verification report, then define formal sign-off criteria.
- Keep simulator-generated artifacts untracked and add CI/lint automation where licensed tools are available.

## Documentation

- `docs/spec_analysis.txt`: behavior extracted from the RTL and the open polarity conflict.
- `docs/verification_plan.txt`: scope, requirements, planned tests, assertions, coverage, and sign-off goals.
- `docs/coverage_plan.txt`: coverage intent and closure targets.
- `docs/traceability_matrix.csv`: requirement/test/assertion/coverage mapping.
- `docs/issues_log.csv`: authoritative open-issue list.
- `docs/version_explain.txt`: detailed v1 limitations and the architectural motivation for v2.
- `docs/verification_report.md`: final-report template; not yet a completed sign-off report.
- `docs/v4_c1_rtl_timing_analysis.md`: RTL timing and NBA sampling analysis.
- `docs/v4_c2_timing_scoreboard.md`: C2 event contract, implementation, cycle evidence, regression results, and C3 boundary.
- `docs/v4_c3_1_coverage_infrastructure.md`: C3.1 schema, compatible groups, real VCS/URG results, claim boundaries, and remaining C3.2-C3.4 gaps.
- `docs/v4_c3_2_functional_coverage.md`: C3.2 observed functional coverage and frozen checkpoint evidence.
- `docs/v4_c3_3_code_coverage_gap_analysis.md`: v3.2/v4 denominator proof, DUT-only covered/total, uncovered lines/branches/toggles, and C3.4 boundary.
- `docs/v4_c3_3_parameter_negative.md`: parameter matrix, bad-slave/C2/W1C/reset selftests, final 28-run results, and reproduction.
- `docs/v4_c3_4_coverage_gap_closure.md`: C3.3 checkpoint, C3.4 tests, exact DUT/TB before-after counts, gap triage, reproduction, and draft sign-off gaps.
- `manifests/c3_4_coverage_gap_triage.json`: machine-readable hit/parameter/constant/unresolved gap inventory and claim boundaries.

## Provenance and licensing

`dut/rtl/axilgpio.v` and `dut/rtl/skidbuffer.v` originate from the ZipCPU WB2AXIP project and carry Apache License 2.0 notices in their source headers. The repository currently has no root `LICENSE` file covering the verification environment. Add an explicit project license and preserve all upstream notices before redistributing or accepting external contributions.

