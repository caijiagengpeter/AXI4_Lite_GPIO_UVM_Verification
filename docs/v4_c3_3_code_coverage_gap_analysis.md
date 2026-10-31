# AXI4-Lite v4.0 C3.3 Code Coverage Gap Analysis

## 结论先行

用户给出的 v3.2 Overall 89.13% 与 v4.0 Overall 80.45% 确实分别来自：

- 旧工程 `/home/ray/AXI4_Lite/sim/coverage_report/`；
- 新工程保留的 legacy `/home/ray/AXI4_Lite_New/sim/coverage_report/`。

两份 dashboard 都是 7 tests、`urg -dir coverage.vdb -report coverage_report`，但 Overall
不是 DUT-only 指标。最关键的反证是两份报告中 `tb_top.dut` 实例完全相同：
Line 92.41%、Condition 80.95%、Toggle 80.56%、Branch 82.52%、Assert 100%。因此
`89.13 -> 80.45` 不是 v4 DUT RTL coverage 退化。

v4 legacy 编译了新增的 `v4_slave` 和 `v4_axi_if`，但这 7 个 GPIO/v3 tests 没有执行
v4 component traffic。`v4_slave` 只有 Line 55.56%、Condition 45.00%、Toggle 2.74%、
Branch 52.17%，`v4_axi_if` Toggle 2.74%。它们扩大 top-level 分母并拉低 Overall。

## Dashboard 分母证据

| Metric | v3.2 covered/total | v3.2 | v4 legacy covered/total | v4 | 分母变化 |
|---|---:|---:|---:|---:|---:|
| Line | 147/160 | 91.88% | 186/228 | 81.58% | +68 |
| Condition | 51/63 | 80.95% | 69/103 | 66.99% | +40 |
| Toggle | 1708/2078 | 82.19% | 1726/2862 | 60.31% | +784 |
| Branch | 85/103 | 82.52% | 98/128 | 76.56% | +25 |
| Assert | 71/73 | 97.26% | 71/73 | 97.26% | 0 |
| Group | scored groups | 100.00% | scored groups | 100.00% | 口径相同但仅代表现有 groups |

这解释了为何 covered 数量增加而百分比下降。尤其 toggle 分母增加 784，而新 TB 在旧
run mix 中几乎不活动，是 -21.88pp 的主要来源。

## DUT-only apples-to-apples

以下表只比较 `axilgpio.v` 与默认 elaboration 的 `skidbuffer.v`，不把 Driver、Lifecycle、
C2 checker 或 controlled slave 当成 DUT coverage。每格为 covered/total（percent）。

| Report / module | Line | Condition | Toggle | Branch |
|---|---:|---:|---:|---:|
| v3.2 `axilgpio` | 80/82 (97.56%) | 21/21 (100%) | 654/940 (69.57%) | 55/58 (94.83%) |
| v4 legacy `axilgpio` | 80/82 (97.56%) | 21/21 (100%) | 654/940 (69.57%) | 55/58 (94.83%) |
| C3.2 `axilgpio` | 80/82 (97.56%) | 21/21 (100%) | 684/940 (72.77%) | 55/58 (94.83%) |
| C3.3 default `axilgpio` | 80/82 (97.56%) | 21/21 (100%) | 698/940 (74.26%) | 55/58 (94.83%) |
| v3.2/v4 legacy `skidbuffer`, representative DW=3 instance | 18/21 (85.71%) | 10/14 (71.43%) | 37/40 (92.50%) | 10/15 (66.67%) |
| C3.2/C3.3 `skidbuffer`, representative DW=3 instance | 18/21 (85.71%) | 11/14 (78.57%) | 38/40 (95.00%) | 10/15 (66.67%) |

三个 skidbuffer 实例的 DW 不同，因此 URG module-definition Toggle 汇总不能简单用单一
40-bit 分母相加。最终 module-definition 百分比为 97.17%；上表明确标为 representative
instance，避免伪造总分母。

C3.2 到 C3.3 的同口径 default GPIO group：Line 81.39 -> 81.47、Condition 69.90 ->
69.90、Toggle 62.79 -> 63.69、Branch 76.15 -> 76.15。`tb_top.dut` Toggle 83.68 ->
84.84；`axilgpio` Toggle 72.77 -> 74.26。Functional 99.56 -> 98.73 是因为 C3.3 新增了
W1C/operation coverage 分母，并非删除命中或功能退化。

## 默认配置的真实 code gaps

默认参数为 NIN=5、NOUT=30、OPT_SKIDBUFFER=1、OPT_LOWPOWER=0。

### `axilgpio.v`

- Line 489 与 503 是仅有的两个未命中行。两行均在 `OPT_LOWPOWER` 条件体内；默认值 0
  时不可达。C3.3 的 LOWPOWER=1 隔离运行两行都真实命中。
- Branch 380 的 false arm 要求 NOUT>=32。默认 NOUT=30 时为 elaboration 常量；
  NOUT=32 隔离运行证明 false arm。
- Branch 488 true arm（reset 时 low-power read data 清零）和 502 true arm（无有效 read
  时清零）要求 OPT_LOWPOWER=1；LOWPOWER=1 隔离运行证明这些路径。
- 默认 Toggle 为 698/940。剩余未翻转项主要是设计常量或参数零扩展：
  `S_AXI_BRESP[1:0]`、`S_AXI_RRESP[1:0]` 恒为 OKAY；NOUT=30 使
  `S_AXI_RDATA[31:30]`、`axil_read_data[31:30]`、`r_gpio[31:30]` 恒 0；NIN=5 使
  `ck_gpio/ck_toggled/w_mask/int_toggled[31:5]` 恒 0；`unused` 与
  `INPUT_HANDLING.unused_inputs` 是 lint reduction 常量。
- 仍可用测试改善的 toggle gap 是 `S_AXI_AWADDR[1]` 未翻转。ARADDR[4:0] 已全部翻转；
  该项保留到 C3.4 review，不做 exclusion。

### `skidbuffer.v`

- 默认未命中 line 149、151、183 都属于 OPT_LOWPOWER=1 路径；LOWPOWER=1 隔离运行
  三行全部命中。
- 默认 10/15 branch 的缺口同时包含 parameter-only LOWPOWER arms，以及 line 137 的
  “同周期接收新输入且当前输出 stalled”组合。后者是合法可激励项，继续保留为 C3.4
  code-coverage closure 候选。
- OPT_INITIAL=0、OPT_OUTREG=1、OPT_PASSTHROUGH=1 不是当前 GPIO DUT 的合法参数矩阵；
  本阶段不通过改 DUT 参数或 exclusion 假装覆盖。

## 分组边界

C3.3 保持十个独立 URG merge groups：default GPIO、NOUT32、NIN1/NOUT1、skid0、
lowpower1、NIN0、bad-slave、controlled slave、lifecycle、checker selftest。不同 top、参数、
source signature、coverage object 的 VDB 不合并。单参数 run 的 top-wide 百分比仅用于该
配置的 reachability 证据，不能与 16-run default group 直接相加形成“更高 Overall”。

## C3.4 边界

本报告没有创建 coverage exclusion 或 waiver，没有改变 DUT 功能，也不宣称最终 sign-off。
`SPEC-MASK-001`、可激励 skid stall branch、AWADDR[1] toggle、结构常量的 waiver 审核和
最终 traceability/sign-off 仍属于 C3.4。
