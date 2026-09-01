# LASA 投稿冻结门禁

只有所有硬门禁都具备可重算的 JSON/CSV、原始日志和 SHA256，才允许移除
论文首页的“内部证据稿”标识。

## 已完成且须保持

- [x] r5 fresh full implementation；200 MHz SYSTEM_IMPL PASS。
- [x] 资源、route timing、DRC、unconstrained/internal-none 门禁。
- [x] 128 张、22 节点、2816 records，byte mismatch=0。
- [x] 5000 张 raw-head/network mAP 与 RTL-host 完全一致。
- [x] 5000 张 `detections + accuracy` A53 product 后处理：逐图顺序、类别、
  source index 和 NMS 集合一致，score/bbox 达到既定容差，COCOeval 指标一致。
- [x] 3 runs x (20 warmup + 1000 timed) 性能，CRC deterministic。
- [x] 600 s Ethernet soak，无 CRC/DMA/PL/timeout/重连错误。
- [x] SD 冷启动及 100 timed 重复性验证。
- [x] Vivado post-route estimated power；记录 junction temperature、process、
  vectorless toggle/static probability、置信度和报告哈希。

## 投稿前硬门禁

- [ ] Native-1x1 vs sparse-3x3 受控变体。
- [ ] legacy per-pass IFM vs materialize/replay 受控变体。
- [ ] no-preload/no-handoff、preload-only、preload+handoff、full-overlap 四级。
- [ ] 固定保守 tile vs 层自适应 tile。
- [ ] 同板完整 13 卷积单核标量 C 基线。
- [ ] 同板完整 13 卷积四核 NEON/output-channel 基线。
- [ ] 外部工作表逐项回原始论文核对，并记录页码/表号和统计口径。
- [ ] 公开 artifact 自检：clean release tag、新机器从 manifest 重建表/PDF、
  固定 golden 和结果 hash 全部闭环。

## 论文文字门禁

- [ ] 不出现“无精度损失”“模型发布通过”或功耗实测表述。
- [ ] 摘要和最终性能表不出现旧 100 MHz、18x8、288 ms、单尺度 24 通道。
- [ ] 576 个阵列 DSP 与 650 个系统 DSP 分开报告。
- [ ] resident、pipeline、SD I/O、cold boot 的时间边界明确。
- [ ] conv-only GOPS 不与外部 end-to-end FPS 直接排名。
- [ ] 不能执行完整网络的消融只报告代表层，不外推端到端。
- [ ] 所有表格由脚本生成，禁止手抄数值。
