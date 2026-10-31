# AXI4-Lite v4.0-C3.4-C DUT-only Coverage Audit

状态：**审计完成；DRAFT—PENDING WAIVER APPROVAL；不是 final sign-off**。

## 1. 审计对象与证据边界

- C3.4-A 基线：`v4.0-c3.4a-baseline` ->
  `e1404e5906a08fca70071a5a0de02f3754fe0376`；当前 HEAD 与该 commit 一致。
- 复用证据：`sim/c3_4_coverage_closure_reviewed_final/` 的 51/51 runs、
  12/12 URG merges、UVM W/E/F=0/0/0、runtime SVA failure=0。
- 新增定向证据：`sim/c3_4b_w1c_fresh/` 的 seed43 单项 run PASS，exit=0，
  UVM W/E/F=0/0/0，SVA failure=0；standalone merge PASS。
- 本审计主报告：`sim/c3_4b_w1c_combined/report/`。命令只合并兼容的 default
  GPIO DUT 数据库：C3.4-A `merged_gpio_dut_default.vdb` 与 seed43
  `merged_gpio_dut_default.vdb`；URG exit=0，未报告 source/schema incompatibility。
- 当前未提交 C3.4-B 源码全部保留。DUT、coverage class、AXI monitor 在 combined
  数据生成后未改变；旧库和新库共用未改动的 covergroup schema。C3.4-B 新测试、
  scoreboard 注释和规格文档属于当前 dirty worktree，不应把此审计误称为 clean-commit
  reproduction。
- 本轮没有运行 51-run 全量回归，没有修改 DUT、删除 bin、降低 goal、添加 exclusion，
  也没有跨不兼容参数 build 合并 VDB。

## 2. 为什么 81.39% 不是 DUT-only

combined dashboard 的 81.39% 包含 `tb_top`、interfaces、controlled test slave、
SVA bind module 和 `uvm_pkg` 等分母：Line 189/232、Condition 72/103、Toggle
1834/2870、Branch 99/130、Assert 71/73、Group 99.64%。其中
`v4_slave` Line 55.56%/Condition 45.00%/Toggle 2.74%/Branch 52.17%，
`v4_axi_if` Toggle 2.74%；这些是 TB infrastructure，不是 GPIO DUT RTL。

### 2.1 默认配置 DUT-only 精确表

默认 build：NIN=5、NOUT=30、OPT_SKIDBUFFER=1、OPT_LOWPOWER=0、
DEFAULT_OUTPUT=0；source 为 `dut/rtl/axilgpio.v` 与 `dut/rtl/skidbuffer.v`。

| 对象/边界 | Line | Condition | Toggle | Branch | Assert |
|---|---:|---:|---:|---:|---:|
| `axilgpio` / `tb_top.dut` self instance | 80/82 (97.56%) | 21/21 (100.00%) | 700/940 (74.47%) | 55/58 (94.83%) | N/A |
| `skidbuffer`, AW instance, DW=3 | 18/21 (85.71%) | 11/14 (78.57%) | 38/40 (95.00%) | 10/15 (66.67%) | N/A |
| `skidbuffer`, AR instance, DW=3 | 18/21 (85.71%) | 11/14 (78.57%) | 38/40 (95.00%) | 10/15 (66.67%) | N/A |
| `skidbuffer`, W instance, DW=36 | 18/21 (85.71%) | 11/14 (78.57%) | 302/304 (99.34%) | 10/15 (66.67%) | N/A |
| 纯 DUT RTL 三实例合计（不含 bind SVA） | 134/145 (92.41%) | 54/63 (85.71%) | 1078/1324 (81.42%) | 85/103 (82.52%) | N/A |
| URG `tb_top.dut` subtree（含 bind SVA） | 134/145 (92.41%) | 54/63 (85.71%) | 1470/1728 (85.07%) | 85/103 (82.52%) | 71/71 (100.00%) |

`tb_top.dut` 的 89.14% 是含 `axi4l_gpio_sva_i` 的 hierarchy score；bind SVA
额外贡献 Toggle 392/404 和 Assert 71/71。它适合表示“DUT subtree + checker”，
但不能替代上面的纯 RTL composite。URG 的 `skidbuffer` module-definition Toggle
97.17% 是 DW=3 与 DW=36 两个 parameter definition 百分比的聚合，不应伪造为一个
covered/total；因此表中按真实实例列出。

## 3. 默认配置 code gap 的行级分类

### 3.1 `axilgpio.v`

- Line 489、503：默认 OPT_LOWPOWER=0 时不可达；LOWPOWER=1 seed35 隔离 run
  分别为 1/1。对应 branch 488 的 true arm 与 line 502 的 true arm也在该配置命中。
- Branch line 380 false：要求 NOUT>=32。默认 NOUT=30 时常量为 true；NOUT=32
  seed32 隔离 run 证明 false arm covered。不同参数库未合并。
