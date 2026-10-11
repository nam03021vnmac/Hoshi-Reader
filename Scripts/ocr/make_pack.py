#!/usr/bin/env python3
#
#  make_pack.py
#  Hoshi Reader
#
#  Copyright © 2026 Manhhao.
#  SPDX-License-Identifier: GPL-3.0-or-later
#
#  Assembles one OCR model pack (det.onnx, rec.onnx, dict.txt, params.json) from PaddleOCR
#  ONNX exports and their inference.yml files. Called by fetch_models.sh.
#
#  Usage: make_pack.py --det-dir DIR --rec-dir DIR --name ppocrv6-small --out OUT_DIR
#

import argparse
import json
import shutil
import sys
from pathlib import Path

import numpy as np
import onnxruntime as ort
import yaml

# Limits we choose for on-device use; everything else comes from inference.yml
DET_LIMIT_SIDE_LEN = 1536
DET_MAX_CANDIDATES = 300
REC_MAX_WIDTH = 3200
REC_BATCH_SIZE = 6


def find_op(ops, name):
    for op in ops:
        if name in op:
            return op[name] or {}
    return None


def det_params(config):
    ops = config["PreProcess"]["transform_ops"]
    decode = find_op(ops, "DecodeImage") or {}
    normalize = find_op(ops, "NormalizeImage") or {}
    post = config["PostProcess"]
    scale = normalize.get("scale", "1./255.")
    if isinstance(scale, str):
        numerator, denominator = scale.split("/")  # "1./255." in every PaddleOCR config
        scale = float(numerator) / float(denominator)
    if normalize.get("order", "hwc") != "hwc":
        sys.exit("unexpected NormalizeImage order")
    return {
        "limitSideLen": DET_LIMIT_SIDE_LEN,
        "channelOrder": decode.get("img_mode", "BGR"),
        "scale": float(scale),
        "mean": [float(v) for v in normalize["mean"]],
        "std": [float(v) for v in normalize["std"]],
        "thresh": float(post["thresh"]),
        "boxThresh": float(post["box_thresh"]),
        "unclipRatio": float(post["unclip_ratio"]),
        "maxCandidates": min(int(post.get("max_candidates", DET_MAX_CANDIDATES)), DET_MAX_CANDIDATES),
        "minSize": 3,
    }


def rec_params(config, classes, dict_count):
    ops = config["PreProcess"]["transform_ops"]
    decode = find_op(ops, "DecodeImage") or {}
    resize = find_op(ops, "RecResizeImg") or {}
    _, height, width = resize.get("image_shape", [3, 48, 320])
    if classes == dict_count + 2:
        use_space = True
    elif classes == dict_count + 1:
        use_space = False
    else:
        sys.exit(f"rec output has {classes} classes, dictionary has {dict_count} entries")
    return {
        "imageHeight": int(height),
        "minWidth": int(width),
        "maxWidth": REC_MAX_WIDTH,
        "channelOrder": decode.get("img_mode", "BGR"),
        # RecResizeImg normalises to [-1, 1]; this isn't spelled out in inference.yml
        "scale": 1 / 255,
        "mean": [0.5, 0.5, 0.5],
        "std": [0.5, 0.5, 0.5],
        "useSpaceChar": use_space,
        "batchSize": REC_BATCH_SIZE,
    }


def check_det(path):
    session = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    out = session.run(None, {session.get_inputs()[0].name: np.random.rand(1, 3, 64, 96).astype(np.float32)})[0]
    if out.shape[:2] != (1, 1) or out.min() < 0 or out.max() > 1:
        sys.exit(f"det output isn't a [1, 1, H, W] probability map: {out.shape}, [{out.min()}, {out.max()}]")


def rec_classes(path):
    session = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    out = session.run(None, {session.get_inputs()[0].name: np.zeros((1, 3, 48, 320), np.float32)})[0]
    if out.ndim != 3 or not np.allclose(out.sum(-1), 1, atol=1e-3):
        sys.exit(f"rec output isn't [N, T, C] softmax: {out.shape}")
    return out.shape[-1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--det-dir", required=True, type=Path)
    parser.add_argument("--rec-dir", required=True, type=Path)
    parser.add_argument("--name", required=True)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    ort.set_default_logger_severity(3)
    det_config = yaml.safe_load((args.det_dir / "inference.yml").read_text())
    rec_config = yaml.safe_load((args.rec_dir / "inference.yml").read_text())

    characters = rec_config["PostProcess"]["character_dict"]
    for c in characters:
        if not isinstance(c, str) or "\n" in c or "\r" in c or c == "":
            sys.exit(f"dictionary entry can't be written one per line: {c!r}")

    check_det(args.det_dir / "inference.onnx")
    classes = rec_classes(args.rec_dir / "inference.onnx")

    pack = args.out / args.name
    pack.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.det_dir / "inference.onnx", pack / "det.onnx")
    shutil.copyfile(args.rec_dir / "inference.onnx", pack / "rec.onnx")
    with open(pack / "dict.txt", "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(c + "\n" for c in characters))
    params = {
        "model": det_config["Global"]["model_name"].removesuffix("_det"),
        "det": det_params(det_config),
        "rec": rec_params(rec_config, classes, len(characters)),
    }
    (pack / "params.json").write_text(json.dumps(params, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"{args.name}: {len(characters)} characters, {classes} classes")


if __name__ == "__main__":
    main()
