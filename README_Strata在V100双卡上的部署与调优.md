# Strata 在 V100 双卡上部署 Qwen3.8-Flash-Next：完整过程、调优方法与结果

> 一份可复现的实践记录。目标是让 **Strata v0.1.24**（官方仅支持 RTX 30 系 / sm_80+）在
> **双 Tesla V100-16GB + 无 AVX-512 的老 Xeon** 上正确运行，并把一个 125B 级 MoE 模型调到可用速度。
> 文档与补丁均可直接分享给他人复用。

> [!IMPORTANT]
> **本仓库是第三方非官方补丁集合**，与 Strata 项目无隶属关系，也未获其背书。上游 Strata 以 MIT 许可发布，
> 本仓库同样以 MIT 分发（见 [`LICENSE`](LICENSE) 与 [`NOTICE`](NOTICE)）。
>
> **内容生成方式**：本文档、补丁与脚本中的排查过程、代码定位、补丁编写与文字编辑，均由
> **Space Bunny Free** 模型发现、处理与生成；**结果仅供参考**，不构成任何正确性或性能保证。
> 其中所有技术结论均经过人工逐项复测验证（与 llama.cpp 参照引擎的首 token 对照、11 个 parity 测试、
> 补丁在原始源码上的逐字节复现、117K token 深度针检索），但性能数字与具体硬件强相关，
> 换机器请自行重测。

---

## TL;DR（30 秒版）

- **一句话**：Strata v0.1.24 官方只支持 RTX 30 系（sm_80+）。这里给出让它在 **双 Tesla V100（sm_70）（PCIE，无nvlink）+ 无 AVX-512 的老 Xeon** 上正确跑起来的全部改动，实测 **128K 上下文 decode 43.4 tok/s、prefill 865 tok/s @117K token**。
- ⚠️ **只想拿补丁的话，先看补丁 02。** 不打它会得到「**输出乱码但看起来一切正常**」：长度对、速度对、显存对、换 prompt 时 logits 也会变，只有内容是错的。官方自带的 parity 测试全绿也发现不了。
- **该打哪个补丁**：

  | 你的情况 | 补丁 |
  |---|---|
  | V100 / T4 / RTX 20 系（sm_70~75），装不上或编不过 | **01（必需）** |
  | 任何硬件，怀疑输出质量 | **02（必需）** |
  | 用两张及以上 GPU | 03（可选，但 prefill 会腰斩） |
  | 要排查数值问题 / 自己做二次开发 | 04（可选，env 触发） |

- **两条与硬件无关的结论**：PLE 的 F32 权重被按 fp16 位读取；MTP 草稿词表子集会让中文接受率从 63% 掉到 18%。这两条在任何机器上都会复现。
- **上手顺序**：解压 → **打补丁 01** → `setup.sh` 下载权重并编译（§2.3，78GB，最耗时）→ 打补丁 02/03/04 → 放开 `memlock`（§2.5）→ 启动（§2.6）。
- **跑校验前先停服务**：parity 测试与常驻服务抢显存，不先停会全部 out of memory（§6）。

---

## 0. 结论速览

| 项 | 结果 |
|---|---|
| 能否装上 V100 | 能，需 6 处平台补丁（补丁 01） |
| 输出是否正确 | 能，需 1 处正确性修复（补丁 02）。**未修复时输出为乱码且看似正常** |
| 双卡是否比单卡快 | **修复后是**：decode +14~21%、长文 prefill +5%（补丁 03） |
| 投机解码 | 开启后中文 decode 33.9 → **43.4 tok/s**；需停用一个草稿词表子集（补丁 04 之外的操作项） |
| 最终性能 | **decode 43~48 tok/s，prefill 865 tok/s @117K token 上下文** |
| 上下文 | 模型支持 256K，本机开到 128K 并通过 117K 深度针检索验证 |

---

## 1. 环境（本机实测配置）

### 硬件