- Toggle 未命中 240 个方向位已完全落在结构常量：
  `S_AXI_BRESP[1:0]`、`S_AXI_RRESP[1:0]` 恒 OKAY；NOUT=30 使
  `S_AXI_RDATA[31:30]`、`axil_read_data[31:30]`、`r_gpio[31:30]` 恒 0；
  NIN=5 使 `ck_gpio/ck_toggled/w_mask/int_toggled[31:5]` 恒 0；`unused` 与
  `INPUT_HANDLING.unused_inputs` 是 lint-reduction 常量。端口缺口 12 个方向位，
  内部信号缺口 228 个方向位，与 URG 940-700 完全对账。

### 3.2 `skidbuffer.v`

- 默认未命中 line 149、151、183 为 OPT_LOWPOWER 路径；LOWPOWER=1 seed35
  分别为 1/1，证明合法 alternate configuration 可达。
- Line 137 branch 已命中。其 condition truth-table 中 `i_valid=0,o_ready=1,
  o_valid=1,!i_ready=1` 与 `i_valid=1,o_ready=1,o_valid=0,!i_ready=1` 不可达：
  在该 `else if` 中 reset 已为 0，且 `o_ready=!r_valid`、
  `o_valid=!i_reset&&(i_valid||r_valid)`。
- Line 152 缺少“左操作数=0、o_ready=1”组合；当前 GPIO DUT 固定
  OPT_OUTREG=0，因此 `!OPT_OUTREG` 使左操作数恒 1。只有 LOWPOWER=1、
  OPT_OUTREG=1、i_valid=0 的 generic-module 模式才可产生该组合；该模式不是
  `axilgpio` 支持矩阵。
- Branch line 133/146 的 false arm 要求 OPT_INITIAL=0；GPIO DUT 三个实例固定
  OPT_INITIAL=1。默认 line 148 的 LOWPOWER arms与 line 178 final-else由
  LOWPOWER=1 隔离 run证明。每个实例仅剩 `unused` 两个 toggle 方向，属于结构常量。

## 4. W1C 逐 bin 审计

结论：`w1c_matrix_cg.data_x_strobe_x_hardware` **严格核实为 8/8**，不是只凭
covergroup 总分推断。combined `grpinfo.txt` 显示：

| data | strobe | hardware | count | 来源 |
|---|---|---|---:|---|
| 1 | on | changing | 5 | C3.4-A |
| 1 | on | stable | 38 | C3.4-A 36 + seed43 2 |
| 1 | off | changing | 1 | **seed43 独占** |
| 1 | off | stable | 14 | C3.4-A |
| 0 | on | changing | 5 | C3.4-A |
| 0 | on | stable | 1 | C3.4-A |
| 0 | off | changing | 1 | **seed43 独占** |
| 0 | off | stable | 2 | C3.4-A |

seed43 日志包含两个 `C3_4B_W1C_OFF_CHANGE` marker、一个 closure PASS、
`SCB_PASS`，以及真实 commit/snapshot=4/4、responses=8；故两项不只是 sequence
intent，也经过独立 cycle scoreboard/readback 检查。`w1c_collision_cg` 同时为 100%。

## 5. response immediate 缺口

`axi_response_cg` 唯一未覆盖项为 `cp_latency.immediate`：0 hit；其余为
one=146、short=252、moderate=82、extended=228。coverage 定义在
`axi4l_gpio_coverage.sv:121-140,303-310`，测量值是
`response_cycle-accept_cycle`。

DUT 在 `axilgpio.v:255-265,304-315` 于接受沿通过 NBA 更新 registered
`BVALID/RVALID`。monitor 在 `axi4l_monitor.sv:145-180,197-210` 同一 sampled edge
先记录 accept，只有后续 sampled edge 才能在 `:185-193/:215-224` 观察 response
handshake。因此当前 DUT、clocking-block 与 bin 定义下最小值为 1；0-cycle bin 是
结构不可达候选。它仍保留在分母中，未 exclude/delete，须由项目规格/verification
owner审批 waiver 或批准把该 bin 标为不适用；本审计不代替审批。

## 6. 结论与剩余项

- 默认 reachable gap：未发现新的合法、未激励 DUT RTL gap；AWADDR[1] 和 legal skid
  stall 已在 C3.4-A 命中。
- 参数专有 gap：LOWPOWER=1、NOUT=32、NIN=0、NIN/NOUT=1、SKID=0 均有隔离
  PASS 证据；只证明各自配置，不跨 build 合并分数。
- 结构常量/不适用配置：进入 `v4_c3_4_waiver_register.md`，全部仍是候选。
- `SPEC-MASK-001` 已由项目决议为 MASK1=enable/MASK0=masked，状态 RESOLVED；
  这是 RTL-derived behavioral spec，不是 waiver，DUT和独立 golden model逻辑未改。
- 仍需 owner 审批 waiver、确认 supported parameter matrix、决定 RAL/CI/lint/formal
  scope，并批准最终 verification report；在此之前不得宣布 final sign-off。
