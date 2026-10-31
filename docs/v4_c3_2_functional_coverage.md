# AXI4-Lite v4.0-C3.2 Functional Coverage Closure

## Scope and evidence rule

C3.2 extends the frozen C3.1 manifest; it does not change or overwrite the
C3.1 plan, logs, VDBs, reports, commit, or tag. Coverage is sampled only from
passively observed AW/W/AR/B/R handshakes and stalls, real C2 write-commit and
read-snapshot events, reset entry, GPIO pins, and lifecycle-service state.
Sequence intent is never treated as a hit. All new directed traffic completes
through the existing independent model, cycle-aware scoreboard, and strict C2
checker.

C3.3 parameter/bad-slave expansion and C3.4 sign-off are explicitly out of
scope. No exclusion, `ignore_bins`, or deleted bin was used to raise coverage.

## Requirement traceability

| Requirement | Observed coverage object / bins | Closing test(s) | Final result |
|---|---|---|---|
| REQ-AXI-003 AW/W independence | `axi_request_cg.cp_aw_w_relation`: simultaneous; AW/W-first gaps 1, 2-3, 4-7, 8+ | existing GPIO runs + `axi4l_c3_2_coverage_test` seed 21 | 9/9 bins |
| REQ-AXI-005 WSTRB | 16 explicit pattern bins; zero, four independent one-hot lanes, ten independent other-partial patterns, full; legal register x pattern | `axi4l_c3_2_coverage_test` seed 21 | 16/16 patterns and 96/96 register crosses |
| REQ-GPIO-001/002..005 register/output operations | read/write x eight word addresses; LOAD/SET/CLEAR/TOGGLE x WSTRB | existing tests + seed 21 | access x address 16/16; four output-op rows in the 96/96 legal matrix |
| REQ-AXI-002 response backpressure | B/R stall 0, 1, 2-3, 4-7, 8+; AW/W relation x B-backpressure | existing runs + seeds 21/22 | stall bins/crosses closed; response latency zero-cycle bin remains uncovered |
| C2 commit/snapshot timing | write/read x accepted-to-event latency 0, 1, 2-3, 4-7, 8+; same-edge read-old/write-new | `axi4l_c2_timing_test` + `axi4l_c3_2_timing_closure_test` seed 22 | latency cross 10/10; same-edge bin hit |
| REQ-AXI-004 outstanding/order | passive GPIO accepted queues 0/1/2; controlled-slave highwater and ordered B/R | v3 stress + v4 depth 3/4/8 tests | GPIO 0/1/2 closed; controlled 3/4/8 and order closed; reset run only reaches actual 1/1, so depth-2 bin remains open |
| REQ-RST-001 reset | GPIO idle, AW-only, W-only, accepted W/R pending, B/R stalled; v4 AW/W-only, B/R pending, credit-wait, normal-before-publication, recovery | v3 mid-reset, v4 reset, `axi4l_c3_2_reset_context_test` seed 23 | GPIO 7/7; v4 lifecycle/reset scenarios closed |
| REQ-GPIO-008 W1C collision | real W1C commit x independently reconstructed hardware-change cycle | collision test seed 5 | `hw_change_wins` hit 5 times |
| REQ-INT-001/002 | observed MASK enabled/disabled x `o_int`, assert/hold/deassert events | directed GPIO + seed 21 | implemented-polarity bins closed; specification polarity remains open |

The seed-21 WSTRB matrix deliberately keeps non-zero WDATA for `WSTRB=0000`,
so preservation is checked rather than avoiding a side effect with zero data.
Writes cover only the architecturally meaningful writable registers:
LOAD/SET/CLEAR/TOGGLE/CHANGED-W1C/MASK. INPUT and INT are not manufactured
into a misleading register x WSTRB cross; their existing write-isolation
checks remain active.

## Implementation summary

- `axi4l_monitor` publishes passive cycle observations, response-stall counts,
  queue occupancy/highwater, and reset-entry classification.
- `axi4l_c2_timing_monitor` mirrors each real checker event to a coverage-only
  observation without weakening or bypassing checker behavior.
- `axi4l_gpio_coverage` adds explicit WSTRB/register, AW/W gap,
  relation/backpressure, response/event latency, outstanding/stall, reset,
  same-edge, W1C collision, and MASK/IRQ covergroups.
- v4 component tests add separate controlled-slave depth/order/reset groups and
  lifecycle scenarios. These are never merged into the GPIO RTL claim.
- `c3_2_coverage_plan.json` extends C3.1 with seeds 21, 22, and 23. The runner
  resolves overlays deterministically and records planned/actual status, tool,
  Git state, command, seed, logs, DBs, exit code, UVM counts, and URG reports.

## Final measured run

Validated on Rocky Linux with VCS/URG `V-2023.12-SP1_Full64` and UVM 1.2.
The final evidence directory is `sim/c3_2_coverage_verified/`.

- 21/21 runs PASS; four/four compatible URG merges PASS.
- Aggregate run exit codes are zero; UVM warning/error/fatal = 0/0/0;
  runtime SVA failures = 0.
- Every selected run has a non-empty coverage DB and its required marker.
- The three new closure rows are deterministic seeds 21, 22, and 23.

| Compatible group | Runs | Line | Condition | Toggle | Branch | Assert | Functional | Assertion attempts/failures | SVA covers |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| GPIO DUT default | 15 | 81.39% | 69.90% | 62.79% | 76.15% | 97.26% | 99.56% | 420764/0 | 32/32 |
| v4 controlled slave | 4 | 72.73% | 38.83% | 9.16% | 46.15% | 9.59% | 93.75% | 17040/0 | 0/32 |
| v4 lifecycle component | 1 | 22.51% | 8.74% | 0.00% | 9.23% | 1.37% | 100.00% | 2/0 | 0/32 |
| C2 checker self-test | 1 | 63.64% | 41.75% | 9.41% | 43.08% | 27.40% | 19.80% | 1320/0 | 6/32 |

FSM is N/A in every URG group because no scored FSM object exists; it is not
0% or 100%. Denominators across the four groups are intentionally not treated
as interchangeable. The checker self-test's low functional score is expected:
it is isolated fault-injection sensitivity evidence, not a GPIO closure run.

## Remaining bins and honest boundary

1. GPIO `axi_response_cg.cp_latency.immediate` is uncovered. The passive
   definition is accepted-request to completed B/R handshake. In this
   registered DUT/testbench sampling model, completion is observed no earlier
   than the following cycle. The bin is retained, unexcluded, and reported.
2. Controlled-slave `v4_depth_order_cg` depth-2 write/read bins are uncovered.
   The depth-2 reset run proves credit-wait/reset behavior but its measured
   slave highwater is only 1/1; it is not relabelled as 2/2. Depth 3/4/8 and
   response order are covered independently.
3. Code coverage remains 81.39/69.90/62.79/76.15 for GPIO
   line/condition/toggle/branch. C3.2 does not create waivers or claim code
   coverage closure.
4. `SPEC-MASK-001` remains unresolved. Current RTL, scoreboard, SVA, and
   coverage characterize MASK=1 as enable, while original prose says mask.
5. Default elaboration only is covered. Parameter matrices, broader bad-slave
   behavior, RAL, formal closure, exclusions, and final sign-off remain
   C3.3/C3.4 or later work.

Therefore 99.56% GPIO functional coverage is a measured coverage-object score,
not a claim that every specification requirement is signed off.