| 组件 | 配置 | 对本任务的影响 |
|---|---|---|
| GPU | **2 × Tesla V100-SXM2-16GB**（sm_70，2017 世代） | 官方不支持；无 BF16 张量核、无 FP8 |
| GPU 互联 | **PCIe Gen3 x16**，两卡经同一主机桥（PHB），**无 NVLink** | 跨卡只能走 PCIe，实测 10.9 GB/s |
| NUMA | **单节点**，两卡共享 CPU 0-13 | 无跨 NUMA 开销，但 CPU/内存带宽也是共享的 |
| CPU | **Intel Xeon E5-2680 v4 @2.40GHz**（单路 14 核，无超线程，L3 35MiB） | **只有 AVX2，无 AVX-512 / 无 VNNI** ← 关键短板 |
| 内存 | **62 GiB DDR4** | 专家竞技场 45.29GiB 常驻，128K 上下文时系统可用约 5-6GB |
| 磁盘 | NVMe 468GB（剩余 70GB） | 权重 78GB，加载约 0.5-1.0 GB/s |

### 软件

| | |
|---|---|
| 系统 | Ubuntu 24.04.5 LTS / Linux 6.8.0-142 x86_64 |
| GPU 驱动 | 580.178.04 |
| CUDA | 12.8（V12.8.93） |
| 模型 | `Qwen3.8-Flash-Next-UD-IQ3_XXS`（3 分片 GGUF，78GB） |
| 量化 | IQ3_XXS（i-quant），项目文档标注 RAM+VRAM 需求 47GB |

### 关键结论：瓶颈在哪

先说清楚这决定了后面所有优化的方向——**这套配置的瓶颈是 CPU，不是 GPU**：

- decode 每轮约 75ms，其中 **CPU 专家池占 34~56ms（约 70%）**
- 第二张 GPU **只增加"驻留专家的显存"，不增加算力、不增加内存带宽**（两卡共享同一 14 核与同一 DDR4 通道）
- 因此"加第二张卡就更快"的直觉在这台机器上不成立，必须靠**减少 CPU 需要计算的专家数量**（提高缓存命中率）来兑现收益

---

## 2. 部署步骤

### 2.1 解压

```bash
tar xzf Strata-0.1.24.tar.gz && cd Strata-0.1.24
```

> ⚠️ **先别跑 `./setup.sh`。** 安装器会把 V100 判为"不支持"并**在下载权重之前**直接退出，权重永远下不来。必须先打补丁 01（§2.2），再回来跑安装。

### 2.2 应用补丁（关键步骤）

在源码根目录依次执行：

```bash
patch -p1 < patches/01-平台适配-sm70与分片.patch                      # 必须最先，且必须早于 setup.sh
patch -p1 < patches/02-正确性修复-PLE卷积权重F32误当F16.patch          # 不打则输出乱码
patch -p1 < patches/03-双卡优化-分层流水线三处修复.patch               # 只影响双卡
patch -p1 < patches/04-诊断开关-逐层与PLE中间量转储.patch               # 可选，排障用
```

四个补丁相互独立、可单独应用；每一处改动在源码里都带 `Local patch` 注释，便于日后甄别与回滚。

**顺序约束**：补丁 01 改的是 `setup.py` 与 `CMakeLists.txt`，所以它必须在 `setup.sh` 之前打好——否则安装器在下载权重前就退出了（§2.1）。补丁 02/03/04 改的是引擎 C++ 源码，在 `setup.sh --build` 编译之前打好即可。

### 2.3 下载权重并生成 pack（前置步骤，最耗时）

官方安装器一条命令就能把「装依赖 + 下载权重 + 打包 + 编译」做完。打完补丁 01 后：

```bash
# 路线 A：让 Strata 自己下载官方默认权重（GSQ-RCO IQ3_XXS，2 分片）
./setup.sh --setup --family qwen --model IQ3_XXS --context 131072 \
           --gpus 0,1 --build --no-start

# 路线 B：已经有本模型的 GGUF（分片数任意），跳过下载
./setup.sh --setup --family qwen --model IQ3_XXS --context 131072 \
           --gpus 0,1 --build --no-start \
           --gguf-dir ~/.lmstudio/models/unsloth/Qwen3.8-Flash-Next-GGUF
```

| 参数 | 为什么需要 |
|---|---|
| `--build` | Releases 里的预编译引擎是 sm_80+ 的，V100 跑不了，**必须本地编译** |
| `--no-start` | 只装不启，方便先把补丁打全、再跑校验（§6） |
| `--gpus 0,1` | 双卡分层流水线；单卡用 `--gpu 0` |
| `--context 131072` | 128K。想更稳可用 `32768`：专家缓存多 17%、prefill 略快（§5.2） |
| `--gguf-dir` | 用你自己已有的 GGUF。**多分片（如 `-00001-of-00003`）依赖补丁 01 的分片发现** |

