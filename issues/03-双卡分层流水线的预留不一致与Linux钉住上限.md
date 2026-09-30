**Summary:** two separate problems that only show up when a layer split is combined
with prompt borrowing on a non-Windows platform. The second one is why prefill roughly
halves on two cards.

Environment: 2x Tesla V100-SXM2-16GB (sm_70, PCIe Gen3 x16, no NVLink, same host
bridge), Xeon E5-2680 v4, 62 GiB RAM, driver 580.178.04, CUDA 12.8, v0.1.24 built from
source. Context 131072. All numbers from the same prompt and the same command.

## Problem 1: prompt-borrow sizing disagrees with prompt-buffer reservation

Under a layer split, upstream sets `no_prefill_borrow = true`, so the prompt path owns
its own buffers and both sizing paths happen to agree. If you enable borrowing, they
stop agreeing:

- the CUDA0 sizing at `src/program/generate.cpp:2021` does **not** reserve the prompt
  buffer when it borrows
- `split_pf_mib` at `src/program/generate.cpp:1887` reserves `chunk*680` **per card**

Measured effect of enabling borrowing as-is: CUDA1 dropped from 3461 expert-cache slots
to **1290**, decode 33 -> 27.7 tok/s.

Enabling borrowing also needs a second change: `:1153` hardcodes
`no_prefill_borrow = true` when splitting, which pulls chunk down from 8192 to 2048 at
`:1174-1178`. With borrowing on and chunk left at 8192 the engine cannot start at all:

```
device buffers for a chunk of 8192 tokens do not fit
```

My fix: borrow on the first pass (no reservation), and let every later pass pay for its
own prompt buffer; keep the chunk cap at 2048.

```
layer split auto: CUDA1 80 SMs at 1.53GHz -> 0.59 ms per layer, 6.35 GiB for experts
the prompt path borrows 2335 cache slots (4.31 GiB)
expert cache auto: 10.83 GiB free -> 8867 slots        (was 4756 on one card)
```

## Problem 2: the 8 GiB pin cap is a WDDM workaround applied on every platform

`src/program/generate.cpp:1827` caps pinned host memory at 8 GiB, and the comment says
why:

> pinning all of it into two contexts leaves WDDM refusing every later allocation

That is a Windows/WDDM problem, but the cap is applied unconditionally. On Linux the
second CUDA context then pins only 7 GiB of the 45.29 GiB expert arena, and expert
reads that miss the cache go through **pageable memory, page by page**, instead of DMA.
That is the direct cause of the prefill regression:

| | 1 card | 2 cards, as-is | 2 cards, fixed |
|---|---:|---:|---:|
| prefill, 4053-token prompt | 790 tok/s | 406 tok/s | **744 tok/s** |
| prefill, 28053-token prompt | 932 tok/s | 378 tok/s (74.1 s) | **976 tok/s** (28.7 s) |
| decode, 99 tokens, no MTP | 29.2-31.0 | 32.5-33.8 | **35.2** |
| expert residency | 4756 slots | 8142 | **8867** (+86%) |
| arena pinned | full, CUDA0 only | 7 GiB (CUDA1 capped) | **45.29 GiB, both contexts** |

### Prerequisite if you make the cap Windows-only

On Linux, raising the cap only helps once `RLIMIT_MEMLOCK` allows it. Without it the
arena cannot be pinned at all and you regress to pageable copies - slower, and on a
62 GiB machine it can fail outright. So this needs to ship together with:

```bash
echo '*  -  memlock  unlimited' | sudo tee /etc/security/limits.d/99-strata.conf
# new login required; verify with: grep "Max locked memory" /proc/<engine-pid>/limits
```

Defaults are 7.84 GiB here (soft == hard, needs root).

## Escape hatches

Both behaviours are still reachable without recompiling, which is how I A/B'd them:

- `STRATA_SPLIT_NO_BORROW=1` - restore upstream's "no borrowing under a split"
- `STRATA_ARENA_PIN_CAP=8` - restore the 8 GiB cap on all platforms

## Questions

1. Would you accept making the pin cap Windows-only? It is the single biggest win here,
   but it moves a memory requirement onto the user, so it probably wants documentation
   and a warning rather than a silent change.
2. On problem 1, is "first pass borrows, later passes own their buffer" the intended
   semantics? If so, the two sizing sites just need to agree on it.

Patches and the full investigation: https://github.com/zipenghao/strata-v100-sm70

Related: #303 (garbled output, same setup) and #305 (sm_70 support).

*Note: this report and the linked patches were drafted with AI assistance; all numbers
above were measured manually on the hardware listed.*
