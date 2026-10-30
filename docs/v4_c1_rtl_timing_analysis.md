# AXI4-Lite v4.0-C1 RTL Timing Analysis

> 状态：C1 代码审查与评审完成；最小 white-box adapter 方案已批准，C2 已按本文契约实现。
> C3 未启动；C2 结果见 `docs/v4_c2_timing_scoreboard.md`。
>
> 基线：`main` commit `e0e4a3001f9d533cc9d24e7695480926c8182cbb`，
> annotated tag `v4.0-b2-baseline`。本文只分析当前
> `/home/ray/AXI4_Lite_New` 的真实源码，不修改功能实现。
>
> 验证限制：本轮未重新运行仿真。文中的条件表达式和相对先后来自 RTL；除明确引用
> B2 已保存日志的地方外，逐周期表均为 **illustrative relative cycles**，不是新仿真得到的
> 绝对 cycle number。

## 1. 审查范围、术语与采样区域

审查文件包括 `docs/v4_driver_architecture.md`、`docs/v4_architecture_plan.md`、
`dut/rtl/axilgpio.v`、`dut/rtl/skidbuffer.v`、AXI/GPIO interface 与 monitor、
`axi4l_gpio_scoreboard.sv`、GPIO SVA/bind、B2 channel-pipeline/test-slave/reset tests。

本文严格区分四个事件：

| 事件 | 精确定义 | 含义 |
|---|---|---|
| external AW/W/AR handshake | 对应 `VALID && READY` 在上升沿成立 | AXI pin 上该 channel beat 被 DUT 接受 |
| skid accept | skid 的 `i_valid && o_ready`；本设计 `o_ready = !r_valid` | beat 可能直通，也可能在下游 stall 时进入 `r_data/r_valid` |
| write internal execute/commit | `axil_write_ready` 在上升沿成立 | AW/W 已在 skid 输出端配对，且 B response slot 可用；寄存器副作用在本沿 NBA 更新 |
| read internal snapshot | `axil_read_ready` 在上升沿成立 | AR 已在 skid 输出端，且 R response slot 可用；`axil_read_data` 在本沿从 pre-edge state 取样并 NBA 更新 |

采样区域约定：

- DUT 顺序块均为 `always @(posedge S_AXI_ACLK)`；条件和 RHS 在 Active region 使用
  pre-edge state 求值，非阻塞赋值在 NBA region 生效。因此同沿 read snapshot 看见的是同沿
  write/CDC/W1C 之前的状态。证据：`axilgpio.v:255-262,304-311,331-382,403-418,
  423-448,486-504`。
- `axi4l_if.sv:44-69` 的 `drv_cb`/`mon_cb` 使用 input `#1step`；interface 注释明确
  monitor/driver input 在沿前采样，driver output 在沿后更新。Monitor 的 handshake cycle
  因而代表 DUT 在该上升沿采样的稳定 pin 值，而不是 NBA 后的新寄存器值。
- GPIO monitor 同样使用 input `#1step`（`gpio_if.sv:14-29`），看到的是本沿 NBA 之前的
  pin state；一次本沿 commit 的 `o_gpio` 更新在下一编号 GPIO observation 中可见。Scoreboard
  的额外一 callback 延迟只是消除 monitor callback 顺序差异，并非 DUT latency
  （`axi4l_gpio_scoreboard.sv:216-230`）。
- SVA 在 `@(posedge clk)` 的 sampled-value 语义下检查 pin/internal event；bind 已把
  `write_accept`/`read_accept` 分别接到 `axil_write_ready`/`axil_read_ready`
  （`axi4l_gpio_sva_bind.sv:35-44`），不是外部 AW/W/AR handshake。

## 2. 写路径：accept、AW/W 配对、commit 与 B backpressure

### 2.1 精确条件

`OPT_SKIDBUFFER=1` 是当前默认配置（`axilgpio.v:96-99`）。AW 与 W 分别经过
`OPT_OUTREG=0` skid，连接见 `axilgpio.v:191-226`。每个 skid 的关键行为是：

