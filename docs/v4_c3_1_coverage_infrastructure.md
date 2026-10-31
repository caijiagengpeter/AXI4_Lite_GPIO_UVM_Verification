# AXI4-Lite v4.0-C3.1 Coverage Infrastructure

## Scope and checkpoint

C3.1 establishes collection, a machine-readable planned/actual manifest,
compatible merge groups, URG reports, and a human-readable overview. It does
not add coverpoints, tests, exclusions, parameter variants, or sign-off claims.
C3.2 functional-coverage closure, C3.3 parameter/negative expansion, and C3.4
sign-off remain open.

The work was based on the real C2 checkpoint
59187f90c871a530d020fa495ea4a836c52be8c5 (v4.0-c2-baseline). The stable B2
tag still resolves to e0e4a3001f9d533cc9d24e7695480926c8182cbb; neither tag
was moved. The repository has no remote.

## Interfaces

- Plan: manifests/c3_1_coverage_plan.json
- Runner: scripts/coverage_manifest.py
- Directed infrastructure tests: scripts/test_coverage_manifest.py
- Planned manifest: make coverage_manifest
- Full C3.1 run: make coverage_v4
- Optional sets: make coverage_v4_gpio, make coverage_v4_bfm, and
  make coverage_v4_checker
- Actual result: sim/c3_1_coverage/manifest.json
- Overview: sim/c3_1_coverage/overview.md
- Per-group HTML: sim/c3_1_coverage/reports/<group>/dashboard.html

make coverage remains the historical seven-run GPIO/v2/v3 target and still
writes coverage.vdb plus coverage_report. C3.1 uses a separate output tree.
Choose a new C3_OUT value for another evidence run; existing run databases are
rejected instead of silently reused.

## Manifest and failure semantics

Every planned row records test/target/seed, execution target, build variant,
top/configuration, DUT parameters, driver mode, runtime parameters, expected
outcome, and plusargs. Actual rows record timestamps, the exact command, exit
code, UVM warning/error/fatal counts, runtime SVA failures, log, coverage DB,
report path, status, and failure reasons.

A run cannot pass if its process exit code is nonzero, its UVM summary is
missing, UVM error/fatal or an SVA failure is observed, its coverage DB is
missing/empty, or a required semantic marker is absent. URG groups must have
the same top, build variant, compile configuration, DUT parameter set, and
coverage object. Duplicate test/build/config/seed tuples are reported.

The C2 checker self-test has controlled_checker_faults semantics. PASS means
the injected orphan, duplicate, missing, stale-epoch, and unqualified-B faults
were all detected and C2_SELFTEST_PASS was emitted with zero UVM errors; it
does not mean a DUT fault is accepted.

## Real execution on 2026-10-31

Environment: VCS V-2023.12-SP1_Full64, UVM 1.2, URG V-2023.12-SP1.
Commands: make coverage_manifest_selftest; make coverage_manifest;
make coverage_v4.

All five infrastructure self-tests passed: missing DB, nonzero run exit,
incompatible merge variant, duplicate-seed warning, and negative expected
outcome. The real coverage run compiled successfully; all 18 runs returned
exit 0 with UVM warning/error/fatal 0/0/0, zero runtime SVA failures, and a
non-empty coverage DB. All four URG merges and reports passed.

| Merge group | Runs | Line | Condition | Toggle | FSM | Branch | Assert | Functional group | Assertion attempts/failures | SVA covers |
|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|
| gpio_dut_default | 12 | 81.39% | 69.90% | 62.16% | N/A | 76.15% | 97.26% | 100.00% | 332534/0 | 32/32 |
| v4_controlled_slave | 4 | 72.73% | 38.83% | 9.16% | N/A | 46.15% | 9.59% | N/A | 17036/0 | 0/32 |
| v4_lifecycle_component | 1 | 22.51% | 8.74% | 0.00% | N/A | 9.23% | 1.37% | N/A | 2/0 | 0/32 |
| checker_selftest | 1 | 63.64% | 41.75% | 9.41% | N/A | 43.08% | 27.40% | 36.58% | 1315/0 | 6/32 |

The total metrics are for the compiled tb_top scope. The coverage-object labels
control the claim: controlled-slave and lifecycle results are not GPIO DUT RTL
coverage. FSM is N/A because URG found no FSM coverage shape.

## Remaining gaps

- The two implemented functional covergroups reach 100% in the GPIO group, but
  they do not implement every item in coverage_plan.txt.
- GPIO total line/condition/toggle/branch are 81.39/69.90/62.16/76.15%; the
  compiled-but-idle controlled slave and testbench infrastructure affect the
  aggregate. Module-level gaps are listed in the generated overview.
- Only the default GPIO elaboration was run. No NIN/NOUT, skid-buffer,
  low-power, or default-output parameter matrix was added.
- Controlled-slave depth 3/4/8 remains distinct from the GPIO DUT's observed
  maximum of 2/2.
- No new deliberately bad slave, randomized seed expansion, bin closure,
  exclusion, waiver, or sign-off decision belongs to C3.1.
