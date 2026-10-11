#!/usr/bin/env python3
#
#  reference.py
#  Hoshi Reader
#
#  Copyright © 2026 Manhhao.
#  SPDX-License-Identifier: GPL-3.0-or-later
#
#  Reference implementation of the on-device OCR pipeline (Features/PDFReader/OCR) with
#  onnxruntime. Same pre/post-processing and the same params.json, so it can produce golden
#  outputs and catch channel order or normalisation bugs in the Swift port. Keep in sync.
#
#  Usage:
#    reference.py run PACK_DIR IMAGE_OR_PDF [--page N] [--json OUT]
#    reference.py eval PACK_DIR FIXTURES_DIR                  accuracy against <name>.p<N>.txt
#    reference.py compare SWIFT.json REFERENCE.json           Swift port vs this script
#

import argparse
import json
import math
import sys
import time
from collections import deque
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image

RENDER_LONG_SIDE = 2048
# batch size × padded width cap (CTCConfig.maxBatchWidth)
REC_MAX_BATCH_WIDTH = 4096


class Pack:
    def __init__(self, directory, overrides=()):
        directory = Path(directory)
        self.params = json.loads((directory / "params.json").read_text(encoding="utf-8"))
        for override in overrides:  # e.g. det.unclipRatio=1.8, for tuning
            key, value = override.split("=", 1)
            section, name = key.split(".", 1)
            self.params[section][name] = json.loads(value)
        data = (directory / "dict.txt").read_bytes()
        self.characters = [line.decode("utf-8") for line in data.split(b"\n")[:-1]]
        options = ort.SessionOptions()
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        options.intra_op_num_threads = 2
        self.det = ort.InferenceSession(str(directory / "det.onnx"), options, providers=["CPUExecutionProvider"])
        self.rec = ort.InferenceSession(str(directory / "rec.onnx"), options, providers=["CPUExecutionProvider"])


def resize(image, width, height):
    """Bilinear with OpenCV's INTER_LINEAR sampling (no antialiasing), like PaddleOCR. Same as PixelImage.resized."""
    if image.size == (width, height):
        return image
    pixels = np.asarray(image, dtype=np.float32)
    src_h, src_w = pixels.shape[:2]

    def samples(count, source):
        position = np.clip((np.arange(count) + 0.5) * (source / count) - 0.5, 0, source - 1)
        lower = position.astype(np.int64)
        return lower, np.minimum(lower + 1, source - 1), (position - lower).astype(np.float32)

    x0, x1, wx = samples(width, src_w)
    y0, y1, wy = samples(height, src_h)
    wx = wx[None, :, None]
    wy = wy[:, None, None]
    top = pixels[y0][:, x0] * (1 - wx) + pixels[y0][:, x1] * wx
    bottom = pixels[y1][:, x0] * (1 - wx) + pixels[y1][:, x1] * wx
    return Image.fromarray(np.floor(top * (1 - wy) + bottom * wy + 0.5).astype(np.uint8))


def to_tensor(image, order, scale, mean, std):
    """RGB uint8 HxWx3 -> float32 3xHxW in the model's channel order."""
    pixels = np.asarray(image, dtype=np.float32)
    channels = [2, 1, 0] if order == "BGR" else [0, 1, 2]
    out = np.empty((3,) + pixels.shape[:2], np.float32)
    for c, source in enumerate(channels):
        out[c] = (pixels[:, :, source] * scale - mean[c]) / std[c]
    return out


# MARK: detection

def detect(pack, image):
    p = pack.params["det"]
    width, height = image.size
    ratio = min(1.0, p["limitSideLen"] / max(width, height))
    resized_w = max(32, int(round(width * ratio / 32)) * 32)
    resized_h = max(32, int(round(height * ratio / 32)) * 32)
    resized = resize(image, resized_w, resized_h)
    x = to_tensor(resized, p["channelOrder"], p["scale"], p["mean"], p["std"])[None]
    prob = pack.det.run(None, {pack.det.get_inputs()[0].name: x})[0][0, 0]
    return db_boxes(prob, p, width / resized_w, height / resized_h, width, height)