- upstream ready：`o_ready = !r_valid`（`skidbuffer.v:158-161`）；
- downstream valid：`o_valid = !i_reset && (i_valid || r_valid)`（`skidbuffer.v:166-183`）；
- 若本沿 upstream handshake，同时 downstream valid 且 `!i_ready`，则置
  `r_valid <= 1` 并保存 payload（`skidbuffer.v:131-155`）；
- reset 清除 `r_valid`，stall 时保持 `o_valid/o_data`（`skidbuffer.v:133-153,
  303-312`）。

当前 GPIO DUT 唯一的 write internal execute enable 是：

```systemverilog
axil_write_ready = awskd_valid && wskd_valid
                && (!S_AXI_BVALID || S_AXI_BREADY);
```

证据：`axilgpio.v:228-229`。因此：

1. AW 和 W 可在不同外部周期被各自接受；DUT 只按两个 skid 输出端的 FIFO head 配成一笔写。
2. 完整 pair 已在两个 skid 中也不保证立即 commit；若 `BVALID && !BREADY`，条件为 0。
3. commit 沿同时使 `axil_bvalid <= 1`（`axilgpio.v:255-264`）并执行对应寄存器写
   （`axilgpio.v:327-382,423-448`）。若同沿旧 B handshake 且新写 commit，`else if`
   优先保持 `BVALID=1`，形成 back-to-back response。
4. `BRESP` 恒为 OKAY（`axilgpio.v:264-265`）。B stall 时 `BVALID/BRESP` 稳定由
   `axi4l_gpio_sva.sv:65-67` 检查。

AW/W pairing 不使用 AXI ID。黑盒 monitor 分别收集 AW、W handshake，再将各自最老项
配对，完整 write 的 `accept_cycle=max(aw_cycle,w_cycle)`
（`axi4l_monitor.sv:88-119`）；B 再与最老 complete pair 关联
（`axi4l_monitor.sv:121-130`）。这是协议关联，不是内部 commit 观察。

### 2.2 为什么现有 scoreboard 会提前更新

现有 scoreboard 在 monitor 发布 complete AW/W pair 后，将 request 放入
`request_events`（`axi4l_gpio_scoreboard.sv:194-201`），并在 `accept_cycle`：

- 立即建立期望 B；
- 立即把 LOAD/SET/CLEAR/TOGGLE、CHANGED W1C、MASK 写入 `next_*`；
- 对输出写建立 `accept_cycle+1` 的 GPIO side-effect expectation。

证据：`axi4l_gpio_scoreboard.sv:337-399`。当 `BVALID && !BREADY` 时，两个 skid 仍可各
接受一笔后继 AW/W 并将它们缓冲；外部完整 acceptance 已发生，但
`axil_write_ready=0`，所以 RTL 尚未执行。这时 scoreboard 已更新 model，直到 B slot
释放才真正 commit，造成提前的 pin expectation、后续读值和状态预测错误。

## 3. 读路径：AR buffering、snapshot 与 R backpressure

### 3.1 精确条件

AR 经独立 `OPT_OUTREG=0` skid（`axilgpio.v:273-286`）。当前 DUT 唯一的 read snapshot
enable 是：

```systemverilog
axil_read_ready = arskd_valid && (!axil_read_valid || S_AXI_RREADY);
```

证据：`axilgpio.v:288-289`。因此 external `ARVALID && ARREADY` 只表示地址 beat 进入/通过
skid，不保证本沿 snapshot。若已有 `RVALID && !RREADY`，一个后继 AR 仍可被空 skid
接受并缓冲，但 `axil_read_ready=0`。

在 snapshot 沿：

- `axil_read_valid <= 1`（`axilgpio.v:304-313`）；
- `axil_read_data` 在 `!S_AXI_RVALID || S_AXI_RREADY` 时从 pre-edge architectural state
  解码（`axilgpio.v:486-504`）；
- `RRESP` 恒为 OKAY（`axilgpio.v:313-315`）。

