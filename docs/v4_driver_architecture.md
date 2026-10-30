# AXI4-Lite v4.0 Driver 架构设计与 B2 实现记录

> 状态：v4.0-A 架构基准已冻结；v4.0-B2.1～B2.3 已在新工程集成并通过专用测试、兼容性回归与覆盖率回归。第 1～15 节保留设计形成过程，第 16 节记录实际交付。
>
> 基线：`/home/ray/AXI4_Lite_New` 的当前真实源码；`/home/ray/AXI4_Lite` 仅作为 v3.2 稳定只读基线。
>
> 仿真状态：2026-10-30 在已加载许可证环境的 VCS/URG V-2023.12-SP1 上实跑；未记录或输出许可证服务器信息。

## 1. 范围、术语与结论

v4.0-A 的目标是把 v3 的“transaction-level request/response decoupling”升级为真正的“跨事务、按 channel 独立推进”：AW、W、AR 各有独立有界 FIFO 和唯一 worker，B、R 各有独立有序等待队列和 collector。AXI4-Lite 没有 ID，因此只承诺：

- AW channel 内保持 sequence/dispatch 顺序；
- W channel 内保持同一顺序，禁止 W_B 越过 W_A；
- AR channel 内保持顺序；
- B 只与本方向最早具备响应资格的完整写请求关联；
- R 只与本方向最早已完成 AR handshake 的读请求关联；
- 读、写之间不建立虚构的全局完成顺序，混合流量的 UVM response 必须用 sequence_id/transaction_id 关联，不能假设跨方向返回顺序。

这里的“响应资格”不是“某个 worker 最早结束”。写 A 只有在 AW_A 和 W_A 都完成 handshake 后才具备 B 资格；读 A 在 AR_A handshake 后具备 R 资格。B/R 真正完成仍以 BVALID&&BREADY 或 RVALID&&RREADY handshake 为准。

## 2. 从真实源码确认的 v3 基线

### 2.1 Driver 的三种现有模式

`tb/axi_agent/axi4l_driver.sv` 明确保留三种互斥语义：

| 模式 | 选择方式 | `item_done()` 时点 | 已知能力 | 主要局限 |
|---|---|---|---|---|
| legacy/default | 两个 mode bit 都为 0 | B/R response 之后 | 与旧 v2 sequence 契约兼容；单事务路径直接 | 完全 blocking，没有跨事务 overlap |
| limited_overlap_mode | `limited_overlap_mode=1` | request-side drive 结束后 | v2.1 coverage-only 的 request/response 解耦；由单一 response mailbox 收集 | 不区分 B/R pending queue，不是可扩展的正式 pipeline；仍逐事务完成 AW/W 或 AR |
| pipelined_mode | `pipelined_mode=1` | AW+W 或 AR 已物理 handshake、context 已进入 pending response FIFO 后 | 读写独立 credit、B/R 独立 collector、`set_id_info()` response 路由、reset-aware credit wait、正常/abort response | request loop 仍一次只处理一个事务；写仅在单个 item 内 `fork drive_aw/drive_w join`，所以 AW_B 不可能在 W_A 完成前开始；不是跨事务 channel pipeline |

v3 pipelined mode 的 credit 在 request-side drive 前取得，写只有 AW 和 W 都完成后才进入 `pending_write_response_fifo`；读只有 AR 完成后才进入 `pending_read_response_fifo`。因此 v3 已实现“已接受请求与响应等待解耦”，但没有实现“不同 transaction 的 AW/W 独立推进”。

### 2.2 可复用内容

下列行为应保持，而不是重写其对外契约：

- `axi4l_seq_item` 已有 access、addr、data、strb、prot、五类 delay、四态 resp/rdata、transaction_aborted 以及 accept/response/AW/W cycle metadata。
- abort response 以 `transaction_aborted=1` 为唯一有效性判据；resp 和 rdata 保持四态 `'x`。
- `req.clone()` 后显式 `set_id_info(req)`，以及 response clone 后再次 `set_id_info(ctx.req_clone)`，继续作为 UVM response association 契约。
- interface 的 `drv_cb`/`mon_cb` 使用 input/output `#1step`，可继续作为 pin worker 的唯一时钟采样点。
- sequencer 本身是标准 `uvm_sequencer #(axi4l_seq_item)`，无需为 v4 改变 sequence API。
- monitor 已经分别记录 AW/W handshake，以 FIFO 方式把最老 AW 与最老 W 配对；B/R 又按各自方向 FIFO 关联。这一独立观察方式可用于 v4 Driver 黑盒检查。
- v3 pipeline/reset/stress sequences 已经检查 ID 路由、duplicate/missing response、credit leak、B/R stall、reset recovery，可作为 v4 新测试的素材，但不能把它们当成 channel-level 场景已经覆盖。
- 新工程的上述关键 Driver、Monitor、sequence item、Scoreboard 以及三组 v3 sequence 与旧 `/home/ray/AXI4_Lite` 对应文件逐文件只读比较一致；新工程测试路径已整理为 `tb/tests/directed` 与 `tb/tests/random`。

### 2.3 已知测试与 DUT 边界

`axi4l_v3_pipelined_test` 把 max_write_outstanding/max_read_outstanding 配成 3，但这只表示 Driver credit 上限。现有 ZipCPU GPIO DUT 的 skid buffer 实测最多形成 2 个 complete outstanding request。配置值 3 不等价于 DUT 接受深度 3，更不能证明通用 master BFM 已在 3-deep 情况正确工作。

v3 stress test 允许 depth 2 或 3，但现有断言重点仍是已观察深度至少 2、credit 与 monitor FIFO 一致。后续若要证明 master 支持 3/4/8 deep，必须使用单独的可配置 AXI4-Lite test slave，并把“BFM 能力验证”与“当前 GPIO DUT 集成验证”分开报告。

## 3. v4.0-A 设计目标、非目标与兼容策略

### 3.1 设计目标

1. AW、W、AR 跨事务独立排队、独立驱动，同时保持各 channel FIFO 顺序。
2. 写 A/B/C 同时进入 AW 和 W 的逻辑顺序；允许 AW_B 在 W_A 前完成，但不允许 AW_B 越过 AW_A，也不允许 W_B 越过 W_A。
3. B/R response 按方向有序关联，不依赖 worker 调度或完成回调顺序。
4. write/read credits 从成功预留到正常或 abort UVM response 发布完成全生命周期只归还一次。
5. reset 可以终止所有已被 Driver 取得但尚未完成 B/R handshake 的事务，包括 credit-wait、queue、partial handshake、complete accepted 和 response pending 状态。
6. 每个已取得的 sequence item 恰好一次 `item_done()`，每个 context 恰好一个 terminal UVM response。
7. 所有 queue 有显式 capacity，无无界增长；统计量能区分 reservation、partial、accepted、response pending 与 DUT 实际接受深度。
8. 保留三种 v3 模式，v4 作为新模式逐步引入，避免一次性破坏稳定回归。

### 3.2 非目标