前置条件与预期开销：

- **磁盘**：IQ3_XXS 官方权重约 **75.8GB**，加上 pack 与中间产物，安装器要求再多留 **≥ 84GB**（它自己会检查并报错提示）。
- **内存**：官方标称 IQ3_XXS 需 **60GB RAM**；本机 62GiB 实测够用，但 128K 上下文时系统可用内存仅剩 5~6GB。
- **耗时**：下载取决于带宽；打包阶段还要读写几十 GB。
- **产物**：`packs/iq3_xxs/{dense.bin, index.txt, tokenizer/}`（约 45GB）。
- **Hugging Face 不通**：补丁 01 已让 `tools/mtp_fetch.py` 读取 `HF_ENDPOINT`，用 `export HF_ENDPOINT=https://hf-mirror.com` 即可，不改代码。

产物是 **native 包**（IQ 量化专家 + 直接从 GGUF 读取的投影矩阵），因此 `--mmap-experts` 不可用（启动会明确拒绝，这是预期行为）。

### 2.4 编译

```bash
PATH="$PWD/.venv/bin:$PATH" .venv/bin/cmake --build build -j 10
cp -f build/strata engine/strata          # 约 1~2 分钟（44 个 .cu）
```

> §2.3 带了 `--build` 的话这一步已经完成，这里仅供你中途改了 C++ 之后重编。

### 2.5 系统配置：放开 memlock

```bash
echo '*  -  memlock  unlimited' | sudo tee /etc/security/limits.d/99-strata.conf
```

**为什么需要**：Linux 下钉住主机内存（`cudaHostRegister` 内部用 `mlock`）受 `RLIMIT_MEMLOCK` 限制，本机默认仅 **7.84GiB**（软=硬，需 root）。放开后两个 CUDA 上下文才能都完整钉住 45.29GiB 专家竞技场——这是双卡优化补丁 03 生效的前提。

### 2.6 启动

见本目录 `启动Strata-双卡.sh`。最小命令行形式：

```bash
M=<第2分片.gguf>     # 含 output.weight / token_embd / PLE key
./engine/strata \
  --pack "$HOME/Strata-data/packs/iq3_xxs" \
  --native "$M" --ple-gguf "$M" \
  --expert-profile data/expert-profile.bin --expert-cache auto \
  --prefill auto --spec 2 --spec-min-p 0.5 \
  --mtp "$HOME/Strata-data/mtp/rt" \
  --max-context 131072 --kv int8
```

服务模式下配置 `"gpu": [0,1]` 即启用双卡分层流水线（框架会自动追加 `--layer-split auto`）。

> 本目录的 `strata-iq3_xxs.json` 里写的是占位符 `/home/YOUR_USER`（server.py 不做 `~` / `$HOME` 展开）。
> 用 `启动Strata-双卡.sh` 启动时它会自动替换成你的 `$HOME`；若手动跑引擎，请自己替换：
> `sed -i "s|/home/YOUR_USER|$HOME|g" strata-iq3_xxs.json`

---

## 3. 遇到的问题与解决

### 3.1 平台：V100 不在支持范围内

官方矩阵是 RTX 30 系以上（sm_80+），V100 是 sm_70。补丁 01 处理了 6 处：安装器架构门槛、CMake 架构守卫、设备资格检查、hf-mirror 下载覆写、IQ 内核的 Q6_K 分派、多 GGUF 分片发现。

**经验**：改架构门槛前先确认那些 `#if __CUDA_ARCH__ >= 800` 的 kernel 有没有向下回退分支。本项目有（`qsa_select.cu` / `qsa_prompt_attn.cu` / `native_qsa_score.cu` 都有旧路径），所以 sm_70 上注意力能跑，只是慢。这是"官方不支持但实际能跑"的前提条件。

### 3.2 正确性：输出乱码（最耗时的一次排查）

**现象**：输出是字母/符号乱码，但长度正常、速度正常、显存正常，且**对 prompt 有响应**（换 prompt 时 logits 余弦只有 0.198，确实在变）。这种"有限、稳定、但完全错误"的输出，最难定位。