当 `RVALID && !RREADY`：上述 read-data guard 为假，且 `axil_read_ready=0`，所以
`RVALID/RDATA/RRESP` 全部保持。SVA 明确检查
`rvalid && !rready |=> rvalid && $stable({rdata,rresp})`
（`axi4l_gpio_sva.sv:69-71`）。当旧 R handshake 与已缓冲的下一 AR snapshot 同沿发生时，
`axil_read_valid` 保持 1，NBA 后 `RDATA` 切换为下一响应的快照，允许无空泡替换。

### 3.2 现有 read expectation 的缺口

Monitor 在 external AR handshake 当沿发布 request（`axi4l_monitor.sv:132-141`）；scoreboard
又在该 `accept_cycle` 调用 `register_read_value()` 保存期望 RDATA
（`axi4l_gpio_scoreboard.sv:290-300,352-355`）。若 AR 在 prior R stall 时被缓冲，则真正
snapshot 可能晚很多周期；期间已 commit 的 writes、CDC、CHANGED 或 MASK 更新都应影响
该读。当前 acceptance-time snapshot 会错误冻结旧值。

## 4. Register map 与逐寄存器语义

地址按 `addr[4:2]` 解码，低两位不参与 word decode（`axilgpio.v:148-156,527-529`）。

| 地址 | 名称 | 精确 RTL 行为 |
|---|---|---|
| `0x00` | LOAD | commit 时对每个 `WSTRB[k]=1` 的 byte 用 WDATA 覆盖；未 strobed byte 保持。`apply_wstrb`：`axilgpio.v:327,507-519`；LOAD：`336-337`。 |
| `0x04` | SET | strobed byte 内 `r_gpio |= WDATA`；`axilgpio.v:338-348`。 |
| `0x08` | CLEAR | strobed byte 内 `r_gpio &= ~WDATA`；`axilgpio.v:350-360`。 |
| `0x0C` | TOGGLE | strobed byte 内 `r_gpio ^= WDATA`；`axilgpio.v:362-373`。 |
| `0x10` | INPUT | read `qq_gpio`，即第二同步级；write 无 architectural effect；`axilgpio.v:410-418,451-452,494-499`。 |
| `0x14` | CHANGED | read sticky `toggled`；write-one-to-clear 只作用于 `WSTRB[bit/8] && WDATA[bit]`；`axilgpio.v:423-435,452,497`。同拍 hardware change 的后一个 NBA assignment 胜出，故 HW set 优先于 SW clear。 |
| `0x18` | MASK | normal byte-strobed replace，最终仅保留 `[NIN-1:0]`；`axilgpio.v:439-454,498`。实际 RTL polarity 是 **1=enable**，因为 IRQ/INT 用 `r_mask & toggled`，虽然文件头注释写成“1 masks”；以实现与 SVA 为准（`axilgpio.v:403-407,454-455`，`axi4l_gpio_sva.sv:123-127`）。 |
| `0x1C` | INT | read `r_mask & toggled` 的组合 active bits；write 无 effect；`axilgpio.v:454,499`。注意标量 `o_int` 是上一沿 old mask/old toggled 计算后寄存的值，不要求与当前 INT read 同拍相等。 |

补充边界：

- `r_gpio` 内部为 32 bit，但每沿都将未实现的 `[31:NOUT]` 强制为 0；reset 将
  `[NOUT-1:0]` 置 `DEFAULT_OUTPUT`（`axilgpio.v:378-384`）。所有 output read alias
  仅返回 `NOUT` 位，其余为 0（`axilgpio.v:492-500`）。
- `NIN>0` 时，0x10..0x1C 是输入侧寄存器；`NIN=0` 时 decode top bit 被强制为 0，
  这些地址按低两位 alias 回 LOAD/SET/CLEAR/TOGGLE 的 output read/write 语义
  （`axilgpio.v:336-375,494-500`），并且 `o_int=0`（`465-471`）。C2 若要支持参数矩阵，
  不能假定输入寄存器永远存在。
- 输入 pipeline 每沿执行 `{last,qq,q}<={qq,q,i_gpio}`，reset 清零
  （`axilgpio.v:410-418`）。change detect 使用 pre-edge `last ^ qq`
  （`423-435`），不是 raw `i_gpio`。