- 不增加 AXI ID，不支持 AXI4 burst、乱序 response 或同一 channel 内重排。
- 不把读写方向合并为一个全局完成队列。
- 不通过 Driver 内部顺序替 Monitor/Scoreboard 推断总线行为。
- v4 Driver 阶段不同时重写 Scoreboard；Scoreboard/commit 模型是后续独立阶段。
- 不以当前 GPIO DUT 的 2-deep 实测能力证明通用 BFM 的 3/4/8-deep 能力。
- 不承诺消除 sequencer intake 的方向间 head-of-line blocking：单一 UVM pull port 上，一个已经取得但等待本方向 credit 的 item 会暂时挡住后续 item。已完成 dispatch 的读写 context 仍完全独立推进。若以后需要消除此限制，需要改变 sequence/dispatcher API，另案评审。

## 4. 总体架构与线程边界

```text
                                     +---------------------------+
Sequencer --get_next_item----------> | bounded Dispatcher        |
                                     | clone + set_id_info       |
                                     | reserve direction credit  |
                                     | reserve queue slots       |
                                     +-------------+-------------+
                                                   |
                           lifecycle_lock 内：registry + queues 原子提交
                                                   |
              +------------------------------------+----------------------------------+
              | Shared per-transaction Context Registry                              |
              | ctx_uid -> req clone / IDs / epoch / flags / state / terminal gate    |
              +----------------------+----------------------+--------------------------+
                                     |                      |
                    +----------------+--------+       +-----+----------------+
                    |                         |       |                      |
                 AW FIFO                  W FIFO    AR FIFO              order queues
                    |                         |       |            write_order/read_order
              AW worker                 W worker  AR worker                |
              (sole AW pin owner)       (sole W)  (sole AR)                |
                    |                         |       |                      |
                    +----------- mark handshake under lifecycle_lock ------+
                                                   |
                                      promote-oldest-eligible helper
                                  (按 dispatch 顺序扫描，不按线程结束顺序)
                                                   |
                                      +------------+-------------+
                                      |                          |
                              pending B ordered FIFO     pending R ordered FIFO
                                      |                          |
                                B collector                R collector
                              (sole BREADY owner)        (sole RREADY owner)
                                      |                          |
                                      +------ terminalize_once --+
                                                   |
                                     terminal response FIFO
                                                   |
                                     single Response Publisher
                                                   |
                                  seq_item_port.put_response()
                                                   |
                              release credit exactly once / retire ctx

Reset Coordinator -> epoch++ / cancel / drain / worker barrier / synthetic abort
                  -> terminalize_once -> terminal response FIFO
```

图中的 Response Publisher 是 `put_response()` 的唯一物理调用者。逻辑上仍是 B/R collector 产生正常结果并流向 `put_response`；串行 publisher 用来消除 B、R、reset 三方同时发布时的重复和端口并发风险。读写之间的发布先后只是到达顺序，不成为协议承诺。

### 4.1 线程/资源唯一所有权

| 执行体 | 唯一拥有的资源 | 可以修改的共享状态 | 明确禁止 |
|---|---|---|---|
| Dispatcher | `get_next_item/item_done` 调用权；当前未提交 item | 建 context、取得 credit、原子预留 queue slots、注册并入队 | 驱动任何 AXI pin；收 B/R；归还已提交 context 的 credit |
| AW worker | AWADDR/AWPROT/AWVALID | 只通过同步 helper 标记 aw_done/aw_cycle，归还 AW queue slot | 修改 W/AR/B/R pin；直接建立 B 关联 |
| W worker | WDATA/WSTRB/WVALID | 标记 w_done/w_cycle，归还 W queue slot | 让后一个 W 越过前一个；直接发布 response |
| AR worker | ARADDR/ARPROT/ARVALID | 标记 ar_done/accept_cycle，归还 AR queue slot | 修改其他 channel pin；直接收 R |
| eligibility helper | 无 pin；在 lifecycle_lock 内执行 | 从 write/read order queue 的头部连续 promote 到 pending B/R | 按 worker 完成时间 push pending FIFO |
| B collector | BREADY | 只处理 pending B 的头；捕获 BRESP；请求 normal terminal | 处理没有 eligible head 的 B；释放别的 context |
| R collector | RREADY | 只处理 pending R 的头；捕获 RRESP/RDATA；请求 normal terminal | 跨过 pending R 头；建立读写全局顺序 |
| Reset Coordinator | reset_epoch、reset_active、worker barrier | 标记 cancel、清队列、对未完成 context 请求 abort terminal | 直接驱动 AW/W/AR/B/R pin；对已完成 B/R handshake 的 context 再 abort |
| Response Publisher | `put_response`；terminal response FIFO | response_sent、completed、credit release、registry retire | 产生第二个 response；改变总线 handshake 结果 |

所有共享 context/queue/counter 状态必须通过同一个 `lifecycle_lock` 或封装后的原子 helper 访问。单独依赖 SystemVerilog task 的调度先后不构成同步。

## 5. Transaction context 拟定数据模型

建议新增内部类 `axi4l_v4_context`。它不是新的 sequence API，而是 Driver 内部跨线程共享对象。每个 dispatcher 接管的 item 都生成唯一、单调递增的 `ctx_uid`；不能拿 UVM transaction_id 当全局唯一 key，因为不同 sequence 可能复用 transaction_id。

### 5.1 字段

| 类别 | 拟定字段 | 定义与有效性 |
|---|---|---|
| 原始请求 | `axi4l_seq_item req_clone` | clone 后立即 `set_id_info(original_req)`；之后 worker 只读 stimulus 字段 |
| UVM 路由 | `sequence_id`、`transaction_id` | 从 original request 显式保存；response 再用 `set_id_info(req_clone)` |
| 唯一身份 | `longint unsigned ctx_uid`、`dispatch_index` | Driver 内唯一；dispatch_index 用于方向内 order queue 与诊断 |
| 请求 payload | `access, addr, data, strb, prot` | 从 clone 固化；禁止 worker 修改 |
| delay | `aw_delay, w_delay, ar_delay, bready_delay, rready_delay` | 各 owner 只消费自己的 delay |
| reset | `longint unsigned reset_epoch`、`cancel_requested` | 建 context 时记录当前 epoch；任何 worker 驱动前和每个 clock boundary 比较 |
| dispatch | `item_done_sent`、`dispatch_committed`、`registry_owned` | 保证 sequencer handshake 一次；committed 表示相关 queue 已原子可见 |
| credit | `credit_owned`、`credit_released`、`credit_kind` | credit_owned 只有真正取得 token 后置 1；publisher 终结时最多释放一次 |
| queue membership | `aw_queued/aw_inflight`、`w_queued/w_inflight`、`ar_queued/ar_inflight` | reset drain、slot 返还和 stale-entry 丢弃的依据 |
| channel handshake | `aw_done, w_done, ar_done` | 只能由对应 worker 经同步 helper 从 0 置 1 |
| timing | `aw_cycle, w_cycle, accept_cycle, response_cycle` | 对应 done flag 为 1 才有效；写 accept_cycle=max(aw_cycle,w_cycle)，读等于 ar_cycle |
| response eligibility | `b_eligible_enqueued`、`r_eligible_enqueued`、`response_pending` | 只能由按 order queue 扫描的 promote helper 设置 |
| bus completion | `response_handshake_done`、`resp`、`rdata` | B/R collector 在有效 handshake 时原子写入；write 的 rdata 无效 |
| terminal | `terminal_kind={NONE,NORMAL,ABORT}`、`terminal_enqueued`、`response_sent`、`completed`、`aborted` | terminal_kind 只能从 NONE 原子转换一次；completed 表示 UVM response 已发布且 credit 已处理 |
| state | `outstanding_state_e state` | 诊断状态，不替代上述 ownership flags |

