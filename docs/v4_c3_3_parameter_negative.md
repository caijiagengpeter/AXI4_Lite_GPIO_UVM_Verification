# AXI4-Lite v4.0 C3.3 Parameter Matrix and Negative Verification

## Evidence

最终实测目录：`sim/c3_3_parameter_negative_verified_clean/`。

- Rocky Linux 8.10；VCS/URG `V-2023.12-SP1_Full64`；UVM 1.2。
- 7/7 independent builds PASS，28/28 runs PASS，10/10 compatible URG merges PASS。
- 全部 selected runs 合计 UVM warning/error/fatal = 0/0/0，runtime SVA failure = 0。
- compile warning/error = 0/0。开发运行曾暴露 NIN=0/NOUT=32 的零宽/满宽 TB part-select
  与 physical GPIO width warning；改为参数安全的逐 bit loop/guarded width 后，完整矩阵
  重跑确认 warning 清零。
- 标准 `make regression` 另行实际执行并 exit 0；各回归日志 UVM W/E/F 均为 0/0/0。

## Parameter matrix（performed）

| Seed | NIN | NOUT | SKID | LOWPOWER | DEFAULT_OUTPUT | 实际结果 / 目的 |
|---:|---:|---:|---:|---:|---:|---|
| 31 | 5 | 30 | 1 | 0 | 0 | PASS；default gap、unaligned alias、operation change/no-change |
| 32 | 5 | 32 | 1 | 0 | 0 | PASS；full-width output，line 380 false branch |
| 33 | 1 | 1 | 1 | 0 | 0 | PASS；minimum positive input/output widths |
| 34 | 5 | 30 | 0 | 0 | 0 | PASS；SIMPLE_READS/SIMPLE_WRITES generate path |
| 35 | 5 | 30 | 1 | 1 | 0x15555555 | PASS；non-zero reset value，LOWPOWER lines/branches |
| 36 | 0 | 32 | 1 | 0 | 0 | PASS；NO_INPUTS elaboration，upper four words alias output ops，o_int=0 |

每个配置均有独立 build variant、compile signature、coverage object、VDB 和 merge group。
日志中的 `[C3_3_PARAM_CFG]` 与 `[C3_3_PARAMETER_PASS]` 证明参数实际生效，而不是只修改
manifest。NIN=0 的 RTL 使用 guarded one-bit physical input port；因为 INPUT_HANDLING 不
elaborate，该配置绑定 bus-only protocol SVA，不能冒充 NIN>0 GPIO SVA coverage。

## Controlled bad-slave selftest（performed）

独立 top `tb_bad_slave_top` 直接注入并明确检测八类错误：

1. BVALID 早于对应 AW/W；
2. RVALID 早于 AR；
3. RDATA/RRESP 在 RVALID stall 中变化；
4. BRESP 在 BVALID stall 中变化；
5. AW/W payload 在 request stall 中变化；
6. reset 后 stale response；
7. duplicate B response；
8. audit 时 missing R response。

日志包含 8 个 `[BAD_SLAVE_DETECTED]` 和一个 `[C3_3_BAD_SLAVE_PASS]`，同时 UVM W/E/F
为 0/0/0。预期 fault 由 detector 计数/mask 自检，不用 `UVM_ERROR` 污染正常回归。
BRESP=SLVERR 单独出现是 AXI4-Lite 合法响应，测试明确不把它当协议错误；AXI4-Lite
没有 transaction ID，本测试也没有虚构 ID-based checking。

## Checker and functional strengthening（performed）

- C2 selftest 分别命中 commit 和 snapshot 的 orphan/duplicate/missing，各 1 次；stale=2；
  unqualified B/R=1/1。expected faults 被检出，UVM W/E/F 仍为 0/0/0。
- W1C 对 bits 0..4 每 bit 实测：data=1/WSTRB=0 preservation、data=0/WSTRB=1 + input
  change、data=1/WSTRB=1 + same-cycle hardware set collision；五个 collision cover 均命中。
- output LOAD/SET/CLEAR/TOGGLE 增加 operation x change/no-change 与 zero-strobe 覆盖；所有
  场景通过 scoreboard/SVA，而非 sequence intent 直接采样。
- v4 reset 新增真实 depth2-both 场景。controlled slave 实际观测 max outstanding
  write/read=2/2 后才注入 reset，并验证 recovery；修正 C3.2 只有 1/1 的历史缺口。
- default 与 NIN=0 都执行地址 bits[1:0] alias；NIN=0 upper words 按真实 RTL decode 验证
  为 LOAD/SET/CLEAR/TOGGLE alias。

## Coverage result and interpretation

| Group | Runs | Line | Cond | Toggle | Branch | Functional |
|---|---:|---:|---:|---:|---:|---:|
| GPIO default | 16 | 81.47% | 69.90% | 63.69% | 76.15% | 98.73% |
| LOWPOWER=1 | 1 | 80.60% | 56.72% | 50.24% | 67.69% | 46.53% |
| NIN=0/NOUT=32 | 1 | 74.41% | 51.02% | 54.80% | 60.33% | 38.91% |
| NIN=1/NOUT=1 | 1 | 78.45% | 53.77% | 42.91% | 62.31% | 46.08% |
| NOUT=32 | 1 | 78.02% | 53.40% | 61.47% | 62.31% | 46.53% |
| SKID=0 | 1 | 79.89% | 57.63% | 56.00% | 71.26% | 49.56% |
| bad-slave detector | 1 | 93.18% | 78.38% | 70.10% | 90.00% | N/A |

单参数组只有一个 directed run，其 top-wide coverage 低于 default 是预期现象。它们的用途
是证明 alternate elaboration 合法且可被 checker 检验，不是拿不同分母冲高 Overall。

## Reproduction

    cd /home/ray/AXI4_Lite_New/sim
    make coverage_manifest_selftest
    make coverage_c3_3 C3_3_OUT=<fresh-output-name>
    make regression

runner 会拒绝已有 VDB/output tree，要求新目录，防止覆盖证据。最终 clean 目录保留；
此前开发/诊断运行也保留用于审计，不参与最终 PASS claim。

## Remaining / C3.4

- `SPEC-MASK-001` 仍 OPEN：RTL 是 MASK=1 enable，原文相反。
- RAL、formal、reviewed exclusions/waivers、最终 sign-off 不在 C3.3 范围。
- 结构常量 toggle、可激励 skid stall branch 与完整 traceability review 留到 C3.4。
- 本阶段变更留在工作区供评审，未 commit/tag；`v4.0-c3.2-baseline` 不变。