- `r_int <= |(r_mask & toggled)` 使用 pre-edge state，reset 优先
  （`axilgpio.v:400-408`）。MASK write、CHANGED W1C/hardware set 与 IRQ 寄存更新同沿时，
  IRQ 本沿仍基于旧 MASK/CHANGED；下一沿才反映新 sticky/mask。
- 写、读分别由 `axil_write_ready` 与 `axil_read_ready` 独立使能。若同沿都成立，RTL
  只定义各自对 pre-edge state 的并行采样/更新；AXI4-Lite 没有跨方向 ordering，验证环境
  不得从 AW/W/AR 或 B/R callback 顺序臆造“写先于读”或“读先于写”。

## 5. Relative-cycle timing tables

以下 `T0/T1/...` 只表达相对先后。表中 “pre-edge condition” 是 DUT Active region 求值
所见值；“after NBA” 是该沿寄存器更新后的结果。

### 5.1 (a) AW_B 早于 W_A：B2 master capability 与 GPIO DUT 边界

该场景已由 **受控 test slave** 的保存日志证明 `AW_B=13 < W_A=23`，测试刺激和检查见
`axi4l_v4_pipeline_tests.sv:12-29,86-99`。下面只是该协议配对的 illustrative 表；它不证明
GPIO DUT 内部 commit cycle。

| 相对沿 | pin handshake | monitor/association | 结论 |
|---|---|---|---|
| T0 | `AW_A && AWREADY` | AW queue=`[A]` | 只有 address A；write A 尚不 complete。 |
| T1 | `AW_B && AWREADY` | AW queue=`[A,B]` | 在可配置 slave 上 AW_B 可先于 W_A。 |
| T2 | `W_A && WREADY` | pop oldest AW=A 与 oldest W=A；发布 complete write A | FIFO pairing，不按 worker 完成回调配对。 |
| T3 | `W_B && WREADY` | pair B；后续 B responses 仍 A、B | AXI4-Lite 无 ID，per-channel order 是关联依据。 |

当前 GPIO DUT 的 AW skid 只有一个 `r_valid` slot：AW_A 在缺 W 时被缓冲后，
`AWREADY=!r_valid`，直到 A 被消费前不能再接 AW_B（`skidbuffer.v:128-160`，
`axilgpio.v:202-208`）。所以严格 `AW_B < W_A` 是 B2 Driver+test-slave 能力场景；在 GPIO
DUT 上最多可在 A 消费后再接受 B，不能把 B2 component evidence 当成 GPIO depth evidence。

### 5.2 (b) B stall 下 buffered side-effect、nonzero WSTRB consecutive writes

假设 A 已生成 stalled B，B 是后继 `SET/CLEAR/TOGGLE/LOAD`，`WSTRB!=0`。

| 相对沿 | pre-edge condition | internal event / after NBA | scoreboard 风险 |
|---|---|---|---|
| T0 | A 的 `axil_write_ready=1` | commit A；after NBA `BVALID=1` | A 正常建模。 |
| T1 | `BVALID=1,BREADY=0`；AW_B/W_B skid 均空；external AW_B/W_B handshake | `axil_write_ready=0`；AW_B/W_B 被各自保存到 `r_data/r_valid`，**无 B 副作用** | monitor 已发布 complete B；旧 scoreboard 在 T1 更新 model。 |
| T2..Tk | `BVALID && !BREADY` | `axil_write_ready=0`；buffer payload/valid 保持 | 预测可持续领先真实 RTL，latency 无固定上界。 |
| Tk+1 | `BREADY=1` 且两个 `skd_valid=1` | `axil_write_ready=1`；旧 B handshake 与 B commit 同沿；WSTRB 精确门控；after NBA `BVALID` 仍 1 | 正确模型应在此 commit event 更新。 |
| Tk+2 | 若新 B response 被接受 | 可继续接受/执行后继 C，受单 slot skid 与 B slot 条件约束 | “consecutive” 不能等同于“accept_cycle 连续即 commit 连续”。 |

精确条件来自 `axilgpio.v:228-229,255-265,327-382`；buffer capture/hold 来自
`skidbuffer.v:133-160`。