推荐状态枚举：

```text
FETCHED_WAIT_CREDIT
RESERVED_WAIT_QUEUE
QUEUED
PARTIAL_ACCEPT
REQUEST_ACCEPTED
RESPONSE_PENDING
RESPONSE_HANDSHAKEN
TERMINAL_PENDING_PUBLISH
COMPLETED
ABORTED
```

状态是可读摘要；并发正确性由不可逆 flags、epoch 和 lock 保证。比如写 context 可以同时是 `aw_done=1`、`w_done=0`、`state=PARTIAL_ACCEPT`。

### 5.2 多线程同步不变量

1. `terminal_kind` 只允许 `NONE -> NORMAL` 或 `NONE -> ABORT`，没有反向或二次转换。
2. `response_sent` 只由 Response Publisher 设置；一旦为 1，任何 reset/collector 都跳过。
3. `credit_released` 只在 `credit_owned && !credit_released` 时设置，并与 token put 在同一临界区完成。
4. `item_done_sent` 只由 Dispatcher 设置；Reset Coordinator 只能请求 cancel 和等待 dispatcher ack。
5. queue pop 与 slot 返还是一个原子 ownership transfer：要么 entry 仍在 queue，要么 worker 持有 in-flight handle，不能两边都认为自己应返还 slot。
6. epoch 不匹配的 entry 永远不允许重新驱动 pin；只能完成 stale cleanup。其 terminal response 已由 reset 路径决定。
7. terminal response FIFO 中每个 ctx_uid 最多一项；publisher 发布后从 registry retire。
8. 正常 B/R handshake 的采样条件必须包含 `ARESETN === 1'b1`。在有效 handshake 记录后，即使 response 尚未 put_response，也不能被 reset 改成 abort。

### 5.3 exactly-once terminal response

`terminalize_once(ctx, kind)` 必须在 `lifecycle_lock` 内执行：

- 若 `terminal_kind != NONE`，返回 “lost race”，调用者不再发布、不再归还 credit；
- NORMAL 只有 B/R collector 在已记录有效 handshake 后可请求；
- ABORT 只有 reset 路径可请求，且 `response_handshake_done==0`；
- NORMAL response：write 的 resp 有效、rdata='x；read 的 resp/rdata 都有效；
- ABORT response：`transaction_aborted=1`、`resp='x`、`rdata='x`；未完成的 cycle 字段必须靠 done flag 判无效，不伪造 handshake；
- winner clone `req_clone`、写入结果、`set_id_info(req_clone)`，并把一个 terminal packet 放入 terminal response FIFO；
- publisher 调用 `put_response` 后设置 response_sent/completed，再仅一次返还 credit、更新计数并 retire context。

这样即使 AW worker、W worker、B collector 与 reset 同时醒来，也只有一个 terminal winner。

## 6. Dispatcher 与精确 item_done() 契约

### 6.1 正常 dispatch 顺序

Dispatcher 是唯一 UVM request-side owner。每个 item 的正常路径必须严格执行：

1. `get_next_item(req)`；clone；`set_id_info(req)`；建立 epoch E 的 context，初态 `FETCHED_WAIT_CREDIT`。
2. 根据 access 以 reset-aware 方式尝试取得一个 write 或 read credit。真正成功后才设 `credit_owned=1`；等待期间 reset 仍可 abort。
3. 以原子 counter/lock 方式预留相关 channel queue slots：
   - write 必须同时预留一个 AW slot 和一个 W slot；
   - read 必须预留一个 AR slot。
4. 取得 `lifecycle_lock`，再次验证 `!reset_active && ctx.reset_epoch==current_epoch`。
5. 在同一临界区内完成：
   - context registry 注册；
   - write：向 AW FIFO、W FIFO、write_order_q 各追加同一 ctx handle；
   - read：向 AR FIFO、read_order_q 追加同一 ctx handle；
   - 设置 queue membership 与 `dispatch_committed=1`。
6. 仅在上述结构对 worker 原子可见后调用一次 `seq_item_port.item_done()`，设置 `item_done_sent=1`，再释放 lock。

“原子安全入队”不要求 AW/W 两个 mailbox 有神奇的多对象原子 put；实现应使用受同一 lock 保护的 bounded queues 和显式 free-slot counters。worker 只有取得同一 lock 后才能 pop，因此永远看不到“AW 已入队、W 尚未入队”的半提交状态。

### 6.2 item_done() 的准确含义

v4 的 `item_done()` 只表示：

- direction credit 已成功预留；
- request clone/context 已完全由 Driver 接管；
- context 已注册；
- write 的 AW+W 队列，或 read 的 AR 队列，已经原子、安全入队；
- 原 sequence 可以继续产生下一个 item。

它明确不表示：

- AW/W/AR 已经开始驱动；
- 任何物理 handshake 已发生；
- write 已形成完整 request；
- BRESP/RRESP/RDATA 有效；
- transaction 已退休。

这与 v3 pipelined mode 的 item_done 时点不同：v3 等到 AW+W 或 AR 物理接受后才 item_done；v4 为了跨事务 channel pipeline，必须在安全入 channel queues 后就释放 sequencer。

### 6.3 reset 打断 intake

若 reset 在 get_next_item 之后、dispatch commit 之前发生：

1. Reset Coordinator 设置 cancel_requested；不调用 item_done。
2. Dispatcher 检测 epoch/reset，只回滚尚未 commit 的 queue slot；若已取得 credit，继续由该 context 持有到 abort response 发布完成。
3. Dispatcher 在 lifecycle_lock 内调用一次 `item_done()` 并置 `item_done_sent=1`。
4. 同一 context 通过 `terminalize_once(ABORT)` 生成一个 synthetic response。
5. Response Publisher 最终 `put_response` 一次；若 `credit_owned=1`，此时再唯一一次返还 token；未取得 credit 则不返还。

统一规则是：一旦 `credit_owned=1`，即使尚未 commit，也不在 Dispatcher 直接返还；仍由 terminal publisher 在 abort response 发布后返还。只有“slot 预留”在 commit 前由 Dispatcher 回滚。这样所有 credit 都遵守同一终点。

若 reset 在 commit/item_done 临界区竞争，`lifecycle_lock` 决定唯一结果：

- reset 先赢：不 commit，走 intake-abort；
- dispatcher 先赢：完整 commit 并 item_done，随后由 reset sweep abort；
- 不允许 queues 已可见但 item_done 尚可被遗漏。item_done 调用与 `item_done_sent` 更新都位于 commit 临界区。

## 7. Channel 调度与 response association

### 7.1 WRITE：AW/W 独立但各自 FIFO

对 dispatch 顺序 A、B、C：

```text
AW FIFO: A -> B -> C       AW worker: AW_A, AW_B, AW_C
 W FIFO: A -> B -> C        W worker:  W_A,  W_B,  W_C
```

两个 worker 可并行，所以合法时序包括：

```text
AW_A handshake
AW_B handshake
... W_A handshake
W_B handshake
```

这里 AW_B 在 W_A 前完成是 v4 必须覆盖的能力。W worker 仍按 A、B、C 串行消费，所以 W_B 绝不能越过 W_A；AW worker 同理不能让 AW_B 越过 AW_A。另一个同样合法的场景是 W_A、W_B 均领先 AW_A，只要各 channel 自身保持 FIFO。

