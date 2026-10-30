# AXI4-Lite v4.0-C2 Timing Monitor and Cycle-Aware Scoreboard

> 状态：2026-10-30 已实现并完成真实 VCS 回归；C3 coverage closure 未开始。
>
> 基线：`v4.0-b2-baseline^{commit}` =
> `e0e4a3001f9d533cc9d24e7695480926c8182cbb`。C2 未修改 DUT RTL、v4 master
> Driver、既有 SVA 或 test slave。

## 1. Event contract 与采样区域

`tb_top` 中的 `axi4l_c2_timing_if` 是最小只读 white-box adapter，只连接：

- `WRITE_COMMIT = dut.axil_write_ready`
- `READ_SNAPSHOT = dut.axil_read_ready`
- reset/clock 仅用于同一采样域

adapter 不输出 `r_gpio`、`r_mask`、`toggled/changed`、`axil_read_data`、skid payload
或任何 DUT 计算结果。地址、data、WSTRB、PROT 全部来自 tracker 在外部 pin 上独立记录的
AW/W/AR handshake。

两个 event 在 `#1step` monitor clocking input 中代表即将被 DUT 在该上升沿采样的 pre-edge
条件。DUT 的 RHS 在 Active region 读取 pre-NBA 状态，寄存器在 NBA 更新。因此：

1. read snapshot 先从 pre-edge golden state 计算 expected RDATA；
2. 同沿 write、CDC、W1C 与 IRQ next-state 随后计算；
3. 最后 atomic commit golden next-state；
4. 所以同沿 read/write 是 read-old/write-new；本沿写后的 `o_gpio` 在下一编号 GPIO
   observation 中检查。

精确 RTL 条件保持为：

```systemverilog
WRITE_COMMIT  = awskd_valid && wskd_valid
              && (!S_AXI_BVALID || S_AXI_BREADY);
READ_SNAPSHOT = arskd_valid
              && (!axil_read_valid || S_AXI_RREADY);
```

`RVALID && !RREADY` 时没有新的 read snapshot，`RDATA/RRESP` 由既有 SVA 检查稳定。

## 2. Accepted-request tracker

`axi4l_c2_timing_monitor` 在一个时钟线程内完成所有 pin 采样，避免用 analysis callback 或
AW/W worker 的调度先后来建立事务关系：

- AW FIFO：`{epoch, cycle, address, PROT}`；
- W FIFO：`{epoch, cycle, data, WSTRB}`；
- AR FIFO：`{epoch, cycle, address, PROT}`；
- 最老 AW 与最老 W 配成 write request，`accept_cycle=max(AW,W)`；
- accepted write/read queues 分别按方向 FIFO 保存；
- WRITE_COMMIT/READ_SNAPSHOT 只消费当前 epoch 的队头；
- 已 commit/snapshot 的请求进入 B/R eligibility queues，response handshake 只能消费对应队头。

同一沿的处理顺序为：采外部 handshake并形成 request；先退休该沿 pre-edge 已存在的 B/R；
再处理本沿 internal event。这样同沿 external acceptance + internal execution 可被关联，同时
同沿 response replacement 不会把旧 response 错配给刚执行的新请求。

reset assertion 开启新 epoch并清空 partial AW/W、accepted、committed/snapshotted queues。
event/request epoch 不同报告 stale；没有 accepted head 的 event 报 orphan；相同
`epoch:request_id` 再出现报告 duplicate。受控 drain/end-of-test 才检查 missing，绝不使用
任意固定 accept-to-event latency，因此合法无限 B/R backpressure 不会触发假 missing。

## 3. Checker 分类

| 检查 | 失败条件 |
|---|---|
| orphan commit/snapshot | internal event 没有当前 epoch 的 accepted queue head |
| duplicate commit/snapshot | 同一 `epoch:request_id` 第二次执行 |
| missing commit/snapshot | controlled drain 时 accepted request 仍未出现 event |
| stale epoch | event 关联到 reset 前 request |
| response eligibility | B 没有 committed write，或 R 没有 snapshotted read |
| queue order | event 与 B/R 只能消费各方向 FIFO head |
| external response | 旧 AXI monitor 继续独立采 B/R，scoreboard 检查 ID、OKAY 和 RDATA |
| observable state | 每拍比较独立 model 的 `o_gpio/o_int`，并按事务检查 GPIO due-cycle |

负向 `axi4l_c2_checker_selftest` 只修改 checker event stream，不 force DUT。它分别注入
orphan、duplicate、missing、stale，并由 missing 导出 unqualified B；expected-fault 模式把
这些预期诊断记录为 INFO，测试必须检查每类计数非零，故不会把预期 UVM_ERROR 带入普通回归。

## 4. 独立 GPIO golden model