### 5.3 (c) buffered AR/read snapshot 与 intervening write

| 相对沿 | pre-edge condition | internal event / after NBA | 期望 RDATA |
|---|---|---|---|
| T0 | read A snapshot enable=1 | snapshot A；after NBA `RVALID=1` | A 取 T0 pre-edge state。 |
| T1 | `RVALID=1,RREADY=0`；external AR_B handshake，AR skid 原为空 | `axil_read_ready=0`；AR_B 被缓冲，**未 snapshot** | 不应在 T1 冻结 B 的期望。 |
| T2 | R 继续 stall；某 write X 的 `axil_write_ready=1` | X commit；after NBA architectural state 改变 | X 可影响未来 B snapshot。 |
| T3 | `RREADY=1` 且 `arskd_valid=1` | A response handshake 与 B snapshot 同沿；after NBA RVALID 保持 1，RDATA 换成 B | B 读 T3 pre-edge state，包含 T2 已 commit 的 X。 |

证据：`axilgpio.v:288-315,486-504`。旧 scoreboard 在 T1 external AR acceptance 取快照
（`axi4l_gpio_scoreboard.sv:290-300`），会漏掉 T2 write。

### 5.4 (d) same-cycle read/write internal commit

| 相对沿 | pre-edge condition | Active-region RHS | after NBA |
|---|---|---|---|
| T0 | `axil_write_ready=1 && axil_read_ready=1`，读写同一 register | read case 从 old `r_gpio/toggled/r_mask/qq_gpio` 取值；write block独立计算 next state | `RDATA` 是 old value；register/o_gpio 是 write 后 value；BVALID/RVALID 均置 1。 |
| T1 | response 可见/握手依各自 READY | B/R 独立前进 | 不建立跨方向 response order。 |

这不是人为规定“read beats write”，而是当前 RTL 两组 posedge/NBA 的实际结果
（`axilgpio.v:304-315,331-382,423-448,486-504`）。C2 golden 在同一 internal-event cycle
应先从 pre-state 计算 read expectation，再并行计算/commit write next-state。

### 5.5 (e) reset while buffered

| 相对沿 | pre-edge condition | reset edge effect | verification contract |
|---|---|---|---|
| T0 | 可有 AW-only、W-only、complete write 等 B slot、AR 等 R slot、stalled B/R | 仅表示存在 in-flight/buffered state | 记录所属 reset epoch。 |
| T1 | `ARESETN=0`，故 `i_reset=1` | skid `r_valid<=0`；`BVALID/RVALID<=0`；output=`DEFAULT_OUTPUT`；q/qq/last/changed/mask/int 清零；`o_valid` 组合受 `!i_reset` 抑制 | 本沿不得生成 commit/snapshot；旧 epoch accepted/pairs 全 flush/abort。 |
| T2... | reset 保持 | 状态保持 reset 值；master pin owners 应 quiescent | 不允许旧 payload 穿越 reset。 |
| Tr | reset release | 只接受新 epoch handshakes | 新请求与旧 orphan response 不得关联。 |

证据：`skidbuffer.v:133-172`；`axilgpio.v:159,255-262,304-311,378-381,403-418,
423-448`。B2 reset test 已覆盖 Driver/test-slave 的 AW-only/W-only/pending B/pending R 等
abort/recovery（`axi4l_v4_reset_test.sv:43-65,104-158,197-208`），但它不替代本 C1 对
GPIO DUT internal buffer flush 的 RTL 结论。

### 5.6 (f) R channel stall snapshot stability

| 相对沿 | condition | R channel result |
|---|---|---|
| T0 | `axil_read_ready=1` | 在 T0 pre-state snapshot，after NBA `RVALID=1,RDATA=snapshot`。 |
| T1 | `RVALID=1,RREADY=0` | guard `!RVALID || RREADY` 为 0；RVALID/RDATA/RRESP 保持。空 AR skid 仍可能 external-accept 一笔后继 AR 并缓冲。 |
| T2..Tk | stall 持续 | snapshot 必须逐拍稳定；后继 AR 不得覆盖。 |
| Tk+1 | `RREADY=1` | 当前 R handshake；若有 buffered AR，则同沿 snapshot 下一笔，after NBA 可保持 RVALID=1 并替换 RDATA。 |

