# AXI4-Lite v4.0-C3.4-A Coverage-Driven Closure

状态：**coverage improvement 完成，draft sign-off gap report；不宣称最终 sign-off**。

## 1. 基线与完整性

C3.3 的工作区成果先被保存为本地非破坏 checkpoint：

- 保存前 HEAD：`8815016fea0700e8b3efbddfd5fad393ad86673e`；
- C3.3 commit：`3dfdf5e5bbc135eec7204518aaf9098189233b3c`；
- annotated tag：`v4.0-c3.3-baseline`；
- C3.4 改动继续留在工作区，未创建 C3.4 commit/tag；
- 仓库没有 remote，没有 push，也没有移动旧 tag；
- `/home/ray/AXI4_Lite` 未写入、未重跑，tracked tree 保持不变。

本阶段没有修改 `dut/rtl/axilgpio.v` 或 `dut/rtl/skidbuffer.v`，没有新增
coverage exclusion、删除 bin、降低 goal 或把不同 parameter/top 的 VDB 硬合并。

## 2. 实现内容

新增 `axi4l_c3_4_dut_closure_test`，所有事务通过现有 reference model、cycle-aware
scoreboard、timing monitor 和 SVA，而不是只发送 stimulus。测试包含：

- `0x02/0x05/0x0a/0x0d` 合法 unaligned/alias 地址，令 DUT 实际使用的
  `S_AXI_AWADDR[1]` 完成 0->1 与 1->0；
- LOAD/SET/CLEAR/TOGGLE、非零 WSTRB、独立 AW/W delay 与 held VALID；
- 12-cycle B/R backpressure、buffered non-zero write side effect 和 alias read；
- W1C data/strobe/hardware-change 的额外组合；
- 至少 4 个 output write、3 个 read、13 个总 response、4 个 GPIO event 由 Checker
  审计，任何 scoreboard error 都阻止 PASS marker。

新增 `axi4l_c3_4_v4_payload_test`，在受控 v4 test-slave 上发送 32 write + 32
read，覆盖 5-bit 地址、全部 PROT、四类 data/WSTRB、stall 与 depth=8。地址、读数据、
response association、exactly-once 数量、稳定性和实际 high-water 都先检查，再采样
`verified_payload_cg`。一次开发自测故意漏掉 `+V4_TEST_SLAVE`，Checker 检出 32 个
read-data mismatch，证明该测试不会把错误对象上的 traffic 当成 PASS；正式运行使用
正确 plusarg 并为 0 error。

`coverage_manifest.py` 还修复了一个报告解析问题：旧逻辑可能把 cover property 的
`INCOMPLETE` 列误算成 assertion failure。现在只在 assertion detail section 聚合，
并新增单元测试。真实 URG `Failure` 始终为 0。

## 3. 最终可复现实测

最终证据目录：
`sim/c3_4_coverage_closure_reviewed_final/`。

命令：

```bash
cd /home/ray/AXI4_Lite_New/sim
make coverage_c3_4 C3_4_OUT=c3_4_coverage_closure_reviewed_final
```

结果：VCS/URG `V-2023.12-SP1`，7/7 builds、51/51 runs、12/12 compatible
merges PASS；每个 run exit=0、UVM W/E/F=0/0/0、runtime SVA failure=0，VDB 与报告
均存在。完整命令、seed、parameters、log、VDB、merge signature 和精确计数在
`manifest.json` 与 `overview.md`。

### 3.1 DUT-only，同口径前后对照

| 对象 | 阶段 | Line | Condition | Toggle | Branch |
|---|---|---:|---:|---:|---:|
| `axilgpio` | v3.2 / v4 legacy | 80/82 | 21/21 | 654/940 | 55/58 |
| `axilgpio` | C3.2 | 80/82 | 21/21 | 684/940 | 55/58 |
| `axilgpio` | C3.3 default | 80/82 | 21/21 | 698/940 (74.26%) | 55/58 |
| `axilgpio` | C3.4 default | 80/82 | 21/21 | **700/940 (74.47%)** | 55/58 |
| `skidbuffer` module | C3.4 default | 18/21 | 11/14 | instance-specific | 10/15 |

三个 default skid 实例的 toggle 分别为 AW 38/40、AR 38/40、W 302/304。
`axilgpio` 的 +2 是 `S_AXI_AWADDR[1]` 两个方向的真实翻转；Line/Condition/Branch
和 skid 分数不变，说明没有通过改 DUT 或排除不可达项制造增长。

default GPIO compatible group 从 C3.3 的 Line 81.47%、Condition 69.90%、Toggle
63.69%、Branch 76.15%、Functional 98.73%，变为：

| Tests | Line | Condition | Toggle | Branch | Functional | Assertion attempts/fail | SVA cover |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 17 | 189/232 (81.47%) | 72/103 (69.90%) | **1834/2870 (63.90%)** | 99/130 (76.15%) | **99.18%** | 240348/0 | 32/32 |

