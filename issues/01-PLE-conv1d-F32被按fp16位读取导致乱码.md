**Version:** v0.1.24 (official release tarball)
**Engine build:** compiled from source, sm_70
**Hardware:** 2x Tesla V100-SXM2-16GB (sm_70, PCIe Gen3 x16, no NVLink), Xeon E5-2680 v4, 62 GiB RAM, driver 580.178.04, CUDA 12.8
**Model artifact:** `Qwen3.8-Flash-Next-UD-IQ3_XXS` (Unsloth, 3 shards)

## Symptom

Generated text is letter/symbol garbage, but everything else looks healthy:

- output length correct, decode speed normal, VRAM usage normal
- it *does* respond to the prompt: with two different prompts the logits have cosine 0.198, i.e. they change
- the service never reports an error, and all bundled tests pass

## Root cause

`blk.1.ple_conv1d.weight` is stored as **F32** in this artifact, but is handed to the
F16 convolution kernel as raw bits:

```cpp
ss.ple.w.conv1d_f16 = (const uint16_t*) wc->data;
```

The kernel reads it with `__ushort_as_half`, so every weight becomes two garbage
half-precision numbers. The conv output comes out ~500x too large, residual #1 is
poisoned, and layers 2-47 then all build on a wrong residual.

Embedding, the hyper-connection mixer, the 48-layer backbone and `lm_head` are all
correct - which is exactly why the failure looks like an output-only problem.

## Why the bundled tests do not catch it

`ple_parity` and friends use **synthetic F16 weights**, so they never see that the file
is actually F32. Also, the v0.1.24 release tarball ships neither `ref/model.py` nor
`bench/micro/*_parity.cpp`, so "all tests green" is not evidence of numerical
correctness. (Related: `iq_parity` reports 10 failures out of the box because the
release has no Q3_K fixture - so the test suite is not self-checking here either.)

## Evidence

| Check | Result |
|---|---|
| `--tokens 760` ("The"), first output id | **20438**, matches llama.cpp `eval-callback` |
| `--tokens 760,6511,314,9338,369`, first output id | **11751** (" Paris"), matches |
| `token_embd`, `lm_head`, all 248320 logits | matches the reference (max abs diff 4.8e-6) |
| PLE intermediates (key/query/norm/gated/conv/value/gate/emb) | match the reference graph |
| the 11 parity tests | all pass |
| layer-split self-check (`--layer-split 24 --split-device 0`) | byte-identical to single-card output |
| 117,088-token needle retrieval | hit |

The per-layer / PLE-intermediate dump used to localise this is in the linked
repository (patch 04). With it the diagnosis was immediate: only `conv` was ~1000x
too large, everything else lined up.

## Suggested fix

Decide by the pack's `WeightKind` and byte count at load time instead of trusting the
pointer cast. For F32: copy back to the host, re-round element-wise through
`f16_from_f32`, upload. A startup line such as
`PLE conv1d re-rounded F32 -> fp16 (40960 taps)` makes it verifiable.

Note for anyone porting this: **check `kind` and `dst_bytes` in the pack index, not the
element type in the kernel header comment** - that comment was written for a different
artifact and was the source of the confusion.

## Questions

1. Does this affect the official GSQ-RCO quantisations too, or is it specific to
   artifacts whose `ple_conv1d.weight` is F32? I could not test the official shards.
2. Would you accept a PR for this? It is a small, self-contained load-time fix plus a
   log line, and I can add a parity case that uses an F32 weight so it cannot regress.

Full write-up, all four patches and the reproduction steps:
https://github.com/zipenghao/strata-v100-sm70

*Note: this report and the linked patches were drafted with AI assistance; every
finding above was reproduced and verified manually on the hardware listed.*