精确依据：`axilgpio.v:288-315,486-504`；协议 assertion：
`axi4l_gpio_sva.sv:69-71,78-93`。

## 6. C2 推荐 architecture

### 6.1 三层边界

1. **黑盒 AXI protocol/association layer（只看 pins）**
   - 分别发布 `AW_ACCEPT`、`W_ACCEPT`、`AR_ACCEPT`，携带 cycle、epoch 和 payload；
   - AW/W 各自 FIFO，最老对最老形成 `WRITE_PAIR`；AR 独立 FIFO；
   - B/R 只允许消费本方向最老 eligible request；检查 orphan response、duplicate response、
     per-direction ordering、stall stability、reset flush 和实际 outstanding；
   - 不从 complete pair 或 AR accept 猜 commit/snapshot cycle，不建立读写全局顺序。

2. **独立、spec-oriented GPIO golden model**
   - 自己维护 `golden_gpio/q/qq/last/changed/mask/int`，依据本文件第 4 节语义计算；
   - write 只在 `WRITE_COMMIT` event 更新，read 只在 `READ_SNAPSHOT` event 从 pre-state
     生成 expected RDATA；同 cycle 顺序固定为“从 pre-state snapshot，再 atomic next-state commit”；
   - internal monitor **不得**把 DUT 的 `r_gpio/r_mask/toggled/axil_read_data/o_gpio` 当作 expected。
     DUT state/pin 只能是 actual/diagnostic；否则会把同一 RTL bug复制到 expected。
   - input CDC/IRQ 的 cycle model 与 AXI association 分开，统一由 cycle/epoch 合并事件。

3. **可选 white-box timing adapter（bind，只读）**
   - 推荐最小稳定事件：
     `WRITE_COMMIT{epoch,cycle,word_addr,wdata,wstrb}` 对应 `axil_write_ready`；
     `READ_SNAPSHOT{epoch,cycle,word_addr}` 对应 `axil_read_ready`；
   - 可复用现有 bind 已能看到的 `axil_write_ready/awskd_addr/wskd_data/wskd_strb/
     axil_read_ready/arskd_addr` 边界（`axi4l_gpio_sva_bind.sv:35-44`）；
   - 不把 white-box event 用于通用 Driver/deep-slave sign-off；必须保留黑盒 drain/readback/end-to-end tests。

### 6.2 事件契约与不变量

建议每个 event 含 `{epoch, sample_cycle, monotonic_event_id}`；accepted beat 另含 channel-local
sequence number。必须检查：

- 每个 `WRITE_COMMIT` 恰好匹配当前 epoch 最老的完整 `WRITE_PAIR`；无 pair 的 commit 是
  orphan，已 commit pair 再 commit 是 duplicate；payload 必须与 pair 相同。
- 每个 `READ_SNAPSHOT` 恰好匹配当前 epoch 最老尚未 snapshot 的 AR；无 AR 是 orphan，
  重复 snapshot 是错误。
- B 只能匹配已 commit write，R 只能匹配已 snapshot read；当前 RTL 在 event 后一拍置 valid，
  但 checker 应以 event/response eligibility 验证，不从 callback 顺序推测。
- reset observation 先开启新 epoch并 flush 旧 AW/W partial、complete pair、AR、commit/snapshot
  pending；随后到达的旧 epoch event/response 必须报 stale/orphan，不能与新事务配对。
- 同 cycle events 必须按显式 phase 处理：读取所有 pre-state snapshots，计算 writes/CDC/W1C/
  IRQ next-state，再 atomic commit；analysis-port callback arrival order不具有语义。
- 对当前单-slot DUT，同一 cycle 至多一个 write commit、一个 read snapshot；checker 仍应对
  duplicate event 有显式错误，而不是静默覆盖。

### 6.3 C2 dedicated directed tests

至少加入：

1. B stall 后完整 LOAD/SET/CLEAR/TOGGLE 写在 skid 中等待；每项使用不同非零 WSTRB，
   比较 accept、commit、B、o_gpio 四种 cycle。