### 7.2 pending B 队列不能按线程完成时间建立

错误方案是“最后完成 AW/W 的那个 worker 直接 push context 到 pending B mailbox”。例如 A 的 W worker 和 B 的 AW worker 同一时刻结束，SystemVerilog 线程调度可能先 push B，造成错误关联。

正确方案：

1. Dispatcher 在 commit 时按 A、B、C 把 context 放入 `write_order_q`。
2. AW/W worker 只设置自己 context 的 done flag，然后在 lifecycle_lock 内调用 `promote_write_heads()`。
3. helper 只检查 `write_order_q.front()`：
   - 若 front 的 aw_done && w_done，则 pop front，计算 accept_cycle，push 到 pending B FIFO；
   - 继续检查新的 front；
   - 若最老项尚不完整，立即停止，即使后续项的两个 flag 已经都完成也不越过。
4. B collector 只消费 pending B FIFO 的头。

因此 response 关联由 dispatch/channel order 建立，而不是由线程完成时间建立。

协议约束上，合法 slave 不能为一个尚未完成 AW+W 的写请求返回 B。若观察到 BVALID 而 pending B 没有 eligible head，Driver 保持 BREADY=0，并报告协议错误；绝不能把该 B 猜给一个 W 尚未完成的 context。由于 AW、W 各自都按 A/B/C，合法情况下 A 总是最早具备完整配对资格，B response 也只能对应最早 eligible 的 A。

`bready_delay` 属于 pending B 头 context。延迟期间 BREADY 保持低，后续 B context 不得越过。

### 7.3 READ：AR 与 R 独立有序

- Dispatcher 按读 dispatch 顺序放入 AR FIFO 和 read_order_q。
- AR worker 按 FIFO handshake，标记 ar_done/accept_cycle。
- `promote_read_heads()` 只把 read_order_q 的连续已 ar_done 头项送入 pending R FIFO。
- R collector 只处理 pending R 头，按该 context 的 rready_delay 驱动 RREADY，handshake 后记录 RRESP/RDATA 并 normal terminal。
- RVALID 出现在没有 eligible read head 时，保持 RREADY=0 并报协议错误。

B collector 与 R collector 完全独立。某个 read 可以在较早 dispatch 的 write 之前完成，反之亦然；UVM response 跨方向交错时必须靠 ID 匹配。

## 8. Bounded credits、queue capacity 与计数语义

### 8.1 两类边界不能混为一谈

- **Direction credit**：限制 Driver 已接管但尚未完成 terminal response 的 write/read context 数。分别为 `max_write_outstanding`、`max_read_outstanding`。
- **Channel queue capacity**：限制尚待对应 worker 消费的 AW/W/AR entry 数。建议参数为 `aw_queue_capacity`、`w_queue_capacity`、`ar_queue_capacity`。
- **pending response queue capacity**：不需要另配比 direction credit 更大的空间；其上限天然不超过相应 credit 数，但实现仍应使用 bounded queue/counter。
- **DUT accept depth**：只能由 monitor 观察“已完成 AW+W 或 AR、但 B/R 尚未完成”的总线事实得到，不能从 Driver 参数推断。

v4.0-A 首版建议：

```text
aw_queue_capacity >= max_write_outstanding
w_queue_capacity  >= max_write_outstanding
ar_queue_capacity >= max_read_outstanding
default: 三个 queue capacity 分别等于对应 direction credit
```

这一约束使“取得 credit”意味着必有足够的最终 channel storage，减少额外阻塞状态。为了验证 slot 逻辑仍应保留独立 counters；未来若允许 queue capacity 小于 credit，必须新增专门的 deadlock/reset 测试后再放宽。

write 的 AW/W slot 必须在同一个 lock 中同时检查并同时递减，不能先拿 AW slot 后长期等 W slot。read 只需原子取得一个 AR slot。

### 8.2 credit 生命周期

Dispatcher 取得 sequence item 后可处于 `FETCHED_WAIT_CREDIT`；此时 request 已被 pull port 持有，但还没有 credit_owned。真正 `try_get` 成功的时刻才是 credit reservation 点。从这一刻到最终正常或 abort response 通过 `put_response` 发布完成，credit 始终归该 context，最多归还一次。

推荐不变量：

```text
write_reserved =
    count(ctx.access==WRITE && ctx.credit_owned && !ctx.credit_released)

read_reserved =
    count(ctx.access==READ  && ctx.credit_owned && !ctx.credit_released)

write_credit_balance + write_reserved == max_write_outstanding
read_credit_balance  + read_reserved  == max_read_outstanding
```

credit 覆盖如下所有阶段：

- reserved、尚未安全入队；
- 已在 channel queues；
- AW-only 或 W-only partial handshake；
- AW+W complete accepted；
- AR complete accepted；
- pending B/R；
- B/R 已 handshake、但 UVM terminal response 尚未 put_response；
- reset abort 已决定、但 abort response 尚未 put_response。

只有 Response Publisher 完成 `put_response` 后，才在同一原子路径执行 `credit_released=1` 和 token return。对于从未成功取得 credit 的 credit-wait abort，publisher 发布 response 但不归还 token。

### 8.3 max_write_outstanding=3 的强制示例

假设 A/B/C 都已 dispatch，三个 write credits 都由 context 持有：

```text
AW_A = done, AW_B = done, AW_C = done
W_A  = not done
W_B/W_C 因 W FIFO 顺序尚未越过 A
write_reserved       = 3
write_credit_balance = 0
partial requests     = 至少 A（可能有多个 AW-only）
complete accepted    = 0
pending B            = 0
```

这时不能说“DUT 有 3 个 complete outstanding”。事实是 Driver 的 3 个 credits 已全部占用、AW channel 已接受 3 个地址、但还没有完整写请求，因为最老 W_A 未接受。第四个 write 在 Dispatcher 的 credit wait 中；reset 必须令它 item_done 一次、abort response 一次，且因为它未取得 credit，不能错误 put 一个 token。

另一种状态：

```text
AW_A/B/C done, W_A/B/C done, no B handshake
write_reserved       = 3
complete accepted    = 3
responses pending    = 3
write_credit_balance = 0
```

只有这种观测才可能说明 slave 接受了 3 个完整写请求。是否当前 GPIO DUT 真能到达该状态必须由 monitor 实测，不能由配置推断。

### 8.4 必须分开的诊断计数

建议 Driver 暴露只读统计/日志，而非让测试窥探 semaphore 内部：

- `write/read_credit_balance`；
- `write/read_reserved_contexts`；
- `aw/w/ar_queue_entries`；
- `write_aw_only`、`write_w_only`、`write_both_accepted`；
- `read_ar_accepted`；
- `pending_b/r`；
- `b/r_handshake_not_published`；
- `normal_completed`、`aborted_completed`；
- `epoch` 和各 worker stale-drop count。

这些计数的和式应由 assertion/check helper 每周期或关键事件后核对。

## 9. Reset epoch 与并发方案

### 9.1 epoch 生命周期

`current_epoch` 初始为 0。检测到 `ARESETN !== 1'b1` 时，Reset Coordinator：