**根因**：`blk.1.ple_conv1d.weight` 在该 GGUF（Unsloth 量化）里是 **F32**，而引擎把它按 fp16 位强转给 PLE 卷积核：

```cpp
// 错误：把 F32 字节当成 fp16 位
ss.ple.w.conv1d_f16 = (const uint16_t*) wc->data;
```

卷积核用 `__ushort_as_half` 读它 → 每个权重被读成两个垃圾半精度数 → **卷积输出大约 500 倍** → 第 1 层残差被污染 → 后续 47 层全部基于错误残差。而 embedding、超连接混合器、48 层主干、lm_head 全都正确，所以表面看"只有输出不对"。

**为什么项目自带测试没抓到**：`ple_parity` 等测试用的是**合成的 F16 权重**，不会发现"文件里其实是 F32"；且 release 未附带 `ref/model.py` 与 `bench/micro/*_parity.cpp`（官方 oracle），所以"测试全绿"并不能证明数值正确。

**修复**（补丁 02）：加载时按 `WeightKind` 与字节数判断，F32 则 D2H 读回 → 逐元素 `f16_from_f32` 重舍入一次 → H2D 上传。启动日志出现 `PLE conv1d re-rounded F32 -> fp16 (40960 taps)` 即为生效标志。

> ⚠️ 移植注意：**先判断 pack 里该张量的 `kind` 与 `dst_bytes`**，别相信内核头文件里注释的元素类型——那是针对另一种 artifact 写的。

### 3.3 性能：双卡原样并行时 prefill 下降

上游原版实测（128K 上下文）：

| | 单卡 | 双卡原样 |
|---|---|---|
| decode | 29~31 tok/s | 32~34 tok/s |
| prefill 4K | 790 tok/s | 406 tok/s |
| prefill 28K | 932 tok/s | **378 tok/s（74 秒）** |

即 prefill 腰斩。定位到三个原因（补丁 03 修掉前两个）：

**原因 A：第二张卡的专家缓存被"预留"逻辑压低**
`generate.cpp` 里两处算法不一致：`:2021` 的 CUDA0 定尺寸在"借用"时不预留 prompt 缓冲，`:1887` 的 `split_pf_mib` 却按 `chunk*680` 给**每张卡**都预留。上游默认配置下不会暴露这一不一致——因为分卡时必定禁用借用，两边恰好一致。放开借用后 CUDA1 从 3461 slot 掉到 **1290 slot**，decode 33 → 27.7 tok/s。
> 正确的规则：**首段借用（不预留），后续段为自己的 prompt 缓冲付费**。

**原因 A2：连带 chunk 被强制降到 2048**
`:1153` 分卡时硬编码 `no_prefill_borrow = true`，`:1174-1178` 连带把 chunk 从 8192 压到 2048。放开借用后 chunk 涨回 8192，后续段直接起不来：`device buffers for a chunk of 8192 tokens do not fit`。修复是**借用照旧、chunk 仍限 2048**。

**原因 B：8GiB 钉住上限是 Windows/WDDM 的 workaround**
`:1827` 的注释自己写明是 WDDM 问题（*"pinning all of it into two contexts leaves WDDM refusing every later allocation"*），却在 Linux 上无条件生效 → 第二个 CUDA 上下文只钉住 7GiB/45.29GiB，读未命中专家走**可分页内存逐页拷贝**而非真 DMA。这是 prefill 少一半的直接原因。改为仅 Windows 生效。

**原因 C：硬件层面的上限**
见 §1。decode 上限约 35~40 tok/s（优化前口径），瓶颈是 CPU 专家池。

### 3.4 投机解码：草稿词表子集显著拉低中文接受率

**收益最大的一次改动，且与硬件无关。**

引擎支持一个可选文件 `rt/draft_vocab.bin`（`mtp.cpp:303`、`:468`）：存在时，草稿头**只在这批 token 里预测**。本机这份是 **40,525 个 id**（全词表 248,320 的 16%），显然是按英文/代码语料统计的：

| 场景 | 在子集内覆盖率 | 草稿接受率 |
|---|---|---|
| 中文-技术 | **13.2%** | 18% |
| 中文-对比 | **38.8%** | 40% |
| 英文-技术 | 75.8% | 56% |
| 英文-代码 | **96.4%** | 74% |

