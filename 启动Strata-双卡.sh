#!/bin/bash
# ============================================================================
#  启动 Strata（Qwen3.8-Flash-Next IQ3_XXS）—— 双卡分层流水线（layer split）
#  硬件：2 x Tesla V100-16GB（PCIe Gen3 x16，无 NVLink）+ 64GB DDR4
#
#  实测性能（本机，2026-09-30，128K 上下文 + MTP 投机解码）：
#    decode    34~48 tok/s（中文场景草稿接受率 60~82%）
#    prefill   865 tok/s @117K（135 秒读完 11.7 万 token）
#  单卡对照：decode 29~31 tok/s、prefill 790/932 tok/s —— 双卡三项均更优。
#
#  投机解码调优（2026-09-30 实测，已写进配置）：
#    --spec 2 --spec-min-p 0.5   中文合计 43.4 tok/s、接受率 77~78%
#    （spec 越大越慢：每轮验证的 token 越多，而 CPU 专家池是按 token 计费的）
#    草稿词表：已停用 $HOME/Strata-data/mtp/rt/draft_vocab.bin
#      （原 40525 个 token 的英文子集，中文只覆盖 13~39%；
#        停用后草稿用完整 248320 词表，中文接受率 18%→63%、40%→60%）
#      备份在同目录 draft_vocab.bin.bak，需要时改回文件名即可恢复。
#
#  上下文：模型本身支持 256K，本机开到 128K 已在 117K token 深度做过针检索验证。
#        要改的话编辑 strata-iq3_xxs.json 里的 --max-context（32768 / 131072 …）。
#        提示：64GB 内存是项目标称下限；128K 时系统可用内存约 6 GB，
#              启动前请先关掉占显存的程序（如 llama-server）和占内存的大程序。
#
#  用法：  ./启动Strata-双卡.sh          前台运行（Ctrl+C 停止）
#          nohup ./启动Strata-双卡.sh &  后台运行
#          启动后浏览器打开 http://127.0.0.1:8080/
#
#  自定义路径（可选，均有默认值）：
#          STRATA_DIR=/path/to/Strata-0.1.24 ./启动Strata-双卡.sh
#  配置文件 strata-iq3_xxs.json 里的 /home/YOUR_USER 是占位符，本脚本启动时会
#  自动替换为 $HOME，所以从 GitHub  clone 下来通常不需要手工改。
# ============================================================================
set -u

STRATA_DIR="${STRATA_DIR:-$HOME/Strata-0.1.24}"
PORT="${PORT:-8080}"
LOG="$STRATA_DIR/server.log"

cd "$STRATA_DIR" || { echo "找不到 $STRATA_DIR"; exit 1; }

# ---- 0. 把配置里的 /home/YOUR_USER 占位符换成 $HOME（幂等）
if grep -q "/home/YOUR_USER" strata-iq3_xxs.json 2>/dev/null; then
    sed -i "s|/home/YOUR_USER|$HOME|g" strata-iq3_xxs.json
    echo "已把配置中的 /home/YOUR_USER 替换为 $HOME"
fi

# ---- 1. 配置双卡（"gpu": [0,1]；引擎会按各卡实际空闲显存自选切分点 K）
python3 - "$STRATA_DIR/strata-iq3_xxs.json" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["gpu"] = [0, 1]                 # 双卡分层流水线
json.dump(cfg, open(p, "w"), indent=1)
print("配置: gpu =", cfg["gpu"])
PY

# ---- 2. 停掉旧实例（否则显存不够，新实例会分配失败）
if pgrep -f "serve/server.py" > /dev/null; then
    echo "停止已有实例..."
    pgrep -f "serve/server.py" | xargs -r kill
    sleep 5
fi

# ---- 3. 显存自检：两张卡都要有富余，否则专家缓存装不下
echo "当前显存："
nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader | sed 's/^/  /'
for i in 0 1; do
    FREE=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits -i $i)
    if [ "$FREE" -lt 6000 ]; then
        echo "⚠️  GPU$i 空闲仅 ${FREE} MiB。若有别的程序占显存（如 llama-server），请先退出再启动。"
    fi
done

# ---- 4. 启动
echo "启动中（加载 45GB 权重，约 60~90 秒）..."
./.venv/bin/python serve/server.py --engine strata \
    --config strata-iq3_xxs.json --port "$PORT" >> "$LOG" 2>&1 &
SERVER_PID=$!

# ---- 5. 等待就绪并把关键指标打出来
for i in $(seq 1 40); do
    sleep 5
    if curl -s -m 3 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"status": "ok"'; then
        echo
        echo "✅ 就绪：http://127.0.0.1:$PORT/v1   （浏览器界面 http://127.0.0.1:$PORT/）"
        echo "   OpenAI 兼容： POST /v1/chat/completions"
        echo "   Anthropic 兼容：POST /v1/messages"
        echo
        echo "本轮生效的分配："
        grep -E "layer split:|expert cache [0-9]+ slots|borrows|expert arena" strata-iq3_xxs.log | tail -5 | sed 's/^/   /'
        echo
        CTX=$(python3 -c "import json;print(json.load(open('strata-iq3_xxs.json'))['args'][json.load(open('strata-iq3_xxs.json'))['args'].index('--max-context')+1])" 2>/dev/null)
        echo "上下文：${CTX} tokens"
        echo "实测：decode 34.8 tok/s | prefill 700@4K、865@117K"
        echo "停止服务：kill $SERVER_PID   （查看日志：tail -f $LOG）"
        exit 0
    fi
    kill -0 "$SERVER_PID" 2>/dev/null || { echo "❌ 启动失败，日志末尾："; tail -15 "$LOG"; exit 1; }
done
echo "❌ 等待超时，请查看 $LOG"
exit 1