1. 在 lifecycle_lock 内设置 `reset_active=1` 并把 `current_epoch` 加一；先切断所有新 commit。
2. 对 Dispatcher 当前未 commit context 设置 cancel_requested。
3. 原子 drain AW/W/AR queues 和 write/read order queues、pending B/R queues；slot ownership 按 queue/inflight flag 只返还一次。
4. 对所有旧 epoch、`response_handshake_done==0` 且 terminal_kind==NONE 的 context，按各方向 dispatch 顺序请求 ABORT terminal。
5. 唤醒所有 pin owner；每个 owner 立即撤销自己的 VALID/READY、清零非握手 payload 输出，并对当前 in-flight entry 回报 reset ack。
6. 等待 Dispatcher、AW、W、AR、B、R 六类 owner 都到达 reset barrier，确认没有旧 epoch pin drive。
7. reset release 被稳定采样后，清 `reset_active`，允许新 epoch intake/drive。

Reset Coordinator 不直接驱动 master pins，避免与 worker 多重赋值。每个 worker 只负责自己 channel 的安全 idle：

- AW worker：AWVALID=0，AWADDR/AWPROT=0；
- W worker：WVALID=0，WDATA/WSTRB=0；
- AR worker：ARVALID=0，ARADDR/ARPROT=0；
- B collector：BREADY=0；
- R collector：RREADY=0。

### 9.2 各状态的 reset 结果

| reset 时状态 | item_done | terminal response | credit |
|---|---|---|---|
| get_next_item 尚未返回 | 无 item，无动作 | 无 | 无 |
| 已 fetch、credit-wait | Dispatcher 恰好一次 | ABORT 恰好一次 | 未取得则不返还 |
| 已取得 credit、尚未 commit | Dispatcher 恰好一次 | ABORT 恰好一次 | response 发布后返还一次 |
| AW/W/AR queue 中 | 已完成 | ABORT 恰好一次 | 发布后返还一次 |
| AW-only 或 W-only | 已完成 | ABORT 恰好一次 | 发布后返还一次 |
| AW+W/AR 已接受、等 B/R | 已完成 | ABORT 恰好一次 | 发布后返还一次 |
| B/R 已 handshake、尚未 put_response | 已完成 | 保留 NORMAL，不得改 abort | normal 发布后返还一次 |
| response 已 put_response | 已完成 | 不再产生 | 已返还，不再动 |

“已 handshake”只以同一 `drv_cb` 采样到 `ARESETN===1` 且 VALID&&READY 为准。若 reset 采样为低，则该边沿不记为有效 B/R 完成，走 abort。

### 9.3 防旧 epoch 穿透

每个 queue entry 和 in-flight handle 都带 ctx.reset_epoch。worker 在以下位置检查：

- 从 queue pop 后、第一次驱动前；
- 每个 delay clock；
- VALID/READY wait 的每个 clock；
- handshake 后写共享状态前。

若 epoch 不匹配或 reset_active：

- 不再驱动/立即撤销本 channel 输出；
- 不设置新的 done flag；
- 不自行 terminalize，也不自行 release credit；
- 仅通过同步 cleanup 交回 in-flight/slot ownership并 ack barrier。

新 epoch 只有在旧 worker 全部 barrier ack 后才开放。因此旧 reset 前的 delayed task 不可能在 reset release 后继续抬高 VALID/READY。

### 9.4 reset 与 item_done/terminal 的竞态

- commit 与 reset epoch change 使用同一 lifecycle_lock，消除“半入队”。
- worker handshake flag 与 reset sweep 使用同一 lock，消除“normal 与 abort 双赢”。
- item_done 只有 Dispatcher 能调用；reset 只发 cancel。
- terminal_kind CAS 只有一个 winner；publisher 只有一个。
- credit release 与 credit_released flag 在同一临界区。
- pending queue drain 与 worker pop 用 queue membership/inflight 二选一 ownership，不重复返还 slot。

### 9.5 四态 invalid data 约定

保持现有 sequence item 契约：

- ABORT：`transaction_aborted=1`，`resp='x`，`rdata='x`；消费者不得比较 BRESP/RRESP/RDATA。
- 正常 write：`transaction_aborted=0`，`resp` 有效，`rdata='x`。
- 正常 read：`transaction_aborted=0`，`resp` 和 `rdata` 有效。
- 未完成 AW/W/AR 的 cycle 字段不得伪造；done flag 是有效性判据。若保留数值 0，仅表示未记录，不表示 cycle 0 handshake。
- Driver 输出在 reset 时用确定的 0 + VALID/READY=0，不用 X 驱动总线；X 只用于 synthetic UVM response 的无效字段。

## 10. 验证计划

本节是实现后的计划，不表示本轮已执行或通过。恢复 VCS license 后，先跑未改动的 v3 baseline，再逐步打开 v4 mode。

### 10.1 Driver 组件级定向测试

建议新增相互独立、失败定位单一的 sequence/test：

1. **AW_A、AW_B before W_A**
   - A 的 W delay 很长，B/C 的 AW 可继续；
   - 强制观测 `AW_B handshake_cycle < W_A handshake_cycle`；
   - 同时证明 W_B 没有越过 W_A；
   - B 返回仍为 A、B、C。
2. **多个 W 领先 AW**
   - A 的 AW delay 很长；
   - 观测 W_A、W_B 均在 AW_A 前完成；
   - AW、W 各自 FIFO，不发生 payload 交叉配对。
3. **AW-only reset**
   - AW_A 已 handshake、W_A 未 handshake；
   - A 仅一个 abort response，credit/slots 全恢复；旧 W_A 不穿到新 epoch。
4. **W-only reset**
   - W_A 已 handshake、AW_A 未 handshake；
   - 对称检查 exactly-once abort。
5. **credit-wait reset**
   - credit 已耗尽，Driver 已取得下一 item；
   - item_done 一次、abort response 一次、未持有 credit 时不多返 token。
6. **queue depth boundary**
   - 分别填满 AW/W/AR queues；
   - no overflow、no unbounded mailbox；边界释放后继续前进。
7. **B stall / R stall / simultaneous stall**
   - BREADY/RREADY 长时间低；
   - channel request workers 仍在 credit 允许范围内独立推进；
   - pending FIFO、credit 计数保持一致。
8. **mixed read/write traffic**
   - B/R collector 同时活跃；
   - 只检查 per-direction order；跨方向 response 用 ID 关联，不做全局排序。
9. **response association**
   - 每项使用唯一 transaction_id 和不同 payload；
   - monitor 的 AW/W pairing、B/R FIFO、UVM response 三层一致；
   - duplicate、missing、unknown ID 都是错误。
10. **B/R handshake 与 reset boundary**
    - handshake 完成后立即 reset；
    - 已完成者必须 normal，不可 false abort；其他旧 epoch context 全 abort。
11. **compare reset recovery**
    - 每个 reset 场景后立刻执行新 epoch write/read；
    - 无 stale pin drive、无旧 response、credit/queue/registry 全 drain。
12. **invalid-data contract**
    - abort response 严格检查 resp/rdata 为 X；
    - normal response 检查对应有效字段；消费者不误用 write rdata。

测试不能只读 Driver 内部计数。每个关键结论必须同时由独立 monitor 的实际 handshake cycle 支持。

### 10.2 深度矩阵

- 当前 GPIO DUT 集成回归：以实测 complete outstanding 最大 2 为事实，depth=2 是主证明点；配置 3 仅做“Driver 不越界/会 backpressure”的检查。
- 通用 BFM 组件回归：增加可配置 AXI4-Lite slave，request depth 设为 3、4、8；可独立控制 AWREADY/WREADY/ARREADY、B/R latency 与 response stall。
- 每个深度覆盖：
  - AW 领先 W；
  - W 领先 AW；
  - AR 连续接受；
  - B/R 长 stall；
  - reset 位于 reserved/partial/accepted/pending/handshake boundary；
  - 最终 registry empty、queue empty、credit full。

