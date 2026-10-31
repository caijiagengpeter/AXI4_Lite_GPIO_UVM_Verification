# AXI4-Lite v4.0 Draft Verification Sign-off Report

**DRAFT—PENDING WAIVER APPROVAL**
结论：**NOT FINAL SIGN-OFF / readiness conditional**。

## 1. Executive summary

当前证据支持：default GPIO DUT 主要功能、AXI4-Lite handshake/backpressure/reset、
W1C/change-winning、MASK/INT、参数边界、B2 channel-pipeline component 与 C2 independent
cycle checker 均有可复现 PASS 证据。C3.4-A 为 51/51 runs、12/12 compatible merges、
UVM W/E/F=0/0/0、SVA failure=0；C3.4-B seed43 为 exit0、UVM0/0/0、SVA0，
且 W1C exact cross 已逐 bin 核实为 8/8。

这不等于正式 sign-off：候选 waivers 未经 owner审批，supported parameter matrix、
RAL/CI/lint/formal scope 和最终 report acceptance仍未冻结。81.39% 是包含 TB 的 dashboard
overall，不是 DUT-only gate。

## 2. Configuration and provenance

| 项目 | 值 |
|---|---|
| Simulator / coverage | VCS/URG V-2023.12-SP1_Full64；UVM 1.2 |
| Baseline | `v4.0-c3.4a-baseline` -> `e1404e5906a08fca70071a5a0de02f3754fe0376` |
| Default DUT | NIN=5, NOUT=30, SKID=1, LOWPOWER=0, DEFAULT_OUTPUT=0 |
| Main historical evidence | `sim/c3_4_coverage_closure_reviewed_final/` |
| C3.4-B evidence | `sim/c3_4b_w1c_fresh/` and `sim/c3_4b_w1c_combined/report/` |
| Source state | HEAD at baseline commit with reviewed but uncommitted C3.4-B source/docs; no remote/push/history rewrite/tag move |
| This audit execution | Reused VCS/URG data; no 51-run rerun and no new VCS simulation |

旧 `/home/ray/AXI4_Lite` 只读查看，未写入。其工作树原有未跟踪
`sim/coverage_report/` 不属于本轮创建物。

## 3. Verification architecture evidence

- **B2 independent component**：v4 bounded dispatcher、独立 AW/W/AR workers、ordered
  B/R collectors、epoch/reset/credit/exactly-once lifecycle在 controlled slave上验证，
  depth2/3/4/8、order、reset at actual 2/2和64 checked payload responses均通过；这些
  结果标为 component evidence，不冒充 GPIO DUT depth。
- **C2 independent checker**：cycle-aware golden model只使用 accepted transactions、
  GPIO samples与真实 commit/snapshot event；不读取 DUT internal expected state。
  checker selftest命中 orphan/duplicate/missing/stale/unqualified fault，bad-slave selftest
  检出8类协议错误，均与正常回归隔离。
- **Assertions**：default group assertion 71/73 overall 是顶层含 uvm_pkg口径；
  `tb_top.dut` bind SVA 为71/71、100%，C3.4-A runtime assertion attempts
  240348、fail0、SVA cover 32/32。

## 4. Test and evidence matrix

| 类别 | 实测证据 | 结果/边界 |
|---|---|---|
| Default GPIO DUT | C3.4-A default 17 tests | PASS；functional 99.18% 当时 W1C 6/8 |
| C3.4-B W1C target | seed43 | PASS；两个目标 marker、SCB_PASS、commit/snapshot4/4、response8 |
| Combined functional | A default + seed43 compatible merge | Group99.64%；10/11 groups100%；response96%；W1C matrix8/8 |
| Parameters | NOUT32, NIN1/NOUT1, SKID0, LOWPOWER1/nonzero default, NIN0 | 6 isolated configurations PASS；不跨 merge |
| Negative | bad-slave detector seed37 | 8 expected faults detected；UVM W/E/F0/0/0 |
| Checker selftest | C2 fault injection | orphan/duplicate/missing/stale/unqualified paths detected；isolated PASS |
| B2 component | lifecycle, pipeline depth8, order depth4, depth3, reset depth2 | 5 controlled-slave tests PASS；functional100% |
| Standard sanity | recent `make regression` plus selected clean run logs | shell exit0（用户记录）；正式 logs UVM0/0/0 |

