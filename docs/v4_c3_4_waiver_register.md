# AXI4-Lite v4.0-C3.4-C Waiver Register

状态：**DRAFT—PENDING WAIVER APPROVAL**。本表只提出候选；没有任何 candidate
被自动批准、exclude 或从 coverage goal 删除。审批人应是项目规格/verification owner。

## 1. 候选总表

| Candidate ID | requirement / object | 分类 | 状态 | 风险 |
|---|---|---|---|---|
| WV-CODE-RESP-001 | REQ-AXI-002；BRESP/RRESP non-OKAY toggle | RTL structurally constant | PENDING_OWNER_APPROVAL | 低：当前 DUT 没有 error-response 功能；若规格以后要求 SLVERR，waiver 立即失效 |
| WV-CODE-NIN-PAD-001 | REQ-CFG-002；NIN=5 上部 read/INT padding 与 lint constant | parameter structural constant | PENDING_OWNER_APPROVAL | 低：错误 exclusion 范围过宽会掩盖有效低位 toggle |
| WV-CODE-NOUT-PAD-001 | REQ-GPIO-002/REQ-CFG-002；NOUT=30 上部 output padding | parameter structural constant | PENDING_OWNER_APPROVAL | 低：仅限 default build；NOUT=32 必须保留独立证据 |
| WV-CODE-SKID-CFG-001 | skidbuffer OPT_INITIAL=0/OPT_OUTREG=1 truth-table arms | non-applicable generic-module configuration | PENDING_SUPPORTED_MATRIX_DECISION | 中：若 skidbuffer 被独立复用，这些模式可能重新适用 |
| WV-FUNC-LAT-001 | REQ-AXI-002；accepted-to-response latency=0 bin | RTL/NBA sampling structurally unreachable | PENDING_OWNER_APPROVAL | 低至中：若换 combinational-response DUT 或改变采样定义，候选失效 |
| WV-V4-DEPTH-001 | controlled slave invalid-depth `$fatal` branch | negative configuration | PENDING_SCOPE_DECISION | 低：不应为了 line coverage 污染 clean regression；可单独做 expected-fatal test |

## 2. 逐项证据

### WV-CODE-RESP-001

- Source/condition：`dut/rtl/axilgpio.v:265,315` 直接赋 `2'b00`；当前 DUT 没有
  DECERR/SLVERR 生成路径。
- Logic proof：两位输出在所有合法 request、stall、reset 和参数配置下均为 0，
  所以 0->1/1->0 均不可发生。
- Evidence：default combined `axilgpio` toggle detail 显示
  `S_AXI_BRESP[1:0]`、`S_AXI_RRESP[1:0]` 双向均 No；正常回归与 negative detector
  对合法 OKAY/协议违规的边界已分开验证。
- Run/config：C3.4-A default 17 runs + C3.4-B seed43；NIN=5/NOUT=30/SKID1/LOWPOWER0。
- Owner/action：确认产品规格确实只支持 OKAY 后审批；不得扩展到 controlled slave
  或未来增加 error response 的版本。

### WV-CODE-NIN-PAD-001

- Source/condition：`axilgpio.v:451-454,460-461`；default NIN=5。
- Logic proof：`ck_gpio/ck_toggled/w_mask/int_toggled[31:5]` 由拼接显式补 0；
  `INPUT_HANDLING.unused_inputs` 以 `1'b0` 参与 reduction，恒 0。
- Evidence：上述四组各 27 bits 的双向 toggle 全部 No，与 216 个缺口方向位对账；
  NIN=1、NIN=0 独立 build 验证 parameter elaboration，但未跨 merge。
- Owner/action：只允许按精确 bit range 和 default parameter signature 审批。

### WV-CODE-NOUT-PAD-001

- Source/condition：`axilgpio.v:378-384,486-503`；default NOUT=30。
- Logic proof：`r_gpio[31:30]` 每时钟被 line381 清零，read path 先整字清零后只写
  `[NOUT-1:0]`，所以 `r_gpio/axil_read_data/S_AXI_RDATA[31:30]` 恒 0。