建议把 deep slave 放在独立 testbench/agent 下，避免把 GPIO RTL 的功能行为混入 BFM 容量证明。

### 10.3 回归门槛

1. v3 legacy、limited_overlap、pipelined 的既有 tests 先恢复全绿。
2. v4 每个定向 test 单独稳定通过多个 seed。
3. v4 random 只在所有定向不变量已有 assertion 后加入。
4. 当前 DUT 报告与 deep test slave 报告分开。
5. reset regression 必须报告 request count、item_done count、terminal response count、normal/abort count、credit balance 和 stale-drop count。
6. 不以测试超时、队列非空或 license error 当作功能结果。

## 11. Scoreboard/Reference Model 后续独立重构

当前 `axi4l_gpio_scoreboard.sv` 在 AXI request monitor 发布“外部完整接受”事件时：

- 立即构造期望 B；
- 在 accept_cycle 对写 side effect 更新 model；
- 在 AR accept_cycle 对 read value 做 snapshot；
- 用 `model_gpio/model_q/model_qq/model_last/model_changed/model_mask/model_int` 复制了较多 DUT 内部状态和时序。

这在当前受限 pipeline 下可工作，但 channel-level pipeline + skid buffer 会暴露核心歧义：外部 AW+W 接受不一定等于内部寄存器 commit；AR 接受不一定等于 DUT 真正 capture read snapshot。继续在外部 acceptance 点更新寄存器 golden 会把 DUT buffer latency 错当成协议语义。

后续独立阶段应分层：

### 11.1 黑盒协议层

只依赖 AXI pins：

- 重建 AW/W request pairing；
- 检查 B/R 不能无 request；
- 检查 per-direction FIFO response order；
- 检查 response code、稳定性与 reset 清空；
- 统计实际 accept depth；
- 不猜测 DUT 内部 commit cycle。

### 11.2 架构功能层

不要逐拍复制 DUT 全部内部寄存器作为唯一 golden。可选方案：

- 对只要求最终值的黑盒测试，在 drain/observable boundary 后比较 GPIO/readback，避免猜 buffer commit；
- 用面向 spec 的操作级 reference model，只在已知 commit event 上更新；
- 将输入同步器、interrupt pipeline 的逐拍时序检查与 AXI request/response 模型拆开；
- 对 read snapshot 无法从黑盒唯一判断的场景，限制测试刺激或使用下述可选 commit monitor。

### 11.3 可选 white-box commit monitor

可 bind 一个只读 monitor 到 DUT 内部“write commit/read capture”脉冲及必要 payload，向 scoreboard 发布 commit event。边界必须明确：

- white-box event 只解决当前 DUT 内部 commit/snapshot 时点；
- 不参与 AXI protocol checker，不替 Driver response association；
- 通用 BFM/deep slave 测试不得依赖 GPIO DUT white-box 信号；
- 同一功能仍需保留独立黑盒 end-to-end tests，防止 scoreboard 与 RTL 复制同一错误；
- white-box monitor 的信号范围、稳定接口和对 RTL 层级名的依赖要单独评审。

Scoreboard 重构不与 v4 Driver 第一版混在同一提交中；先让 channel engine 在组件级 slave 上证明，再迁移 GPIO scoreboard。

## 12. 小步实施路线与文件计划

以下是未来实施顺序；本轮没有执行这些源码改动。

### Step 0：恢复工具与冻结 baseline

- 恢复 VCS license。
- 运行并记录所有现有 directed/random tests，尤其 v3 pipeline/reset/stress。
- 保存 seed、日志、coverage 和当前 DUT 实测 depth=2 证据。
- 若 baseline 不绿，先修环境，不开始 v4。

### Step 1：只加内部 context 与不变量单元测试

- 新增 `tb/axi_agent/axi4l_v4_context.sv`：字段、状态、clone/response builder，不驱动 pin。
- 新增 `tb/tests/directed/axi4l_v4_context_unit_test.sv`：terminal CAS、credit release guard、四态 abort response。
- 更新 `axi4l_agent_pkg.sv` include；不改变默认 mode。
- 回归全部 v3。

### Step 2：加入 bounded dispatcher 与空 worker 骨架

- 重构 `tb/axi_agent/axi4l_driver.sv`：新增 `channel_pipelined_mode`，与 limited/pipelined 互斥；legacy 默认不变。
- 新增受锁 queue/counter、registry、epoch、统计 helper。
- 先用无 stall 单事务 smoke 验证 item_done/put_response 契约。
- 回归全部 v3。

### Step 3：AW/W/AR channel workers

- 在 Driver 内实现唯一 pin owner tasks；或新增 `tb/axi_agent/axi4l_v4_channel_engine.sv` 封装纯内部 helper，由现有 driver type 持有。
- 先测 AW_A/AW_B before W_A 和多个 W 领先 AW。
- 用独立 monitor cycle 证明跨事务 channel 行为。
- 回归全部 v3。

### Step 4：ordered B/R eligibility 与 collectors

- 实现 write_order/read_order、promote-oldest-eligible、pending B/R。
- 加 response association、B/R stall、mixed traffic tests。
- 加 “B/R without eligible head” protocol error test（由专用 bad slave 驱动）。
- 回归全部 v3。

### Step 5：reset epoch/abort

- 实现 Reset Coordinator、worker barrier、stale cleanup、single publisher。
- 加 AW-only、W-only、AR accepted、B/R pending、credit-wait、handshake boundary、recovery tests。
- 对每个场景审计 exactly-once item_done/response/credit。
- 回归全部 v3。

### Step 6：深度 slave 与 3/4/8 capacity proof

建议新增：

- `tb/axi_slave_agent/axi4l_test_slave.sv`；
- `tb/axi_slave_agent/axi4l_test_slave_cfg.sv`；
- `tb/tests/directed/axi4l_v4_depth_test.sv`；
- `tb/tests/random/axi4l_v4_channel_random_test.sv`。

把 slave-only filelist/testbench 与 GPIO 集成入口分开，避免误报 GPIO DUT 深度。

### Step 7：Monitor/Scoreboard 独立阶段

- `axi4l_monitor.sv` 初期保留；先用现有 AW/W FIFO pairing 检查 Driver。
- 后续仅在有明确需求时扩展 epoch/X/protocol event，不让 monitor 读取 Driver 内部状态。
- 单独重构 `axi4l_gpio_scoreboard.sv`，拆协议接受、commit 与架构功能。
- 若批准 white-box，新增独立 commit monitor/bind 文件；保留黑盒回归。

### 12.1 文件处置总表

