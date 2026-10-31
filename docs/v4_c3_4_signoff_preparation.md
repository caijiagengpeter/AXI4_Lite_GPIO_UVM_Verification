# AXI4-Lite v4.0 C3.4-B Sign-off Preparation

状态：**readiness review；不是 final sign-off，waiver/exclusion 均未批准**。

## 1. 保存基线与证据边界

- C3.4-A checkpoint：`e1404e5906a08fca70071a5a0de02f3754fe0376`；
  annotated tag：`v4.0-c3.4a-baseline`。
- C3.3 历史：28/28 runs PASS；C3.4-A 历史：7/7 builds、51/51 runs、
  12/12 URG merges PASS，UVM W/E/F=0/0/0，SVA failures=0。
- C3.4-A 后的旧 `make regression` 历史 sanity 为 15/15 PASS，日志 UVM W/E/F=0/0/0；本轮尚未重跑。
- C3.4-A DUT-only `axilgpio`：Line 80/82、Condition 21/21、Toggle
  700/940、Branch 55/58。`v4 full 14-test` 的 85.55% 是 TB+RTL top-level
  指标，不是 DUT-only。
- negative/checker selftests 与 NIN=0、NIN/NOUT=1、NOUT=32、SKID=0、
  LOWPOWER=1、非零 DEFAULT_OUTPUT 参数证据均复用历史结果；本轮未重跑全矩阵。
- 历史目录 `sim/c3_4_coverage_closure_reviewed_final` 未覆盖；首次 license-missing
  尝试保留在 `sim/c3_4b_w1c_directed_review`，成功的 seed43 证据保留在
  `sim/c3_4b_w1c_fresh`，选择性 combined 报告在 `sim/c3_4b_w1c_combined/report`。

## 2. SPEC-MASK-001 决议

项目规格负责人于 2026-10-31 决议：**MASK bit 1 = IRQ enable；bit 0 =
masked**。它是明确的 RTL-derived behavioral specification，不是 coverage waiver。
原 ZipCPU RTL 注释描述了相反 polarity，作为源文档冲突保留记录；不修改 DUT RTL。
Golden Model 继续由外部接受事务、GPIO sample 与真实 commit/snapshot event 独立计算
MASK/CHANGED/INT/o_int，绝不读取 DUT 内部 `r_mask/toggled/INT` 作为 expected。

## 3. W1C 定向 closure

C3.4-A 的 `w1c_matrix_cg` variables 为 7/7、cross 为 6/8；缺口是
`data=0/1 × WSTRB-off × hardware-changing`。审查证明两项合法可达：covergroup
按同一 `event_cycle` 汇合 real WRITE_COMMIT 与 `last^qq` hardware detect；既有已验证
collision schedule 使用 2 个 driver clocking-block delay，使 commit 与 CDC 检测落在同沿。

本轮新增 `axi4l_c3_4b_w1c_off_change_test`：只执行这两个组合，读回 CHANGED，且由
独立 cycle scoreboard 按“先 W1C、后 hardware set”规则验证 sticky/set priority；测试
还要求真实 internal commit、response/read checker 计数和零 scoreboard error。

2026-10-31 的首次增量命令因 license unavailable 在源码解析前停止，该目录保留为
诊断证据。许可证恢复后，用户在 fresh 目录只重跑同一项：

```bash
cd /home/ray/AXI4_Lite_New/sim
make coverage_c3_4b_delta C3_4_OUT=c3_4b_w1c_fresh
```

fresh run exit=0、UVM W/E/F=0/0/0、SVA failure=0，standalone URG merge PASS。
随后将 fresh default VDB 与 C3.4-A default VDB 选择性合并，URG exit=0且无
incompatibility。`grpinfo.txt` 逐 bin 显示原缺的 `one/off/changing` 与
`zero/off/changing` 各由 fresh test 独占命中1次，故 cross严格核实为8/8；无需重跑
51-run 全矩阵。

## 4. 唯一分类与 waiver candidates

| 对象 | 分类/证据 | 状态 |
|---|---|---|
| response latency immediate | monitor 在接受沿记 `accept_cycle`；DUT 同沿 NBA 置 `BVALID/RVALID`；`#1step` monitor 只能在后续沿看到 response handshake，故最小 latency=1 | waiver candidate，未批准/未 exclude |
| BRESP/RRESP non-OKAY bits | `axilgpio.v:265,315` 恒 `2'b00`；controlled slave 同样只产生 OKAY | design-constant candidate，未批准 |
| NIN padding/read constants | 由 NIN 宽度零扩展，default 配置结构常量 | NIN structural candidate，未批准 |
| NOUT padding | default NOUT=30 结构常量；NOUT=32 分支已有隔离实测 | NOUT structural candidate，未批准且不跨参数 merge |
| LOWPOWER branches | LOWPOWER=1 隔离配置已实测 | parameter-specific HIT，不需 waiver 冒充 default hit |
| W1C 两 cross | 合法可达，seed43 专用测试逐项命中且独立 checker通过 | exact 8/8，CLOSED，不是 waiver |

没有删除 bin、降低 goal、修改 DUT 或新增 exclusion。

## 5. 实际总表与 readiness

| 阶段 | 本轮状态 | 可用结论 |
|---|---|---|
| C3.3 | 历史 28/28 PASS | 参数/negative/checker 基线可复用 |
| C3.4-A | 历史 51/51、12/12 PASS | DUT toggle 700/940；default Functional 99.18% |
| C3.4-B W1C | PASS（seed43） | exit0、UVM0/0/0、SVA0；combined cross 8/8 |
| C3.4-B sanity | PASS（用户正式执行） | `make regression` shell exit0；正式运行 logs UVM0/0/0 |

当前 readiness 是 **evidence complete for the targeted gap; approvals pending**。真正障碍：

1. 逐项审批或拒绝 response/constant/padding/skid-configuration waiver candidates；
2. 冻结 supported parameter matrix 与 RAL、CI/lint、formal proof 的 release scope；
3. 评审当前 dirty C3.4-B source/docs并保存可追踪 revision；
4. 用户/评审者批准最终 verification report 与 sign-off criteria。

在这些完成前不自动创建 C3.4-B/C3.4-C commit/tag，不宣称 final sign-off。
