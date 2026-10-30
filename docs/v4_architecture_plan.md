# AXI4-Lite v4.0 架构规划与进度

> 进度：2026-10-30 已完成 v4.0-B2.1～B2.3、C1 RTL timing analysis 以及 C2
> internal timing monitor/accepted tracker/独立 GPIO golden model/cycle-aware scoreboard，
> 并完成真实 VCS 集成回归。C3 coverage closure 尚未开始。B2 真实落地细节和证据以
> [v4_driver_architecture.md](v4_driver_architecture.md) 第 16 节为准，C1 结论见
> [v4_c1_rtl_timing_analysis.md](v4_c1_rtl_timing_analysis.md)，C2 见
> [v4_c2_timing_scoreboard.md](v4_c2_timing_scoreboard.md)。

## 本轮边界

本目录以 `/home/ray/AXI4_Lite` 中当前可工作的 v3.2 工程为只读 baseline。v4 B2
只在新工程实现；旧工程继续只读。C2 新增只读 timing adapter/tracker 并将 Scoreboard 的
prediction point 从 external acceptance 切到真实 commit/snapshot；DUT、v4 Driver、既有
SVA/test slave 未改，旧 monitor API、sequence/test 类名保留。

新工程已建立独立本地 Git checkpoint：`main` commit
`e0e4a3001f9d533cc9d24e7695480926c8182cbb`，annotated tag
`v4.0-b2-baseline`。不改写/移动该 tag，不重写历史，不创建 remote，也不 push GitHub。

## 详细设计索引

- [v4.0-A Driver 架构设计](v4_driver_architecture.md)：channel-level pipeline、credit、response association 与 reset/abort。
- v4.0-B1 lifecycle 基础设施及单元测试见 Driver 架构文档第 15 节。
- v4.0-B2.1～B2.3 已接入现有 Driver；配置、delay/reset 合约、3/4/8 深度证据、
  测试结果和限制见第 16 节。
- [v4.0-C1 RTL Timing Analysis](v4_c1_rtl_timing_analysis.md)：external acceptance、
  skid buffering、internal write commit/read snapshot、NBA/clocking-block 采样、register
  semantics、逐周期表、现有 scoreboard 缺口及 C2 推荐分层。
- [v4.0-C2 Timing Monitor and Scoreboard](v4_c2_timing_scoreboard.md)：event contract、
  epoch/FIFO tracker、independent model、fault self-test、cycle evidence 与真实回归结果。

## C1/C2 状态（2026-10-30）

- 已完成只读 RTL/Monitor/Scoreboard/clocking block/SVA/B2 pipeline test 审查，并新增
  `docs/v4_c1_rtl_timing_analysis.md`。
- 精确确认 write commit 是 `axil_write_ready`，read snapshot 是
  `axil_read_ready`；B/R backpressure 可使它们晚于 external AW/W/AR acceptance。
- 最小 white-box timing adapter 已批准并实现；只暴露 commit/snapshot event，不暴露 DUT
  internal expected data/state。
- C2 accepted tracker、cycle-aware scoreboard、fault self-test 和 directed tests 已实现并通过
  VCS；C3 coverage closure 明确保留到下一阶段。

## B2 交付摘要

| 阶段 | 已交付内容 | 验证入口 |
|---|---|---|
| B2.1 | 一个 direction credit/请求；write AW+W 原子双队列提交；active registry；安全 `item_done()`；reset-aware credit wait | `v4_lifecycle_unit`、`v4_reset` |
| B2.2 | AW/W/AR 唯一 worker、channel FIFO、VALID/payload stall stability、epoch 校验和 lifecycle handshake API | `v4_channel_pipeline`、`v4_depth3` |
| B2.3 | 方向顺序的 B/R association、atomic terminal gate、single Publisher、exactly-once credit/cleanup、reset barrier | `v4_response_order`、`v4_reset` |

专用受控 slave 已实测 outstanding depth 3、4、8；depth-8 日志证明
`AW_B=13 < W_A=23`，并达到 write/read 8/8。GPIO DUT 的 v3 depth-3 运行仍只观察到
2/2，因此二者在报告中严格分开。

## v3.2 可复用的稳定内容

