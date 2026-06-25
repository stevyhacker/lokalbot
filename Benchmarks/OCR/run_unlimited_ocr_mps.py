#!/usr/bin/env python3
import argparse
import contextlib
import os
import time

import psutil
import torch
from transformers import AutoModel, AutoTokenizer


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--max-length", type=int, default=4096)
    parser.add_argument("--dtype", choices=["bfloat16", "float16", "float32"], default="bfloat16")
    parser.add_argument("--mode", choices=["gundam", "base"], default="gundam")
    return parser.parse_args()


def selected_dtype(name: str):
    return {
        "bfloat16": torch.bfloat16,
        "float16": torch.float16,
        "float32": torch.float32,
    }[name]


def install_cuda_to_mps_shim(device: str, dtype: torch.dtype):
    original_autocast = torch.autocast

    def tensor_cuda(self, device=None, non_blocking=False, memory_format=None):
        kwargs = {"non_blocking": non_blocking}
        if memory_format is not None:
            kwargs["memory_format"] = memory_format
        return self.to(device=device or selected_device, **kwargs)

    def module_cuda(self, device=None):
        return self.to(device=device or selected_device)

    def autocast(device_type, *args, **kwargs):
        if device_type == "cuda":
            if selected_device == "cpu":
                return contextlib.nullcontext()
            kwargs["dtype"] = dtype
            return original_autocast(selected_device, *args, **kwargs)
        return original_autocast(device_type, *args, **kwargs)

    selected_device = device
    torch.Tensor.cuda = tensor_cuda
    torch.nn.Module.cuda = module_cuda
    torch.autocast = autocast


def rss_mb():
    return psutil.Process(os.getpid()).memory_info().rss / (1024 * 1024)


def main():
    args = parse_args()
    os.makedirs(args.output_dir, exist_ok=True)

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    dtype = selected_dtype(args.dtype)
    install_cuda_to_mps_shim(device, dtype)

    start = time.perf_counter()
    tokenizer = AutoTokenizer.from_pretrained(
        args.model_dir,
        trust_remote_code=True,
        local_files_only=True,
    )
    model = AutoModel.from_pretrained(
        args.model_dir,
        trust_remote_code=True,
        use_safetensors=True,
        torch_dtype=dtype,
        low_cpu_mem_usage=True,
        local_files_only=True,
    )
    model = model.eval().to(device)
    load_seconds = time.perf_counter() - start
    load_rss = rss_mb()

    infer_start = time.perf_counter()
    crop_mode = args.mode == "gundam"
    image_size = 640 if crop_mode else 1024
    text = model.infer(
        tokenizer,
        prompt="<image>document parsing.",
        image_file=args.image,
        output_path=args.output_dir,
        base_size=1024,
        image_size=image_size,
        crop_mode=crop_mode,
        max_length=args.max_length,
        no_repeat_ngram_size=35,
        ngram_window=128,
        save_results=False,
        eval_mode=True,
    )
    infer_seconds = time.perf_counter() - infer_start
    infer_rss = rss_mb()

    image_id = os.path.splitext(os.path.basename(args.image))[0]
    output_path = os.path.join(args.output_dir, f"{image_id}.unlimited.txt")
    with open(output_path, "w", encoding="utf-8") as handle:
        handle.write(text or "")

    print(
        "device\tdtype\tmode\tload_s\tinfer_s\tchars\trss_after_load_mb\trss_after_infer_mb\toutput_path"
    )
    print(
        f"{device}\t{args.dtype}\t{args.mode}\t{load_seconds:.2f}\t{infer_seconds:.2f}\t"
        f"{len(text or '')}\t{load_rss:.1f}\t{infer_rss:.1f}\t{output_path}"
    )


if __name__ == "__main__":
    main()