Scoreboard 不读取 DUT internal data。它自行维护：

- output register：LOAD/SET/CLEAR/TOGGLE，逐 byte `WSTRB`，`NOUT` 以上强制 0；
- `i_gpio -> q -> qq -> last` 的数字 2FF/edge-detect pipeline；
- CHANGED sticky：software W1C 后再 OR 同沿 hardware detect，故 hardware-set 胜；
- MASK：按实际 RTL 的 `1=enable`；
- `o_int`：使用上一拍 MASK/CHANGED 的 registered reduction；
- read-only/illegal writes 无软件副作用，输出别名 read、INPUT/CHANGED/MASK/INT read decode；
- reset 恢复 DEFAULT_OUTPUT、清 CDC/CHANGED/MASK/IRQ，并 flush pre-reset predictions。

Expected response 在 write commit 或 read snapshot 时产生，而不是在外部 acceptance 时产生。
Read expectation 在 snapshot 的 pre-edge model state 冻结，后续 write/CDC/backpressure 不会改变它。

## 5. White-box 与 black-box

默认是 cycle-exact white-box。若 integration 没有 `timing_vif`，monitor 自动告警并回退到
acceptance-time event；也可用 `+C2_BLACKBOX` 显式选择。black-box 仍可检查 AXI FIFO order、
response status/stability、reset、最终 drain/readback 与 observable pins，但不能区分：

- AW/W 已外部接受但仍因 B stall 留在 skid 中的 write；
- AR 已外部接受但仍因 R stall 尚未 snapshot 的 read。

因此 black-box PASS 不是精确 commit/snapshot timing sign-off，C2 默认回归以 white-box 为准。

## 6. 专项场景与真实 cycle evidence

`axi4l_c2_timing_test` 使用非零 WSTRB，使 SET/CLEAR/TOGGLE 各自真正进入 buffer 后再 commit；
并覆盖 B stall、R stall+后继 AR、intervening write、same-edge read/write、reset while buffered、
post-reset recovery。既有 W1C collision test 在新 event/model 路径下覆盖 bits 0..4。

VCS `V-2023.12-SP1` 日志 `sim/c2_timing.log` 的代表性证据：

- buffered SET：external accept cycle 15，internal commit cycle 23；三个非零副作用操作均命中
  `buffered_nonzero_side_effect_count`；
- delayed read：AR cycle 54，因 R backpressure 到 cycle 66 才 snapshot；期间 write 在 cycle 55
  commit，第二个 read 返回 write 后值；
- same-edge read/write：cycle 70，read 返回旧 `0x22`，write 后续可读为 `0x33`；
- B/R stall：26/12 个 sampled cycles；
- reset while buffered：cycle 79 进入新 epoch，恢复后 write commit cycle 85、read snapshot
  cycle 88；
- summary：accepted W/R=12/6，commit/snapshot=11/6，B/R=10/6，violations=0；reset 中被
  flush 的 accepted/commit 数量差异是预期行为。

## 7. 实际回归结果

实际使用带用户初始化的 login shell 运行 Synopsys VCS `V-2023.12-SP1`/UVM 1.2：

- `make compile`：PASS，无编译 warning/error；
- `make c2_timing`：PASS，UVM_ERROR=0，UVM_FATAL=0，无 SVA failure；
- `axi4l_c2_checker_selftest`：PASS，五类预期故障均捕获，UVM_ERROR/FATAL=0；
- `axi4l_gpio_w1c_hw_collision_test`：bits 0..4 PASS，UVM_ERROR/FATAL=0；
- `make smoke`：PASS；
- `make regression`：15 runs 全部 PASS；
- 显式 `v4_lifecycle_unit/v4_channel_pipeline/v4_response_order/v4_depth3/v4_reset`：全部 PASS；
- 显式 v3 stress depth2/depth3：均 PASS，GPIO DUT 实测 max outstanding 仍为 2/2；
- black-box smoke：PASS，但只作为降级路径健全性测试。

没有运行 C3 coverage closure，也没有重做/冒充旧七-run URG merge。旧 coverage snapshot 仍只是
历史记录，不能代表 C2 coverage closure。

## 8. C3 留项

- 将 C2/v4 component tests 纳入独立 coverage merge并建立 machine-readable manifest；
- 完整 register × WSTRB lane × AW/W gap × B/R backpressure × epoch/reset crosses；
- `NIN=0`、NIN/NOUT 边界、`OPT_SKIDBUFFER=0`、`OPT_LOWPOWER=1` 参数矩阵；
- orphan/duplicate snapshot 及 deliberately bad-slave 的更广负向协议矩阵；
- RAL、更多 seeds、coverage exclusion 审查与最终 sign-off/traceability closure。