| 文件/目录 | 未来处置 |
|---|---|
| `dut/rtl/*`、`original/zipcpu/*` | 保留，不为适配 Driver 改 RTL |
| `axi4l_if.sv` | 首版保留；现有 clocking block 足够 |
| `axi4l_seq_item.sv` | 对外字段/四态 abort 契约保留；v4 内部状态放 context，不污染 item |
| `axi4l_sequencer.sv`、`axi4l_agent.sv` | 保留 API；agent 仍连接同一 driver/sequencer |
| `axi4l_agent_pkg.sv` | 仅在实现阶段加入新内部 class include |
| `axi4l_driver.sv` | 实现阶段小步重构，保留三种旧模式并新增 v4 mode |
| `axi4l_monitor.sv` | Driver 阶段先保留；Scoreboard 阶段再独立评估 |
| `axi4l_gpio_scoreboard.sv` | 后续独立重构，不与 v4 Driver 首版混改 |
| `tb/sequences/axi4l_v3_*`、`tb/tests/directed/axi4l_v3_*` | 原样保留为回归 |
| `sim/Makefile`、`sim/filelist.f` | 本轮不改；实现阶段只做新增文件编译入口的最小更新 |
| 新增 context/channel/deep-slave/v4 tests | 按上述 Step 分提交、分回归 |
| `docs/v4_driver_architecture.md` | 本文，v4.0-A 评审基准 |

## 13. 待用户评审的决策项

1. **模式 API**：首版推荐新增 `channel_pipelined_mode` bit 并保持三个旧模式；是否现在就改成 enum mode，还是等兼容期后再统一？
2. **queue capacity 规则**：首版推荐强制 AW/W capacity >= write credits、AR capacity >= read credits，默认相等；是否需要第一版就支持“小 queue、大 credit”？
3. **response 发布**：本文推荐 single Response Publisher，B/R/reset 只 enqueue terminal packet；是否接受这一层串行化？
4. **sequencer 方向间 HOL**：本文接受“已 fetch 的 write 等 credit 会挡住后续 read”；是否有必须消除此现象的用例？若有，需要另设计 intake API。
5. **深度证明范围**：是否批准新增独立 configurable slave，并以 3/4/8 为通用 BFM sign-off matrix？
6. **Scoreboard white-box 边界**：是否允许只读 commit/read-capture monitor；若允许，哪些内部信号可视为稳定验证接口？
7. **统计接口**：测试应只通过只读 snapshot/getter 访问统计，还是允许直接读取 Driver public counters？推荐 getter，避免测试耦合内部表示。

## 14. v4.0-A 架构轮次的历史记录

> 本节只记录上一轮 v4.0-A 文档阶段，已由第 15 节的 v4.0-B 实现状态接续；
> 其中“本轮”均指 v4.0-A，不是当前实现轮次。

本轮只允许：

- 新增 `docs/v4_driver_architecture.md`；
- 在 `docs/v4_architecture_plan.md` 增加本文索引。

本轮明确没有：

- 修改 Driver、RTL、Monitor、Scoreboard、SVA、sequence、test、interface、package 或 Makefile；
- 初始化 Git 仓库或 push GitHub；
- 运行仿真；
- 声称任何 v4 功能或测试通过。

由于 `/home/ray/AXI4_Lite_New` 当前不是 Git repository，不能用 git diff 作为证据。执行前已对 `dut/ tb/ sim/ original/ scripts/` 全部文件记录 SHA-256；文档写入后应再次计算并逐项比较，必须完全一致。旧工程只做读取与 `diff -q` 比较，不写入。

## 15. v4.0-B 第一批 lifecycle 基础设施（历史阶段）

本节覆盖 `tb/axi_agent/axi4l_v4_lifecycle_pkg.sv` 与
`tb/tests/directed/axi4l_v4_lifecycle_unit_test.sv`。它们不驱动 AXI pin，
不改变 `axi4l_driver.sv` 的 legacy、limited-overlap 或 v3 pipelined 行为。

### 15.1 实际 API

- `axi4l_txn_context`：一次性冻结 `axi4l_seq_item` 的安全 clone，并显式
  `set_id_info(req)`；私有不可变字段包括 UVM sequence/transaction ID、access、
  request/order ID、epoch、payload 与五类 delay。AW/W/AR flags、terminal、response
  snapshot、response_sent、credit ownership 等为可变状态，只由 lifecycle service
  的同步 helper 更新。这里的 ID 仅服务 UVM 关联和内部诊断，绝不是 AXI4-Lite
  协议 ID。
- `axi4l_v4_lifecycle_service.create_context/acquire_credit`：注册 active context，
  分别管理 bounded read/write credit；credit wait 使用 reset wakeup，而不是跨 epoch
  阻塞的 `semaphore.get()`。
- `mark_dispatch_committed/claim_item_done`：Dispatcher 是 `item_done()` 的唯一 owner；
  Reset Coordinator 只置 `cancel_requested`。未 commit 的 context 也保留在 registry，
  可在 reset 后发布一次 abort response。
- `worker_entry_valid/mark_channel_handshake`：每次驱动/采样均校验 context epoch、
  current epoch、reset_active 和 terminal；旧 epoch entry 只能被清理，不能产生新握手。
- `record_response_handshake/record_normal_completion/claim_terminal`：统一
  `m_lifecycle_lock` 内完成 response snapshot 与 ACTIVE->NORMAL/ABORTED 单向仲裁。
  单纯在锁外读 flag 再写 terminal 不属于合法调用方式。
- `begin_reset_and_abort/end_reset`：epoch 先递增、切断新 worker，再按方向 order
  扫描 active registry；已记录 B/R handshake 的 context 不转 abort，其余旧 epoch
  context 只 enqueue 一次 synthetic abort。
- `axi4l_v4_response_sink/publish_next`：Publisher 的隔离 adapter。接入 Driver 后，
  sink 的实现只负责调用 `seq_item_port.put_response()`。固定顺序是
  `item_done -> put_response -> response_sent -> credit return -> registry retire`；
  reset 可以先决定 terminal，但 Publisher 会等待 Dispatcher 的一次性 item_done
  标记。publisher lock 保证物理发布串行，terminal queue 保证每个 context 最多一项。
- `release_credit_once/check_invariants/get_snapshot`：针对性验证 guard 与只读统计；
  分别检查 read/write 的 `available + owned == max`。reset 绝不重建满额 semaphore。

### 15.2 reset 采样边界

Collector 只在同一个 `drv_cb` 采样点看到 `ARESETN === 1'b1` 且
`VALID && READY` 时调用 response handshake API，并传入该 context 的 expected epoch。
若 reset 在该采样点为 0/X，该边沿不是有效 B/R handshake，走 ABORT；若已经在有效
采样点记录 handshake，随后 reset 即使先于 publication 到达，也必须保留 NORMAL。
下一批接入时不得把“采样 flag”和“terminal 写入”拆到无锁代码中。

### 15.3 本批测试与运行

专用 test 覆盖：正常交付/一次释放、重复 NORMAL、NORMAL/ABORT 并发竞争、B/R
已握手后 reset 仍 NORMAL、未完成 reset 后 ABORT、max=2 credit 等待者、double
release guard、credit-wait reset 不产生 phantom token、epoch/stale worker、read/write
credit 独立性、UVM response ID 保留。

```sh
cd /home/ray/AXI4_Lite_New/sim
make -n v4_lifecycle_unit
make v4_lifecycle_unit
```

本节曾经未接入的 Channel Worker、bounded channel queues、Dispatcher、B/R
Collector、Driver response sink 与 reset barrier，现已由第 16 节的 B2 集成交付接续。
Monitor、GPIO Scoreboard、DUT 与既有 SVA 仍未为适配 v4 而重写。

## 16. v4.0-B2.1～B2.3 集成交付（2026-10-30）

### 16.1 实际结构与配置