- Evidence：default 对应 12 个方向位均 No；NOUT=32 seed32 使 line380 false arm
  covered，证明 full-width 合法配置而不是把参数分母混入 default。
- Owner/action：审批范围必须写明 NOUT=30；NOUT=32 不适用此 waiver。

### WV-CODE-SKID-CFG-001

- Source/condition：`skidbuffer.v:133,146,152`。
- Logic proof：GPIO DUT 实例固定 OPT_INITIAL=1、OPT_OUTREG=0；因此 initial-if false
  arms 和 line152 左操作数为 0 的组合不能出现。LOWPOWER1 对 line149/151/183
  的合法 alternate paths 已真实命中，不包含在本 candidate。
- Evidence：default three instances line18/21、condition11/14、branch10/15；
  condition line137 两个缺组合由 `o_ready=!r_valid` 与
  `o_valid=!i_reset&&(i_valid||r_valid)` 证明矛盾；`unused` 两个 toggle 方向恒 0。
- Owner/action：先冻结 supported matrix。若 `skidbuffer` 作为独立 IP 支持
  OPT_INITIAL=0 或 OPT_OUTREG=1，应拒绝本候选并增加独立参数测试。

### WV-FUNC-LAT-001

- Source/condition：coverage `axi4l_gpio_coverage.sv:121-140,303-310`；monitor
  `axi4l_monitor.sv:145-224`；DUT `axilgpio.v:255-315`。
- Logic proof：accept_cycle 在请求 handshake sampled edge 记录；registered
  BVALID/RVALID 通过同沿 NBA 更新，monitor 只能在下一 sampled edge 完成 response，
  所以 `response_cycle-accept_cycle>=1`。
- Evidence：combined per-bin immediate=0、one=146、short=252、moderate=82、
  extended=228；`axi_response_cg` 唯一缺口就是 immediate。
- Run/config：C3.4-A default + C3.4-B seed43 combined report，18 test records。
- Owner/action：若 metric 意图是当前 registered GPIO DUT 的 accepted-to-completed
  latency，批准“不适用”；若 intent 是覆盖任意 AXI4-Lite slave，则应把 bin移到
  controlled/combinational slave专属 covergroup，而不是降低当前 DUT goal。

### WV-V4-DEPTH-001

- Source/condition：controlled test slave 的 depth=0 或 depth>MAX_DEPTH `$fatal` guard。
- Evidence：合法 depth2/3/4/8 已由独立 B2 component tests覆盖；该 branch不是 GPIO DUT。
- Owner/action：决定是否需要独立 expected-fatal negative flow。未决定前保留 raw gap，
  不能在 clean regression 中故意 fatal 来冲 coverage。

## 3. 明确不是 waiver 的项目

| ID | 结论 |
|---|---|
| P-HIT-LOWPOWER | `axilgpio.v:489,503` 与 `skidbuffer.v:149,151,183` 在 LOWPOWER=1 seed35 隔离配置命中；是 parameter-specific HIT。 |
| P-HIT-NOUT32 | `axilgpio.v:380` false arm 在 NOUT=32 seed32 隔离配置命中；是 parameter-specific HIT。 |
| FUNC-W1C-8OF8 | 两个 strobe-off/hardware-changing bins由 seed43 独占命中，combined cross 8/8；已关闭，不是 waiver。 |
| SPEC-MASK-001 | 2026-10-31 项目决议 MASK1=enable/MASK0=masked；RESOLVED specification decision，不是 waiver。 |

## 4. 审批记录（待填写）

每项审批必须记录：decision（approve/reject/needs-test）、owner、date、适用 source
commit、精确 config/bit range、到期/失效条件和 residual risk。未填完整前状态保持
`PENDING_*`；任何后续 DUT、采样定义或 parameter matrix 变化都要求重新审查。
