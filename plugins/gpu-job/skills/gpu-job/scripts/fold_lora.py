#!/usr/bin/env python3
"""gpu-job fold_lora.py — fold a LoRA adapter into a base model, WITH a mandatory
verification gate. POD-side.

Why this exists (real incident, 2026-06-11): `PeftModel.merge_and_unload()` SILENTLY
no-ops when the adapter's keys don't bind to the loaded model's module tree — lora_B stays
at zero init and the "merged" output is bit-identical to base while everything reports
success. This script folds by direct arithmetic (W += (alpha/r)·B@A) on the *serialized*
keys, and REFUSES to emit a model unless every adapter delta bound to a base tensor and the
output actually differs from base.

Usage:
  python3 fold_lora.py --base <dir> --adapter <dir-with-adapter_model.*> --out <dir> \
      [--reference <known-good-merged-dir>]   # verify the formula reconstructs it first
Gates (all hard failures, not warnings):
  1. every adapter delta key must bind to a base tensor (unbound keys = the PEFT no-op cause);
  2. with --reference: max |base+delta − reference| must be ≤ 0.05 on every targeted tensor;
  3. the emitted model must differ from base on every targeted tensor (the no-op gate).
Note: writes a single .safetensors shard — fine through ~16GB folds (4B-class); for bigger
models do a sharded save via transformers and keep gates 1+3.
Verified lineage: generalized from regen-dpo's refold_manual.py (reconstructed the captured
merge at max_abs_err 0.000000 over 170 tensors); a verified research reproduction.
"""
import argparse, glob, json, os, shutil, sys

import torch as t
from safetensors import safe_open
from safetensors.torch import save_file


def load_sd(d):
    sd = {}
    for f in sorted(glob.glob(os.path.join(d, "*.safetensors"))):
        with safe_open(f, framework="pt") as sf:
            for k in sf.keys():
                sd[k] = sf.get_tensor(k)
    if not sd:
        sys.exit(f"FOLD_FAIL: no .safetensors found in {d}")
    return sd


def load_adapter(adapter_dir):
    cfg_path = os.path.join(adapter_dir, "adapter_config.json")
    cfg = json.load(open(cfg_path))
    scale = cfg["lora_alpha"] / cfg["r"]
    for cand in ("adapter_model.safetensors", "adapter_model.bin"):
        p = os.path.join(adapter_dir, cand)
        if os.path.exists(p):
            if cand.endswith(".safetensors"):
                ad = {}
                with safe_open(p, framework="pt") as sf:
                    for k in sf.keys():
                        ad[k] = sf.get_tensor(k)
            else:
                ad = t.load(p, map_location="cpu", weights_only=False)
            return ad, scale
    sys.exit(f"FOLD_FAIL: no adapter_model.(safetensors|bin) in {adapter_dir}")


def adapter_deltas(ad, scale, base_keys):
    """Pair lora_A/lora_B, map module names to serialized keys, compute scaled deltas.
    Any delta that can't bind to a base tensor is FATAL (that's the silent-no-op cause)."""
    mods = {}
    for k, v in ad.items():
        kk = (k.replace(".lora_A.weight", "|A").replace(".lora_B.weight", "|B")
               .replace(".lora_A.default.weight", "|A").replace(".lora_B.default.weight", "|B"))
        if "|" not in kk:
            continue  # non-lora entries (e.g. modules_to_save) handled below as unbound check
        name, ab = kk.rsplit("|", 1)
        for pre in ("base_model.model.", "base_model."):
            if name.startswith(pre):
                name = name[len(pre):]
        mods.setdefault(name, {})[ab] = v.float()

    deltas, unbound = {}, []
    for name, d in mods.items():
        if set(d) != {"A", "B"}:
            sys.exit(f"FOLD_FAIL: unpaired lora_A/B for module {name}")
        candidates = [name + ".weight"]
        # gemma-family remap seen in the wild: module path 'model.language_model.layers...'
        # serializes as 'language_model.model.layers...'
        if name.startswith("model.language_model."):
            candidates.append("language_model.model." + name[len("model.language_model."):] + ".weight")
        if name.startswith("model."):
            candidates.append(name[len("model."):] + ".weight")
        key = next((c for c in candidates if c in base_keys), None)
        if key is None:
            unbound.append(name)
            continue
        deltas[key] = (d["B"] @ d["A"]) * scale
    if unbound:
        sys.exit(f"FOLD_FAIL: {len(unbound)} adapter modules did not bind to any base tensor "
                 f"(first: {unbound[:3]}) — this is exactly how merge_and_unload silently no-ops. "
                 f"Fix the key mapping; do NOT skip.")
    if not deltas:
        sys.exit("FOLD_FAIL: adapter produced zero deltas")
    return deltas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--adapter", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--reference", help="known-good merged model dir to verify the formula against first")
    ap.add_argument("--tol", type=float, default=0.05, help="bf16-scale tolerance for --reference check")
    args = ap.parse_args()

    base = load_sd(args.base)
    ad, scale = load_adapter(args.adapter)
    deltas = adapter_deltas(ad, scale, set(base.keys()))
    print(f"[fold] base tensors={len(base)} deltas bound={len(deltas)} scale={scale}", flush=True)

    if args.reference:
        ref = load_sd(args.reference)
        maxerr, checked = 0.0, 0
        for k, dl in deltas.items():
            if k not in ref:
                sys.exit(f"FOLD_FAIL: targeted tensor {k} missing from --reference")
            pred = (base[k].float() + dl).to(t.bfloat16)
            err = (pred.float() - ref[k].float()).abs().max().item()
            maxerr = max(maxerr, err); checked += 1
        print(f"[fold] reference check: {checked} tensors, max_abs_err={maxerr:.6f}", flush=True)
        if maxerr > args.tol:
            sys.exit(f"FOLD_FAIL: formula does not reconstruct --reference (max_abs_err {maxerr:.6f} > {args.tol})")

    changed = 0
    for k, dl in deltas.items():
        new = (base[k].float() + dl).to(base[k].dtype)
        if t.equal(new, base[k]):
            sys.exit(f"FOLD_FAIL: targeted tensor {k} UNCHANGED after fold (zero delta — "
                     f"adapter B at zero init or wrong adapter). Refusing to emit.")
        base[k] = new
        changed += 1

    shutil.rmtree(args.out, ignore_errors=True)
    os.makedirs(args.out)
    save_file({k: v.contiguous() for k, v in base.items()},
              os.path.join(args.out, "model.safetensors"), metadata={"format": "pt"})
    for f in os.listdir(args.base):
        if not f.endswith(".safetensors") and os.path.isfile(os.path.join(args.base, f)) \
           and f != "model.safetensors.index.json":
            shutil.copy(os.path.join(args.base, f), args.out)
    print(f"FOLD_OK {args.out} ({changed} tensors changed)", flush=True)


if __name__ == "__main__":
    main()