缺失的中文 id 集中在 **95,000~115,000**（CJK 字符所在区间）→ 草稿在结构上猜不到中文，**必然被拒**。覆盖率与接受率几乎完全同步。

**修复**：停用该文件，草稿回退到完整 248,320 词表。源码里 `sub = dhead_ != nullptr` 这条分支意味着**直接复用主模型的 head，零额外显存**（实测专家缓存尺寸不变）。

| 场景 | 接受率 改前 → 改后 | decode 改前 → 改后 |
|---|---|---|
| 中文-技术 | 18% → **63%** | 21.3 → 26.4 tok/s |
| 中文-对比 | 40% → **60%** | 37.5 → **46.8 tok/s** |
| 英文-技术 | 56% → **77%** | → 47.6 tok/s |
| 英文-代码 | 74% → **81%** | → 44.3 tok/s |

---

## 4. 调优方法论（可迁移的部分）

这一节是本记录里最通用的部分——**方法比结论更容易复用到别的机器/模型上**。

### 4.1 先读懂引擎自带的分解日志

不要猜瓶颈，去日志里读。Strata 启动会打印：

```
expert cache auto: 10.83 GiB free -> 3993 slots      ← 缓存能装多少（受空闲显存直接决定）
layer split auto: CUDA1 80 SMs at 1.53GHz -> 0.59 ms per layer, 6.35 GiB for experts
the prompt path borrows 2335 cache slots (4.31 GiB)   ← ←← 关键：借用 or 独占
expert arena: cudaHostRegister ...                    ← ←← 关键：钉住是否完整
verify window  wait for rings 16.9  pool 88.9 ms     ← ←← 关键：CPU 池占多少
pool multi     gate/up 55.5  down 31.5 ms/round
pcie experts   2.90 distinct experts per layer read over PCIe
```

**判断顺序**：先看 `pool` 占 `verify window` 的比例 → 决定是"减少 CPU 计算量"还是"优化 GPU 侧"；再看 `borrows/own buffers` → 决定要不要动 prompt 路径策略；最后看 `expert arena` 的钉住字节数 → 决定 PCIe 是不是走了慢路径。

### 4.2 建立可比基线（最容易出错的一步）

- **固定 prompt、固定命令、只改一个变量**，其余全部不动
- 长文本吞吐必须用**长 prompt** 测：用 64 token 的 prompt 测出来的"prefill 50 tok/s"全是固定启动开销（本项目曾因此误判 prefill 只有 50，实际长 prompt 是 835）
- 每个配置**至少复测两次**：本项目实测同一配置波动可达 ±10%（37.4 vs 43.9 这种非单调现象）
- 窗口大小、单 token 指标（decode tok/s）比合计值更能反映本质

### 4.3 定位数值 bug 的通用流程

1. **把范围缩到最小**：本项目用**单 token prompt** 让 bug 在位置 0 就暴露 → 一次排除 KV / prefill / prompt 注意力历史 / 投机解码
2. **证明"大部分是对的"**：把 embedding、lm_head、每个投影层都用 numpy 复算到逐位一致 → 证明问题只在残差
3. **逐层对照参照实现**：用另一个引擎（本项目用 llama.cpp 的 `eval-callback`）导出**同一个 token 的完整逐张量参考图**，按层比对，把范围从"48 层 + KV + prefill + 专家路径"缩到"某一个模块"
4. **再用中间量转储定位到单个 kernel**：本项目加了 PLE 中间量转储（key/query/norm/gated/conv/value/gate/emb），一眼看出只有 conv 偏大 1000 倍
5. **注意参照工具的陷阱**：`eval-callback` 打印的 `sum` 只是**首尾各 3 个显示值之和**，不是完整张量求和；曾因此误判 embedding 对不上

> 关键判据：**"有限、稳定、但完全错误"的输出 + 所有测试全绿**，几乎总是"某个张量的元素类型/字节布局被误解释"，而不是算错。

### 4.4 判断"某个优化值不值得做"

用**边际收益递减**判断，而不是凭直觉。本项目的 CPU 池是按 token 计费的，于是投机解码的窗口大小有个明确的最优点：