- `dut/rtl/`：当前验证对象及 skid buffer RTL，原样保留。
- `original/zipcpu/`：上游参考 RTL，连同现有授权/版权声明原样保留。
- `tb/gpio_agent/`、`tb/coverage/`、`tb/assertions/`、`tb/sequences/`、`tb/ral/`：继续沿用 v3.2 行为；C2 未删除或弱化旧 checker/SVA。
- `tb/env/`：C2 新增 event/tracker，并把原 scoreboard prediction point 改为 internal commit/snapshot，class/API 与独立 GPIO model 保持兼容。
- `tb/axi_agent/`、顶层 interface/`tb_top.sv`：保留旧模式/API，同时增加 v4 lifecycle、driver channel engine、测试 slave 选择和最小只读 C2 timing adapter。
- `tb/tests/`：旧测试类名和语义保留，并增加 v4/C2 directed tests 与隔离 fault self-test。
- `sim/Makefile`、`sim/filelist.f`：沿用相对路径构建方式，增加 v4/C2 编译顺序和测试入口；旧 target 未删减。
- `docs/`、`README.md`、`.gitignore`：保留既有设计/验证背景与工程约定。

“可复用”表示它们是 v4.0 的稳定起点，不表示所有模块已经具备最终的通用并发能力。

## 已完成与后续重构边界

### 1. AXI master BFM / Driver（B2 已完成）

- 为 AW、W、AR 建立真正跨事务的独立 channel queue 与 worker，避免单个 sequence item 内的局部并发掩盖跨事务串行化。
- 明确定义有序 AW/W 配对；B、R response 分别按 FIFO 关联请求。
- 引入 bounded credits，分别限制未完成读、未完成写及必要的 channel 缓冲深度，避免无界队列与死锁。

### 2. Reset 与 abort（B2 已完成）

- 为所有 channel worker、queue、credit 和 response waiter 定义一致的 reset/abort 语义。
- 明确 reset 中已接受、已缓冲、尚未执行和等待响应的事务如何清空、标记或结束，防止跨 reset 的陈旧响应。

### 3. Monitor、Scoreboard 与 Reference Model（C2 已完成）

- Monitor 独立观察各 channel handshake，再按协议规则恢复读写事务；不要依赖 Driver 的内部调度顺序。
- Scoreboard/Reference Model 明确区分：
  - 外部接口已经接受（accepted）的请求；
  - DUT 内部可能仍在 buffer 中等待执行的请求；
  - 真正产生寄存器副作用的执行时点；
  - read response 对应的 read snapshot 时点。
- event 数据模型、Scoreboard/Reference Model 职责边界及 black-box fallback 已落地，详见 C2 文档。

### 4. SVA 与 Coverage（SVA 保留，C3 coverage 待扩展）

- 保留现有 SVA 与 coverage，不以删断言、缩小采样或放宽检查换取通过。
- 在现有基础上扩展 channel 独立 backpressure、AW/W 不同到达顺序、response ordering、bounded outstanding、reset/abort 及跨事务场景覆盖。

### 5. Tests 与参数矩阵（组件级 3/4/8 已完成，参数矩阵待扩展）

- 将 Driver/Monitor/Scoreboard/Reference Model 的单元级或组件级 tests 与 DUT 集成 tests 分开。
- 建立参数矩阵，至少覆盖 AW/W/AR/B/R stall 组合、读写交错、reset 时点、credit/depth 边界和不同随机种子。
- 回归报告必须区分“通用 BFM 能力验证”和“当前 DUT 能力范围内的验证”。

## 当前 DUT 的 outstanding 限制

当前 RTL 的 skid buffer 使“完整 outstanding transaction”的实测最大值为 **2**。因此，不能声称已经在这个 DUT 上验证了更深 pipeline，也不能把 sequence/Driver 中设置得更大的 depth 直接当作 DUT 实际接受了更深 outstanding 的证据。

通用 BFM 的深度验证已经使用可配置 `axi4l_v4_test_slave` 完成 3/4/8 runs；该结果
与当前 GPIO DUT 的集成验证分开报告。GPIO DUT 本身的 outstanding 限制结论不变。

## C3 后续建议顺序

1. 将 C2/v4 组件测试纳入独立 coverage merge，并增加更丰富 stall/reset/negative 矩阵。
2. 扩展 deliberately bad-slave、orphan/duplicate snapshot 与 response-qualification 负向测试。
3. 建立参数矩阵、RAL、machine-readable regression manifest 和 traceability/sign-off closure。

