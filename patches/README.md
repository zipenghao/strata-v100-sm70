# 补丁集说明

适用版本：**Strata v0.1.24**（GitHub Releases `v0.1.24` 原始 tarball）
验证方式：在原始源码上按序应用后，8 个受改文件与本机可运行工程**逐字节一致**。

## 应用顺序与作用

| 顺序 | 文件 | 作用 | 必需性 |
|---|---|---|---|
| 1 | `01-平台适配-sm70与分片.patch` | 让安装器/CMake/设备检查接受 sm_70（V100），补 Q6_K 在 IQ 内核的分派，泛化多 GGUF 分片发现，支持 hf-mirror 覆写 | **V100 必需** |
| 2 | `02-正确性修复-PLE卷积权重F32误当F16.patch` | 修复 `ple_conv1d.weight` 被按 fp16 位读取 → PLE 卷积输出放大约 500 倍 → 第 1 层起残差被污染 → **输出乱码** | **必需（不分硬件）** |
| 3 | `03-双卡优化-分层流水线三处修复.patch` | 修正分卡时 prompt 路径"借用 vs 预留"两处算法不一致、chunk 限回 2048、8GiB 竞技场钉住上限改为仅 Windows 生效 | 仅双卡用户需要 |
| 4 | `04-诊断开关-逐层与PLE中间量转储.patch` | verify 窗口的 logits / 残差 / 逐层快照 / PLE 中间量转储（env 触发，默认完全惰性）；单 token prompt 可进入验证窗口 | 可选，排障用 |

```bash
# 在 Strata-0.1.24 源码根目录
patch -p1 < 01-平台适配-sm70与分片.patch
patch -p1 < 02-正确性修复-PLE卷积权重F32误当F16.patch
patch -p1 < 03-双卡优化-分层流水线三处修复.patch
patch -p1 < 04-诊断开关-逐层与PLE中间量转储.patch
```

回滚按逆序 `patch -R -p1`。

## 涉及文件

| 文件 | 补丁 01 | 02 | 03 | 04 |
|---|:-:|:-:|:-:|:-:|
| `setup.py` | ✅ | | | |
| `CMakeLists.txt` | ✅ | | | |
| `tools/mtp_fetch.py` | ✅ | | | |
| `src/core/device.cu` | ✅ | | | |
| `src/core/native_head.cpp` | ✅ | | | |
| `src/kernels/cuda/iq_kernels.cu` | ✅ | | | |
| `src/program/generate.cpp` | ✅（分片） | ✅（PLE 修复） | ✅（三处双卡优化） | ✅（单 token 窗口） |
| `src/core/verify.cpp` | | | | ✅（转储开关） |

## 配套的系统配置（非补丁）

补丁 03 生效需要放开 `memlock`，否则第二个 CUDA 上下文钉不住完整竞技场：

```bash
echo '*  -  memlock  unlimited' | sudo tee /etc/security/limits.d/99-strata.conf
```

## 运行时开关（无需重编译）

| 变量 | 作用 |
|---|---|
| `STRATA_SPLIT_NO_BORROW=1` | 恢复上游"分卡禁用 prompt 借用"的行为 |
| `STRATA_ARENA_PIN_CAP=8` | 恢复 8GiB 钉住上限（上游在所有平台都生效） |
| `STRATA_DUMP_LOGITS / _HEAD / _LAYERS2 / _PLE = PATH` | 输出诊断转储（补丁 04） |

## 已知的"不需要它"的场景

- **RTX 30 系及以上**：跳过补丁 01（平台本就支持）
- **只用单卡**：跳过补丁 03
- **artifact 里 `ple_conv1d.weight` 本来就是 F16**（pack index 里 `dst_bytes = 元素数 × 2`）：补丁 02 会走"已是 fp16 位"分支直接使用，但仍建议打上，因为它会显式校验形状与字节数并在异常时报错而不是静默算错