def db_boxes(prob, p, scale_x, scale_y, width, height):
    map_h, map_w = prob.shape
    bitmap = prob > p["thresh"]
    seen = np.zeros_like(bitmap)
    boxes = []
    ys, xs = np.nonzero(bitmap)
    for start_y, start_x in zip(ys, xs):  # row-major, same discovery order as Swift
        if seen[start_y, start_x]:
            continue
        seen[start_y, start_x] = True
        queue = deque([(start_y, start_x)])
        min_x = max_x = start_x
        min_y = max_y = start_y
        while queue:
            y, x = queue.popleft()
            min_x, max_x = min(min_x, x), max(max_x, x)
            min_y, max_y = min(min_y, y), max(max_y, y)
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < map_h and 0 <= nx < map_w and bitmap[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        queue.append((ny, nx))
        w = max_x - min_x + 1
        h = max_y - min_y + 1
        if min(w, h) < p["minSize"]:
            continue
        score = float(prob[min_y:max_y + 1, min_x:max_x + 1].mean())
        if score < p["boxThresh"]:
            continue
        d = w * h * p["unclipRatio"] / (2 * (w + h))
        if min(w, h) + 2 * d < p["minSize"] + 2:
            continue
        x0 = max(0.0, (min_x - d) * scale_x)
        y0 = max(0.0, (min_y - d) * scale_y)
        x1 = min(float(width), (max_x + 1 + d) * scale_x)
        y1 = min(float(height), (max_y + 1 + d) * scale_y)
        boxes.append((x0, y0, x1, y1, score))
        if len(boxes) >= p["maxCandidates"]:
            break
    return boxes


# MARK: recognition

def recognize(pack, image, boxes):
    p = pack.params["rec"]
    rec_h = p["imageHeight"]
    crops = []
    for box in boxes:
        x0, y0 = math.floor(box[0]), math.floor(box[1])
        x1, y1 = math.ceil(box[2]), math.ceil(box[3])
        if x1 - x0 < 1 or y1 - y0 < 1:
            continue
        crop = image.crop((x0, y0, x1, y1))
        vertical = (y1 - y0) >= 1.5 * (x1 - x0)
        strip = crop.transpose(Image.Transpose.ROTATE_90) if vertical else crop  # counter-clockwise
        resized_w = max(1, min(math.ceil(rec_h * strip.width / strip.height), p["maxWidth"]))
        crops.append({"rect": (x0, y0, x1, y1), "vertical": vertical, "strip": strip, "resized_w": resized_w})

    order = sorted(range(len(crops)), key=lambda i: crops[i]["strip"].width / crops[i]["strip"].height)
    lines = [None] * len(crops)

    def padded_width(widths):
        return min(max(p["minWidth"], (max(widths) + 7) // 8 * 8), p["maxWidth"])

    batches, current = [], []
    for i in order:
        widths = [crops[j]["resized_w"] for j in current + [i]]
        if current and (len(current) == p["batchSize"] or len(widths) * padded_width(widths) > REC_MAX_BATCH_WIDTH):
            batches.append(current)
            current = []
        current.append(i)
    if current:
        batches.append(current)

    for batch in batches:
        padded_w = padded_width([crops[i]["resized_w"] for i in batch])
        x = np.zeros((len(batch), 3, rec_h, padded_w), np.float32)
        for row, i in enumerate(batch):
            resized = resize(crops[i]["strip"], crops[i]["resized_w"], rec_h)
            x[row, :, :, :crops[i]["resized_w"]] = to_tensor(resized, p["channelOrder"], p["scale"], p["mean"], p["std"])
        out = pack.rec.run(None, {pack.rec.get_inputs()[0].name: x})[0]
        for row, i in enumerate(batch):
            lines[i] = decode_line(pack, out[row], padded_w, crops[i])
    return [line for line in lines if line is not None]


def ctc_decode(probs, valid_t, characters, use_space):
    """Greedy CTC. Returns [(character, t_start, t_end, prob_at_start)]."""
    best = probs[:valid_t].argmax(-1)
    best_p = probs[:valid_t].max(-1)
    space_index = probs.shape[-1] - 1 if use_space else -1
    result = []
    previous = 0
    for t, k in enumerate(best):
        k = int(k)
        if k != 0 and k == previous and result:
            result[-1][2] = t
        elif k != 0:
            character = " " if k == space_index else characters[k - 1] if k - 1 < len(characters) else ""
            result.append([character, t, t, float(best_p[t])])
        previous = k
    return [tuple(r) for r in result if r[0]]


def is_fullwidth(character):
    code = ord(character[0])
    if 0xFF61 <= code <= 0xFF9F:
        return False
    return code >= 0x2E80 or 0x3000 <= code <= 0x30FF


def glyph_spans(chars, stride, valid_w):
    """Strip x-ranges for each decoded character."""
    centers = [(start + end + 1) / 2 * stride for _, start, end, _ in chars]
    n = len(centers)
    if n == 1:
        return [(0.0, float(valid_w))]
    spacing = float(np.median(np.diff(centers)))
    first = max(0.0, centers[0] - spacing / 2)
    last = min(float(valid_w), centers[-1] + spacing / 2)
    if all(is_fullwidth(c[0]) for c in chars):
        cell = (last - first) / n
        return [(first + i * cell, first + (i + 1) * cell) for i in range(n)]
    bounds = [first] + [(centers[i] + centers[i + 1]) / 2 for i in range(n - 1)] + [last]
    return [(bounds[i], bounds[i + 1]) for i in range(n)]


def decode_line(pack, probs, padded_w, crop):
    p = pack.params["rec"]
    steps = probs.shape[0]
    valid_t = min(steps, math.ceil(steps * crop["resized_w"] / padded_w))
    chars = ctc_decode(probs, valid_t, pack.characters, p["useSpaceChar"])
    if not chars:
        return None
    confidence = float(np.mean([c[3] for c in chars]))
    text = "".join(c[0] for c in chars)
    if confidence < 0.5 or not text.strip():
        return None
    stride = padded_w / steps
    x0, y0, x1, y1 = crop["rect"]
    along = (y1 - y0) if crop["vertical"] else (x1 - x0)
    factor = along / crop["resized_w"]
    glyphs = []
    for (character, _, _, _), (s0, s1) in zip(chars, glyph_spans(chars, stride, crop["resized_w"])):
        if character == " ":
            continue
        if crop["vertical"]:
            glyphs.append({"c": character, "r": [x0, y0 + s0 * factor, x1, y0 + s1 * factor]})
        else:
            glyphs.append({"c": character, "r": [x0 + s0 * factor, y0, x0 + s1 * factor, y1]})
    return {"box": list(crop["rect"]), "vertical": crop["vertical"], "text": text, "confidence": confidence, "glyphs": glyphs}


# MARK: pipeline

def load_image(path, page):
    path = Path(path)
    if path.suffix.lower() == ".pdf":
        import pypdfium2
        pdf_page = pypdfium2.PdfDocument(str(path))[page]
        width, height = pdf_page.get_size()
        if pdf_page.get_rotation() in (90, 270):
            width, height = height, width
        return pdf_page.render(scale=RENDER_LONG_SIDE / max(width, height)).to_pil().convert("RGB")
    return Image.open(path).convert("RGB")


def run(pack, image):
    t0 = time.perf_counter()
    boxes = detect(pack, image)
    t1 = time.perf_counter()
    lines = recognize(pack, image, boxes)
    t2 = time.perf_counter()
    return {
        "width": image.width,
        "height": image.height,
        "timings": {"det": round((t1 - t0) * 1000), "rec": round((t2 - t1) * 1000)},
        "lines": lines,
    }


def reading_order_text(result):
    """Minimal port of LayoutAnalyzer for evaluation: drop ruby, order tiers and columns."""
    lines = result["lines"]
    if not lines:
        return ""

    def thickness(line):
        x0, y0, x1, y1 = line["box"]
        return (x1 - x0) if line["vertical"] else (y1 - y0)

    vertical_count = sum(len(l["text"]) for l in lines if l["vertical"])
    vertical = vertical_count * 2 > sum(len(l["text"]) for l in lines)
    # weighted by glyph count, so pages with many short ruby lines still find the body text size
    thick = sorted((thickness(l), len(l["text"])) for l in lines if len(l["text"]) >= 3)
    half = sum(count for _, count in thick) / 2
    median = 0
    for value, count in thick:
        median = value
        half -= count
        if half <= 0:
            break
    main = [l for l in lines if thickness(l) >= 0.6 * median]

    parent = list(range(len(main)))

    def find(i):
        while parent[i] != i:
            i = parent[i]
        return i

    for i in range(len(main)):
        for j in range(i + 1, len(main)):
            a, b = main[i]["box"], main[j]["box"]
            if vertical:
                overlap = min(a[3], b[3]) - max(a[1], b[1])
                shorter = min(a[3] - a[1], b[3] - b[1])
            else:
                overlap = min(a[2], b[2]) - max(a[0], b[0])
                shorter = min(a[2] - a[0], b[2] - b[0])
            if overlap > 0.5 * shorter:
                parent[find(i)] = find(j)
    groups = {}
    for i in range(len(main)):
        groups.setdefault(find(i), []).append(main[i])

    def center(line, axis):
        return (line["box"][axis] + line["box"][axis + 2]) / 2

    ordered = sorted(groups.values(), key=lambda g: min(center(l, 1) for l in g) if vertical else min(center(l, 0) for l in g))
    text = ""
    for group in ordered:
        group.sort(key=lambda l: -center(l, 0) if vertical else center(l, 1))
        text += "".join(l["text"] for l in group)
    return text


def edit_distance(a, b):
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def accuracy(predicted, truth):
    if not truth:
        return 1.0 if not predicted else 0.0
    return max(0.0, 1 - edit_distance(predicted, truth) / len(truth))


# MARK: commands

def command_run(args):
    pack = Pack(args.pack, args.set)
    result = run(pack, load_image(args.input, args.page))
    if args.json:
        Path(args.json).write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    for line in result["lines"]:
        box = ", ".join(f"{v:.0f}" for v in line["box"])
        print(f"[{box}] {'V' if line['vertical'] else 'H'} {line['confidence']:.2f} {line['text']}")
    print(f"det {result['timings']['det']} ms, rec {result['timings']['rec']} ms")
    print("reading order:", reading_order_text(result))


def command_eval(args):
    pack = Pack(args.pack, args.set)
    fixtures = Path(args.fixtures)
    total_errors = total_length = 0
    for truth_path in sorted(fixtures.glob("*.p*.txt")):
        name, page = truth_path.name.rsplit(".p", 1)
        page = int(page.removesuffix(".txt")) - 1
        truth = "".join(truth_path.read_text(encoding="utf-8").split())
        result = run(pack, load_image(fixtures / f"{name}.pdf", page))
        predicted = "".join(reading_order_text(result).split())
        errors = edit_distance(predicted, truth)
        total_errors += errors
        total_length += len(truth)
        print(f"{name} p{page + 1}: {accuracy(predicted, truth) * 100:.1f}% ({errors} errors / {len(truth)} chars), "
              f"det {result['timings']['det']} ms, rec {result['timings']['rec']} ms")
        if args.verbose:
            print("  truth:    ", truth)
            print("  predicted:", predicted)
    if total_length:
        print(f"overall: {(1 - total_errors / total_length) * 100:.1f}%")


def command_compare(args):
    swift = json.loads(Path(args.swift).read_text(encoding="utf-8"))
    reference = json.loads(Path(args.reference).read_text(encoding="utf-8"))

    def iou(a, b):
        ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
        iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
        inter = ix * iy
        union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
        return inter / union if union > 0 else 0

    errors = length = 0
    max_delta = 0.0
    unmatched = 0
    for ref in reference["lines"]:
        best = max(swift["lines"], key=lambda s: iou(s["box"], ref["box"]), default=None)
        if best is None or iou(best["box"], ref["box"]) < 0.5:
            unmatched += 1
            errors += len(ref["text"])
            length += len(ref["text"])
            continue
        errors += edit_distance(best["text"], ref["text"])
        length += len(ref["text"])
        max_delta = max(max_delta, max(abs(a - b) for a, b in zip(best["box"], ref["box"])))
    print(f"lines: swift {len(swift['lines'])}, reference {len(reference['lines'])}, unmatched {unmatched}")
    print(f"character agreement: {(1 - errors / max(length, 1)) * 100:.2f}%")
    print(f"max box delta: {max_delta:.1f} px")


def main():
    ort.set_default_logger_severity(3)
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p_run = sub.add_parser("run")
    p_run.add_argument("pack")
    p_run.add_argument("input")
    p_run.add_argument("--page", type=int, default=0)
    p_run.add_argument("--json")
    p_run.add_argument("--set", action="append", default=[], help="override a params.json value, e.g. det.unclipRatio=1.8")
    p_eval = sub.add_parser("eval")
    p_eval.add_argument("pack")
    p_eval.add_argument("fixtures")
    p_eval.add_argument("--verbose", action="store_true")
    p_eval.add_argument("--set", action="append", default=[], help="override a params.json value, e.g. det.unclipRatio=1.8")
    p_compare = sub.add_parser("compare")
    p_compare.add_argument("swift")
    p_compare.add_argument("reference")
    args = parser.parse_args()
    {"run": command_run, "eval": command_eval, "compare": command_compare}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