```
每轮成本 ≈ 窗口大小 × 每 token 成本
每轮收益 ≈ 1 + 接受率 × (窗口大小 - 1)
```
接受率 60~78% 时，`--spec 2`（窗口 4）性价比最高；`--spec 6`（窗口 8）验证 8 个 token 换来的收益抵不过多算的 4 个 → 实测从 43.4 掉到 27.6 tok/s。**先算这个比值，再决定参数**，比盲扫快得多。

### 4.5 硬件天花板估算

用两个已知点拟合，再外推：本项目"命中率 52.9% → 30 tok/s、65.3% → 33 tok/s"，外推得 **35~40 tok/s 是这套硬件的 decode 上限**。有了天花板，就知道哪些优化不用做——本项目据此直接放弃了张量并行。

---

## 5. 结果

### 5.1 性能对照（本机实测，同 prompt 同命令）

| 指标 | 单卡 | 双卡（上游原样） | **双卡 + 补丁 03** |
|---|---|---|---|
| decode（99 token，无 MTP） | 29.2~31.0 | 32.5~33.8 | **35.2** |
| prefill 4053 token | 790 | 406 | **744** |
| prefill 28053 token | 932 | 378（74.1s） | **976（28.7s）** |
| 专家驻留 | 4756 slot | 8142 | **8867**（+86%） |
| 竞技场钉住 | 全量（仅 CUDA0） | 7GiB（CUDA1 被限） | **45.29GiB，两卡都注册** |

启用 MTP 调优后（最终配置）：

| 场景 | decode | 草稿接受率 |
|---|---|---|
| 中文-技术 | 26~34 tok/s | 63~82% |
| 中文-对比 | **46.8 tok/s** | 60% |
| 英文-技术 | 47.6 tok/s | 77% |
| 英文-代码 | 44.3 tok/s | 81% |
| 中文三题合计 | **43.4 tok/s**（复测 43.9/42.9） | 77~78% |
| prefill @117,088 token | **865 tok/s（135 秒读完）** | — |

### 5.2 上下文长度

| 配置 | 专家驻留 | decode | prefill 4K | prefill 长文 |
|---|---|---|---|---|
| 32,768 | 8867 slot | 35.2 | 744 | 976 @28K |
| **131,072（最终）** | 7368 slot | 34.8 | 700 | **865 @117K** |

128K 只多花 1~6%，代价是专家缓存少 17%（都是低频尾部）。
**已在 117,088 token 深度做过针检索验证**：唯一事实 `ZX-4417` 埋在约 58K token 处（正好在两段卡的切点附近），准确命中。

### 5.3 正确性验证

| 检查 | 结果 |
|---|---|
| `--tokens 760`（"The"）首个 token | **20438**，与 llama.cpp 参照一致 |
| `--tokens 760,6511,314,9338,369` 首个 token | **11751**（" Paris"），与参照一致 |
| embedding / lm_head / Q8_1 / Q6_K 全部 248320 logits | 逐位一致（max\|Δ\| 4.8e-6） |
| PLE 各中间量 | 与参照图一致 |
| 11 个 parity 测试 | 全过（`iq_parity` 因 release 缺 Q3_K fixture 失败，与本机无关） |
| `native_expert_parity` | 0 failures |
| 分卡交接位精确自检（`--layer-split 24 --split-device 0`） | 与单卡输出**逐字节一致** |
| 双卡 vs 单卡文本 | 仅一处措辞差异（官方记录的专家 GPU/CPU 舍入差） |
| 117K 针检索 | 命中 |

---

## 6. 如何验证"装对了"

```bash
# 1) 最强判据：与参照引擎比首 token
#    "The"（760）-> 20438 ; "The capital of France is" -> 11751
./engine/strata --pack ... --tokens 760 --max-new 1      # 看 output 的第一个 id

# 2) parity 测试（先停服务，否则显存不够会全部报 out of memory）
ps -eo pid,cmd | grep '[s]erve/server.py' | awk '{print $1}' | xargs -r kill
for t in ple_parity gr_parity bf16_gemv_parity gdn_parity qsa_parity kv_q8_parity \
         kv_q4_parity kv_stream_parity router_top10_parity s2_gemv_parity shared_expert_parity; do
  LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64 ./build/$t >/dev/null 2>&1 && echo "$t OK" || echo "$t 失败"
done

# 3) 启动日志自检（缺哪项就是没生效）
grep -E "PLE conv1d re-rounded|expert arena|borrows|own buffers|layer split:" strata-*.log | tail -6
```