- `axi4l_driver.v4_mode=1` 显式选择 v4；它与 legacy、`limited_overlap_mode`、
  `pipelined_mode` 互斥。三个旧模式的任务与选择语义保留。
- `axi4l_agent_types_pkg.sv` 承载公共宽度、access enum 和 sequence item，解除
  lifecycle package 与 agent package 的循环依赖；agent package 对历史公共名字做
  alias，旧 sequence/test 不需要改调用方式。
- Dispatcher 是 `get_next_item()/item_done()` 的唯一 owner。每个请求只取得一个
  direction credit；write 的同一 context 原子进入 AW、W 和 write-order 三个有界
  队列，read 原子进入 AR 和 read-order 队列。只有 context 已注册且队列提交完整后
  才调用 `item_done()`。
- AW、W、AR 各只有一个 worker 和一个 pin writer。worker 独立消费本 channel FIFO，
  VALID/payload 保持到 clocking-block 采样的 handshake；每次驱动前及 handshake
  边界都通过 lifecycle API 校验 epoch/context。
- B、R collector 按 Dispatcher 的方向顺序调用 `find_response_candidate()`，不按
  worker 完成先后配对。B 仅接受最老且 AW/W 均完成的 write，R 仅接受最老且 AR
  已完成的 read。AXI4-Lite 没有总线 transaction ID；保存的 sequence/transaction
  ID 只用于 UVM response 路由和诊断。
- collector 只记录原始 BRESP/RRESP/RDATA 与 cycle，并通过同一个 atomic terminal
  gate 竞争 NORMAL/ABORT。只有单一 Publisher 调用
  `seq_item_port.put_response()`，随后一次性返还 credit 并从 registry retire。
- Reset Coordinator 使用 epoch 和五个 owner（AW/W/AR/B/R）的 quiescence barrier。
  reset 先禁止旧 epoch 再 drain channel queue；不会重建满额 semaphore，也不会与旧
  worker 的 put 叠加。有效 response 边界定义为同一 `drv_cb` 采样到
  `ARESETN===1'b1 && VALID && READY`；已锁定 NORMAL 的响应即使尚未发布，也不会被
  reset 覆盖成 ABORT。

配置示例：

```systemverilog
uvm_config_db#(bit)::set(this, "agent.driver", "v4_mode", 1'b1);
uvm_config_db#(int unsigned)::set(this, "agent.driver",
                                  "max_write_outstanding", 8);
uvm_config_db#(int unsigned)::set(this, "agent.driver",
                                  "max_read_outstanding", 8);
```

### 16.2 delay 合约

- `aw_delay`、`w_delay`、`ar_delay` 在对应 worker 从 FIFO 取得 context 后开始消费；
  一个 channel 的 delay/stall 不阻塞另一个 channel worker。
- `bready_delay`、`rready_delay` 属于方向内最老 eligible context；collector 在该项
  成为候选后消费，因此后续同方向 response 不可越过。
- reset/epoch 失效会中断尚未完成的 delay，旧 context 不再驱动 pin。
- clocking block 的 `#1step` 输入采样和 nonblocking 输出赋值保持原接口相位语义；
  测试以 interface 记录的实际 handshake cycle 作为证据，不依赖线程调度顺序。

### 16.3 实测时序与深度证据

受控 slave 的 depth-8 测试记录：

```text
dispatch:   Write A ---- Write B ---- Write C ---- ...
AW worker:       AW_A(...) AW_B(13) ---------------- AW_C(34)
W  worker:       --------- W_A(23) -- W_B(...) W_C(25)

证据：AW_B=13 < W_A=23；W_C=25 < AW_C=34
      actual max outstanding write=8, read=8, stalls=29
```

这证明了跨事务 AW/W channel pipeline，而不是单事务内 `fork/join`。同一测试同时
检查每个 channel 的 FIFO 次序、stall 时 VALID/payload 稳定、mixed read/write、
response ID/数据/次数；depth-3 和 depth-4 专用运行也通过。上述 3/4/8 深度来自
`axi4l_v4_test_slave.sv`，不是 GPIO DUT。GPIO DUT 的 v3 depth-3 stress 仍只实际观察到
write/read outstanding=2/2，文档不将其放大为深度 3 能力。

### 16.4 reset 与 exactly-once 证据

`axi4l_v4_reset_test` 在 depth=2 下逐一运行并在每次 reset 后做恢复事务：

1. AW-only；
2. W-only；
3. pending B；
4. pending R；
5. 两个 credit 已被占用且第三个 item 正在等待 credit；
6. B/R 已在 reset 前有效采样、NORMAL 已锁定但 Publisher 被测试钩子暂时 hold。

日志对六个场景分别报告 request/response exactly-once（场景 0/1/2/3/5 为 1/1，
credit-wait 场景为 3/3）。abort response 使用
`transaction_aborted=1, resp='x, rdata='x`；正常但尚未发布的响应跨 reset 保持
NORMAL。每次 drain 后检查 registry/queue 和 `available+owned==max`，恢复事务证明
没有 phantom token、stale entry 或死锁。

### 16.5 验证结果与复现

```sh
cd /home/ray/AXI4_Lite_New/sim
make v4_lifecycle_unit v4_channel_pipeline v4_response_order v4_depth3 v4_reset
make smoke
make regression
make v3_stress RUN_OPTS="+UVM_TESTNAME=axi4l_v3_stress_test +V3_MAX_WRITE_OUTSTANDING=3 +V3_MAX_READ_OUTSTANDING=3 +UVM_VERBOSITY=UVM_LOW"
make coverage
```

最终普通回归、v4 专用测试及七个 coverage runs 的日志均为
`UVM_WARNING/ERROR/FATAL=0/0/0`，且没有 SVA `failed at`。URG 报告为
`sim/coverage_report/`：41 个 assertion 中 39 success、0 failure、2 个 UVM 内部
assertion 无尝试；32 个 cover property 全部命中（32/32）。

关键日志：

- `sim/v4_channel_pipeline.log`：AW_B<W_A、W-before-AW、depth=8 实测；
- `sim/v4_response_order.log`：depth=4 方向内 response order；
- `sim/v4_depth3.log`：depth=3；
- `sim/v4_reset.log`：六类 reset、exactly-once 与 recovery；
- `sim/v4_lifecycle_unit.log`：terminal/credit/epoch 单元测试；
- `sim/v3_stress.log`、`sim/v3_stress_depth3.log`：旧 v3 兼容性与 GPIO DUT 深度边界。

### 16.6 已知边界

- 当前 Dispatcher 使用标准 UVM pull 接口；若已 fetch 的某方向请求等待 credit，可能
  造成 sequencer 方向间 HOL。它不影响 channel worker 并行和已接管请求的推进。
- 可配置 slave 是组件级 BFM 验证模型，不替代 GPIO DUT/Scoreboard 集成验证；GPIO
  acceptance/commit 分层仍留待下一阶段。
- coverage target 保留原七个 GPIO/v3 runs，未把 v4 组件测试并入 code coverage merge；
  因新增 test-slave/module 被编译但未在该 merge 中运行，整体 code coverage 数值会比
  旧快照低。32/32 cover-property 结论只描述当前 SVA activation，不等于正式 sign-off。
- 尚未增加故意违规的 bad-slave 测试来覆盖 “B/R without eligible head” error path；
  collector 已实现拒绝配对和协议报错，后续应补负向测试。


