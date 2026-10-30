# AXI4-Lite v4.0 架构规划与进度

> 进度：2026-10-30 已完成 v4.0-B2.1～B2.3（bounded Dispatcher、独立
> AW/W/AR workers、B/R collectors、single Publisher、epoch/reset barrier）并完成
> 集成验证。下面保留最初规划作为设计背景；真实落地细节和证据以
> [v4_driver_architecture.md](v4_driver_architecture.md) 第 16 节为准。

## 本轮边界

本目录以 `/home/ray/AXI4_Lite` 中当前可工作的 v3.2 工程为只读 baseline。v4 B2
只在新工程实现；旧工程继续只读。Driver、lifecycle package、编译入口和 v4 专用
testbench 已按授权修改/新增；Monitor、Scoreboard、Reference Model、DUT、GPIO SVA
及旧 sequence/test 的业务逻辑未重写，旧测试类名保留。

新工程暂不执行 `git init`，不继承旧工程的 Git history/remote，也不创建或推送 GitHub 仓库。后续只有在用户明确批准后，才决定独立仓库的初始化方式。

## 详细设计索引

- [v4.0-A Driver 架构设计](v4_driver_architecture.md)：channel-level pipeline、credit、response association 与 reset/abort。
- v4.0-B1 lifecycle 基础设施及单元测试见 Driver 架构文档第 15 节。
- v4.0-B2.1～B2.3 已接入现有 Driver；配置、delay/reset 合约、3/4/8 深度证据、
  测试结果和限制见第 16 节。

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
- `tb/gpio_agent/`、`tb/env/`、`tb/coverage/`、`tb/assertions/`、`tb/sequences/`、`tb/ral/`：新工程继续沿用 v3.2 内容；本阶段没有为 v4 重写这些模块。
- `tb/axi_agent/`、顶层 interface/`tb_top.sv`：保留旧模式/API，同时增加 v4 lifecycle、driver channel engine、测试 slave 选择和只读测试指标。
- `tb/tests/`：旧测试类名和语义保留，并增加 v4 directed tests。
- `sim/Makefile`、`sim/filelist.f`：沿用相对路径构建方式，最小增加 v4 编译顺序和测试入口；旧 target 未删减。
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

### 3. Monitor、Scoreboard 与 Reference Model（后续阶段）

- Monitor 独立观察各 channel handshake，再按协议规则恢复读写事务；不要依赖 Driver 的内部调度顺序。
- Scoreboard/Reference Model 明确区分：
  - 外部接口已经接受（accepted）的请求；
  - DUT 内部可能仍在 buffer 中等待执行的请求；
  - 真正产生寄存器副作用的执行时点；
  - read response 对应的 read snapshot 时点。
- 先共同确定 observation/event 数据模型，再决定 Scoreboard 与 Reference Model 的职责边界和实现形式。

### 4. SVA 与 Coverage（保留既有，负向/v4 coverage 待扩展）

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

## 后续建议顺序

1. 增加 bad-slave 负向测试，直接覆盖 B/R 没有 eligible head 的 protocol error path。
2. 将 v4 组件测试纳入独立 coverage merge，并增加更丰富 stall/reset 随机矩阵。
3. 确定 Monitor 事件、Scoreboard/Reference Model 的 acceptance/commit 分层及 read
   snapshot 语义。
4. 在不改变 GPIO 黑盒回归的前提下，再评审可选 white-box commit observation。