2. R stall 下接受后继 AR，在其真正 snapshot 前插入 output、MASK、CHANGED writes；确认
   expected RDATA 取 snapshot-time pre-state。
3. 同沿 read snapshot/write commit：覆盖 output、CHANGED、MASK、INT，证明 read-old/write-new。
4. CHANGED W1C 与 hardware change 同沿，验证 hardware set priority；MASK write/changed update 与
   registered IRQ 的一拍关系。
5. AW-only、W-only、complete pair waiting for B、AR waiting for R、B/R valid stall 各 reset；
   检查 epoch flush、no stale event、recovery。
6. RVALID stall 多拍的 RDATA/RRESP stability，且 skid 内有下一 AR；BVALID stall 对称检查。
7. 全寄存器 map、每个 byte-lane WSTRB、zero strobe、NOUT upper-bit zero、NIN masking；若参数
   构建允许，再覆盖 `NIN=0` alias。
8. 黑盒 drain/readback test 与 white-box precise-timing test 成对存在，防止过度依赖 hierarchy。

## 7. Backpressure 对准确计时的影响

当前 GPIO DUT 把“是否有 response slot”直接放进执行条件：

- write：`!BVALID || BREADY` 是 `axil_write_ready` 的必要条件；
- read：`!RVALID || RREADY` 是 `axil_read_ready` 的必要条件。

因此 B/R backpressure 不只延迟 response handshake，还会延迟后续 register execute/read
snapshot。只要 READY 可无限期为 0，accept-to-commit/snapshot latency 就没有固定上界。
纯黑盒 checker 可以验证最终 response/order/stability，但不能仅凭 accepted AW/W/AR 精确决定
GPIO side effect 或 read value 的拍点。要做逐拍 C2，必须二选一：批准最小 white-box event
monitor；或限制 stimulus，在 drain/quiescent boundary 才比较最终状态，并放弃歧义区间内的
精确 cycle claim。

## 8. C2 前待评审决策

1. 是否批准只读 bind timing adapter，并把上述最小 event fields 视为稳定 verification interface？
2. 若坚持纯黑盒，是否接受对 B/R stall+intervening side effect 场景只做最终值检查，而不做
   精确 snapshot/commit cycle 检查？
3. MASK 术语是否改称 `interrupt_enable` 以匹配实际 `1=enable`，还是保留 register 名并在 spec
   显式记录 polarity？本轮不改 RTL。
4. C2 参数 sign-off 是否必须包含 `NIN=0` 与多个 NIN/NOUT/WSTRB 边界构建？
5. internal event correlation 采用 monitor 自己的 FIFO head（推荐），还是允许为验证增加稳定的
   debug sequence tag？后者会扩大 DUT 接口，不建议在第一版采用。
6. 是否把 GPIO CDC/IRQ cycle checker拆成独立 component，使 AXI golden 只消费同步后的
   spec events？推荐拆分，但二者需共享 cycle/epoch coordinator。

## 9. C1 结论与评审门槛

- 精确确认：external complete AW/W acceptance 不等于 write commit；external AR handshake
  不等于 read snapshot。差异在 B/R backpressure 下必然可见。
- 精确确认：read snapshot 使用该 internal enable 沿的 pre-edge state；同沿 write/CDC/W1C
  更新不会反映在该快照中；R stall 期间数据必须稳定。
- 精确确认：实际 MASK polarity 为 1=enable；CHANGED 同沿 HW set 胜过 SW W1C；IRQ 是 old
  mask/changed 的 registered reduction。
- 已定位现有 scoreboard 的两个核心缺口：在 complete AW/W `accept_cycle` 提前更新 side
  effect；在 AR `accept_cycle` 提前冻结 RDATA。
- C2 推荐采用 accepted beat queues + independent golden GPIO + optional minimal internal
  commit/snapshot events，并保持 black-box/white-box 测试边界。

本文是 C2 的已批准 timing 基础。C2 未修改 DUT RTL/既有 SVA/v4 Driver，并按最小 adapter
实现；C3 coverage closure 仍需后续明确启动。