**注意**：参照 llama.cpp 本身有坑——`-c 2048` 会让 logits 变平（必须 `-c 4096`）、`-ngl 18` 部分 offload 会输出全 `!`、`-ngl 99` OOM。

---

## 7. 回滚

| 想回退 | 做法 |
|---|---|
| 停用草稿词表子集 | 把 `draft_vocab.bin.bak` 改回 `draft_vocab.bin` |
| 恢复上游"分卡禁用借用" | 启动加 `STRATA_SPLIT_NO_BORROW=1` |
| 恢复 8GiB 钉住上限 | 启动加 `STRATA_ARENA_PIN_CAP=8` |
| 回到单卡 | 配置 `"gpu": [0,1]` → `0`，重启 |
| 上下文 128K → 32K | 配置 `--max-context 131072` → `32768` |
| 撤销全部补丁 | `patch -R -p1 < 对应补丁`（建议按 04→03→02→01 逆序） |

---

## 8. 适用边界（哪些结论与硬件绑定）

| 结论 | 是否依赖本机硬件 | 说明 |
|---|---|---|
| PLE F32/F16 修复 | ❌ **与硬件无关** | 只要 artifact 把该权重存成 F32 就会复现，务必检查 |
| 草稿词表子集拉低中文接受率 | ❌ **与硬件无关** | 用中文/专业术语时必然复现 |
| 分卡预留不一致（原因 A/A2） | ⚠️ 部分 | 只在"分卡 + 想放开借用"时暴露；上游自己碰不到 |
| 8GiB 钉住上限（原因 B） | ⚠️ 部分 | Windows 之外的平台都不该套用 WDDM 限制 |
| `--spec 2` 最优 | ✅ **强依赖** | 因为 CPU 池按 token 计费。GPU 充裕时应重新扫（接受率高时更大窗口可能更优） |
| decode 上限 35~40 tok/s | ✅ 强依赖 | 换 CPU（AVX-512/VNNI）或更多核可显著提升 |
| 不做张量并行 | ✅ 强依赖 | PCIe Gen3 x10.9GB/s + 小包 2.4~2.9µs（而空 kernel 启动就要 2.0~2.3µs）撑不住每层每专家的归约 |

**关于张量并行**：Strata 本身没有 TP 实现（全仓库无 NCCL / all-reduce / 集合通信，文档明确 *"pipeline (layer) parallelism, **not tensor parallelism**"*）。
补充一条已有结论：另一个 llama.cpp 分支**有** TP 实现且实测比 layer 快约 30%，但 `hyper-connections`（qwen4exp，即本模型架构）是**硬缺口、无代码路径**——所以这个架构下 TP 已被判定走不通。

---

## 9. 本目录文件

| 文件 | 说明 |
|---|---|
| `README_Strata在V100双卡上的部署与调优.md` | 本文档 |
| `patches/01-平台适配-sm70与分片.patch` | 6 处平台适配，让 V100 能装能编 |
| `patches/02-正确性修复-PLE卷积权重F32误当F16.patch` | **必打**，否则输出乱码 |
| `patches/03-双卡优化-分层流水线三处修复.patch` | 只影响双卡，单卡用户可跳过 |
| `patches/04-诊断开关-逐层与PLE中间量转储.patch` | 排障用，env 触发、默认惰性 |
| `patches/README.md` | 补丁应用顺序与说明 |
| `启动Strata-双卡.sh` | 一键启动（自动设双卡、替换路径占位符、停旧实例、显存自检、就绪轮询）。路径可用 `STRATA_DIR=` 覆盖 |
| `strata-iq3_xxs.json` | 实测最优配置（双卡 / 128K / spec=2）。其中 `/home/YOUR_USER` 为占位符，启动脚本会自动替换 |
| `验证清单.md` | 逐项可跑的验证步骤 |
| `LICENSE` | 本仓库内容许可（MIT） |
| `NOTICE` | 上游项目与第三方许可声明；本包不含模型权重 |

> 补丁集已验证：在**原始 v0.1.24 源码**上按序应用后，8 个受改文件与本机可运行工程**逐字节一致**。