`tb_top.dut` toggle 从 84.84% 提升到 85.07%。Functional 的改善来自 W1C cross
由 4/8 提升到 6/8；不是删除分母。剩余两项是 data=0/1、strobe-off、hardware-changing
组合，继续保留。

### 3.2 v4 BFM/test-slave 与组件证据

v4 controlled-slave compatible group 为 5 tests：Line 169/232、Condition 40/103、
Toggle 365/2870、Branch 60/130、Functional 100%，assertion attempts/fail
23913/0。

其中 `axi4l_v4_test_slave` 与 `v4_axi_if` 的同一组 interface bits 从 C3.3 的
119/328 (36.28%) 提升到 **169/328 (51.52%)**；test-slave 代码为 Line 62/63、
Condition 35/40、Branch 22/23。唯一未命中 line/branch 是 invalid depth 的 `$fatal`
配置保护，不应在 clean regression 中为分数触发。

功能证据为：verified payload variables 50/50、crosses 64/64；depth/order 10/10；
reset context 8/8；lifecycle scenarios 6/6。UVM driver 是 class，不是本次 HDL
module line report 的独立 scored scope；其真实性由这些 checked bins、response
association、credit/epoch/reset 日志和 exactly-once 审计证明。

### 3.3 legacy 与 full suite 的严格同分母比较

历史 dashboard 仍保留，不能被覆盖：v3.2 的 147/160、51/63、1708/2078、
85/103 与旧 v4 的 186/228、69/103、1726/2862、98/128 具有不同编译分母。

C3.4 新增了**当前源码、同一个 `tb_top_default` build** 的两个组：

| 当前源码组 | Tests | Score | Line | Condition | Toggle | Branch |
|---|---:|---:|---:|---:|---:|---:|
| legacy 7-test | 7 | 76.04% | 189/232 | 68/103 | 1733/2870 | 99/130 |
| v4 full suite | 14 | **85.55%** | **217/232** | **85/103** | **2074/2870** | **110/130** |

这证明 v4 infrastructure 分母可以由真实测试活动覆盖；但该表是 top-level TB +
GPIO + v4 infrastructure 的 combined suite，**不是 DUT-only 改善声明**。full suite
Functional 83.11% 也只包含该 14-test mix，不包含 C3.2/C3.3 全部功能闭合测试，不能
用作 sign-off 功能分数。

## 4. Gap triage

| Gap | 分类 | C3.4 状态 | 处理 |
|---|---|---|---|
| `axilgpio.S_AXI_AWADDR[1]` | default 可达 | HIT | Checker-verified alias traffic，+2 toggle |
| `skidbuffer.v:137` legal stall | default 可达 | HIT/retained | URG line 1/1；C3.4 观察到 B/R stalls 与 buffered side effect |
| `axilgpio.v:489,503`; `skidbuffer.v:149,151,183` | LOWPOWER 参数路径 | parameter HIT | `gpio_lowpower1` 隔离 run，不跨参数合并 |
| `axilgpio.v:380` false branch | NOUT>=32 | parameter HIT | `gpio_nout32` 隔离 run |
| BRESP/RRESP 非 OKAY bits | 设计恒定 | waiver candidate | 实现只返回 OKAY；未加 exclusion，待正式审批 |
| NIN/NOUT padding、read-data constant、lint reduction | 结构/参数恒定 | waiver candidate | 保留 raw scoring，逐 bit 评审 |
| test-slave invalid depth fatal | 负向配置 | isolated test candidate | 不污染 clean regression；是否新增 expected-fatal 流程待评审 |
| W1C strobe-off + hardware-changing | timing cross | unresolved 2/8 | 行为有 scoreboard/SVA 检查，cross 仍保留 |
| response latency immediate | timing definition | unresolved 1/5 | count=0，未删/未 exclude，需时序定义审批 |
| `SPEC-MASK-001` | 规格冲突 | OPEN | Checker 继续匹配 RTL 的 MASK=1-enable；未改变 RTL |

逐项机器可读版本在 `manifests/c3_4_coverage_gap_triage.json`。

## 5. 到最终 sign-off 仍缺少什么

1. 设计/规格 owner 对 `SPEC-MASK-001` 给出书面结论；
2. 审批设计恒定与参数恒定的逐项 waiver，而不是用 exclusion 隐藏；
3. 证明或重新定义 immediate latency bin，并评审 W1C strobe-off/change 的采样时序；
4. 决定 invalid-depth expected-fatal 是否需要纳入独立 negative flow；
5. 完成 formal verification report、traceability review 和 sign-off criteria 审批；
6. RAL、CI/lint 等原计划未完成项仍不因本次覆盖增长而自动闭合。

因此本阶段达到的是可复现的 Coverage-Driven Improvement milestone 和 draft gap
report，不是最终 sign-off。