早期 `sim/c3_4_v4_payload.log` 的32 errors与 `sim/v4_reset_debug.log` 的2 errors是
development/debug evidence；后续 `c3_4_v4_payload_checked.log`、`v4_reset.log`
均为 UVM0/0/0。旧失败日志不得被错误计入正式 pass/fail，也不得删除。

## 5. Coverage result

### 5.1 DUT-only default

| Scope | Line | Condition | Toggle | Branch | Assert |
|---|---:|---:|---:|---:|---:|
| `axilgpio` | 80/82 (97.56%) | 21/21 (100%) | 700/940 (74.47%) | 55/58 (94.83%) | N/A |
| three `skidbuffer` RTL instances composite | 54/63 (85.71%) | 33/42 (78.57%) | 378/384 (98.44% ratio; instance scores 95/95/99.34%) | 30/45 (66.67%) | N/A |
| pure DUT RTL composite | 134/145 (92.41%) | 54/63 (85.71%) | 1078/1324 (81.42%) | 85/103 (82.52%) | N/A |
| `tb_top.dut` subtree incl. bind SVA | 134/145 (92.41%) | 54/63 (85.71%) | 1470/1728 (85.07%) | 85/103 (82.52%) | 71/71 (100%) |

注：三个 skid toggle相加的 378/384 是 instance ratio；URG module-definition 97.17%
按两个 parameter definitions聚合，二者口径不同。精确 gap与证明见
`v4_c3_4_dut_only_audit.md`。

### 5.2 Functional per-bin result

`w1c_matrix_cg` variables7/7、cross8/8；`w1c_collision_cg`100%。
`axi_response_cg` 为96%，唯一缺口 `cp_latency.immediate` 0 hit；one/short/moderate/
extended 全覆盖。该 0-cycle 项进入 WV-FUNC-LAT-001，尚未批准。

## 6. Requirements/issues status

| 项目 | 状态 |
|---|---|
| AW/W independence, WSTRB, output ops, reset, ordering/backpressure | IMPLEMENTED_CLOSED within recorded configurations |
| CHANGED/W1C/change-winning | BEHAVIOR_CHECKED_AND_CROSS_8_OF_8 |
| MASK/INT (`SPEC-MASK-001`) | RESOLVED_BY_PROJECT_SPEC_DECISION：MASK1=enable，MASK0=masked；不是 waiver |
| Parameter matrix | IMPLEMENTED_CLOSED_MATRIX for six recorded configurations；非 exhaustive Cartesian product |
| RAL | NOT IMPLEMENTED |
| CI/lint/formal proof | scope/acceptance criteria not frozen；不得默认为完成 |
| Coverage waivers | candidates drafted；none approved |

## 7. Waivers, bugs, limitations

候选清单见 `v4_c3_4_waiver_register.md`：constant OKAY response、NIN/NOUT padding、
skid generic configuration和 response immediate。`SPEC-MASK-001` 已解决，不列 waiver。
当前没有 DUT functional bug被本审计判定为 open；仍有这些 known limitations：
GPIO DUT实测 outstanding最大为2，不能代表 B2 component depth3/4/8；parameter matrix
有限；black-box checker模式弱于 white-box commit/snapshot；RAL未实现；未批准 exclusion。

## 8. Final sign-off entry criteria

1. owner逐项 approve/reject waiver，并冻结精确 source commit、parameter/bit范围和失效条件；
2. 冻结 supported parameter matrix，决定 skid generic modes是否属于产品范围；
3. 决定 RAL、CI/lint、formal property proof是否为本项目 release gate，并完成被要求项；
4. 将当前 dirty C3.4-B source/docs评审后保存为明确 commit/tag，再从该 revision做最小
   reproducibility sanity（不要求无理由重跑51 runs，但要保证 evidence/source trace）；
5. 最终审阅 traceability、issues/limitations、正式日志选择规则与本报告，填写 owner/date；
6. 未满足以上条件前，最终决定保持 **NOT SIGNED OFF**。

## 9. Draft decision

技术 readiness：**有条件就绪**；default reachable coverage gap已关闭或有参数证据，
W1C exact8/8已证实，response immediate具备结构证明。治理 readiness：**未就绪**；
waiver和scope approvals未完成。因此本文件只供最终评审，不是批准记录。
