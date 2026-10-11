#!/usr/bin/env bash
#
#  fetch_models.sh
#  Hoshi Reader
#
#  Copyright © 2026 Manhhao.
#  SPDX-License-Identifier: GPL-3.0-or-later
#
#  Downloads the pinned PaddleOCR ONNX models and the manga recognizer from Hugging Face, verifies
#  them, and assembles the model packs the app downloads (det.onnx, rec.onnx, dict.txt, params.json).
#
#  Usage: Scripts/ocr/fetch_models.sh [out_dir]          (default: Scripts/ocr/build)
#
#  Output:
#    <out>/<pack>/...            one directory per pack, usable as a local dev drop-in
#    <out>/release/<pack>-<file> flat copies, in case the packs are ever self-hosted
#    Features/PDFReader/OCR/Packs/<pack>-{dict.txt,params.json}, bundled with the app (the app
#      downloads det/rec straight from the pinned Hugging Face commits below)
#    a Swift snippet for OCRModelManifest with every file's size and SHA-256
#
#  If the official ONNX exports ever disappear, export them from the Paddle inference models:
#    pip install "paddlepaddle>=3.0" "paddleocr>=3.7" paddle2onnx
#    paddle2onnx --model_dir <model>_infer --model_filename inference.json \
#                --params_filename inference.pdiparams --save_file inference.onnx --opset_version 14
#  and keep the inference.yml next to it.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$SCRIPT_DIR/build}"
VENV="$SCRIPT_DIR/.venv"
CACHE="$OUT/hf"

# repo|revision|sha256 of inference.onnx
MODELS=(
    "PP-OCRv6_small_det_onnx|28fe5895c24fd108c19eb3e8479f4ab385fbfc62|d73e0058b7a8086bbd57f3d10b8bcd4ff95363f67e06e2762b5e814fe9c9410e"
    "PP-OCRv6_small_rec_onnx|b8f84f0b80c529de40b4fbb3544b84fa7233a513|5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634"
)

# Kellenok's manga fine-tune of the PP-OCRv6 small recognizer (Apache-2.0), file|revision|sha256.
# The repo has no inference.yml, but preprocessing and dictionary match PP-OCRv6_small_rec, so the
# pack reuses that one.
MANGA_REC="rec/manga_rec_v0.2.onnx|8ee29e094b6aac77dd067c70805438782fa16ab0|de12c84c63e62c80339e882e675983d886670dcb6f0147e1ed041afd6fa81888"

# pack|det dir|rec dir[|model name]
PACKS=(
    "ppocrv6-small|PP-OCRv6_small_det_onnx|PP-OCRv6_small_rec_onnx"
    "ppocrv6-manga|PP-OCRv6_small_det_onnx|PP-OCRv6_manga_rec|PP-OCRv6_manga"
)

if [ ! -x "$VENV/bin/python" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet -r "$SCRIPT_DIR/requirements.txt"
fi

mkdir -p "$CACHE"
for entry in "${MODELS[@]}"; do
    IFS="|" read -r repo revision sha <<< "$entry"
    dir="$CACHE/$repo"
    mkdir -p "$dir"
    for file in inference.onnx inference.yml; do
        if [ ! -f "$dir/$file" ]; then
            echo "downloading $repo/$file"
            curl --fail --location --silent --show-error \
                "https://huggingface.co/PaddlePaddle/$repo/resolve/$revision/$file" -o "$dir/$file.part"
            mv "$dir/$file.part" "$dir/$file"
        fi
    done
    actual="$(shasum -a 256 "$dir/inference.onnx" | cut -d' ' -f1)"
    if [ "$actual" != "$sha" ]; then
        echo "checksum mismatch for $repo: $actual" >&2
        exit 1
    fi
done

IFS="|" read -r file revision sha <<< "$MANGA_REC"
dir="$CACHE/PP-OCRv6_manga_rec"
mkdir -p "$dir"
if [ ! -f "$dir/inference.onnx" ]; then
    echo "downloading Kellenok/PP-OCRv6_manga/$file"
    curl --fail --location --silent --show-error \
        "https://huggingface.co/Kellenok/PP-OCRv6_manga/resolve/$revision/$file" -o "$dir/inference.onnx.part"
    mv "$dir/inference.onnx.part" "$dir/inference.onnx"
fi
actual="$(shasum -a 256 "$dir/inference.onnx" | cut -d' ' -f1)"
if [ "$actual" != "$sha" ]; then
    echo "checksum mismatch for PP-OCRv6_manga/$file: $actual" >&2
    exit 1
fi
cp "$CACHE/PP-OCRv6_small_rec_onnx/inference.yml" "$dir/inference.yml"

mkdir -p "$OUT/release"
for entry in "${PACKS[@]}"; do
    IFS="|" read -r pack det rec model <<< "$entry"
    "$VENV/bin/python" -I "$SCRIPT_DIR/make_pack.py" --det-dir "$CACHE/$det" --rec-dir "$CACHE/$rec" --name "$pack" --out "$OUT" \
        ${model:+--model "$model"}
    for file in det.onnx rec.onnx dict.txt params.json; do
        cp "$OUT/$pack/$file" "$OUT/release/$pack-$file"
    done
    for file in dict.txt params.json; do
        cp "$OUT/$pack/$file" "$SCRIPT_DIR/../../Features/PDFReader/OCR/Packs/$pack-$file"
    done
done

echo
echo "// OCRModelManifest entries"
for entry in "${PACKS[@]}"; do
    IFS="|" read -r pack _ _ <<< "$entry"
    echo "// $pack"
    for file in det.onnx rec.onnx dict.txt params.json; do
        path="$OUT/$pack/$file"
        size="$(stat -f %z "$path" 2>/dev/null || stat -c %s "$path")"
        sha="$(shasum -a 256 "$path" | cut -d' ' -f1)"
        echo "(\"$file\", \"$sha\", $size),"
    done
done
