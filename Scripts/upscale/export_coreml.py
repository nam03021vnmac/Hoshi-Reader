#!/usr/bin/env python3
#
#  export_coreml.py
#  Hoshi Reader
#
#  Copyright © 2026 Manhhao.
#  SPDX-License-Identifier: GPL-3.0-or-later
#
#  Converts Real-ESRGAN animevideov3 (BSD-3-Clause, xinntao/Real-ESRGAN) to the fixed-tile Core ML
#  model bundled with the app. The network wrapper follows tools/qnn/export_models.py from
#  HaoweiLi97/mihon_img_upscale (Apache-2.0): the x4 network followed by a bilinear downscale to 2x.
#
#  Usage: Scripts/upscale/export_coreml.py [--out DIR]    (default: Scripts/upscale/build)
#
#  Output:
#    <out>/RealESRGANAnimeV3x2.mlpackage   256x256 RGB image in, 512x512 RGB image out, FP16
#    <out>/reference/                      a tile and the PyTorch output, for the harness comparison
#

import argparse
import hashlib
import urllib.request
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from PIL import Image
from torch import nn
from torch.nn import functional

WEIGHTS_URL = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth"
WEIGHTS_SHA256 = "b8a8376811077954d82ca3fcf476f1ac3da3e8a68a4f4d71363008000a18b75d"

TILE = 256
SCALE = 2
NUM_CONV = 16
MODEL_NAME = "RealESRGANAnimeV3x2"
REFERENCE_SEED = 20261107


class SRVGGNetCompact(nn.Module):
    def __init__(self, num_conv: int) -> None:
        super().__init__()
        layers: list[nn.Module] = [nn.Conv2d(3, 64, 3, 1, 1), nn.PReLU(num_parameters=64)]
        for _ in range(num_conv):
            layers.extend((nn.Conv2d(64, 64, 3, 1, 1), nn.PReLU(num_parameters=64)))
        layers.append(nn.Conv2d(64, 3 * 4 * 4, 3, 1, 1))
        self.body = nn.Sequential(*layers)

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        residual = functional.interpolate(image, scale_factor=4, mode="nearest")
        return functional.pixel_shuffle(self.body(image), 4) + residual


class Upscaler(nn.Module):
    """Takes and returns 0...255 so that both ends can be Core ML images."""

    def __init__(self, weights: Path) -> None:
        super().__init__()
        self.model = SRVGGNetCompact(NUM_CONV)
        checkpoint = torch.load(weights, map_location="cpu", weights_only=True)
        params = checkpoint.get("params_ema", checkpoint.get("params"))
        if params is None:
            raise RuntimeError(f"No params or params_ema weights in {weights}")
        self.model.load_state_dict(params, strict=True)

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        output = self.model(image / 255.0)
        output = functional.interpolate(output, scale_factor=SCALE / 4, mode="bilinear", align_corners=False)
        return torch.clamp(output, 0, 1) * 255.0


def fetch_weights(directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "realesr-animevideov3.pth"
    if not path.exists():
        print(f"Downloading {WEIGHTS_URL}")
        urllib.request.urlretrieve(WEIGHTS_URL, path)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != WEIGHTS_SHA256:
        path.unlink()
        raise RuntimeError(f"Checksum mismatch: {digest}")
    return path


def reference_tile() -> np.ndarray:
    """Line-art-like and screentone-like content, reproducible from the seed."""
    rng = np.random.default_rng(REFERENCE_SEED)
    y, x = np.mgrid[0:TILE, 0:TILE]
    tile = np.full((TILE, TILE), 255.0)
    tile[(x + y) % 6 < 2] = 170.0
    tile[:, TILE // 2 :] = 255.0
    tile[np.abs(y - x) < 3] = 0.0
    tile[np.abs(y + x - TILE) < 2] = 40.0
    tile += rng.normal(0, 4, tile.shape)
    gray = np.clip(tile, 0, 255).astype(np.uint8)
    return np.stack([gray] * 3, axis=-1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parent / "build")
    args = parser.parse_args()

    weights = fetch_weights(args.out / "weights")
    model = Upscaler(weights).eval()

    example = torch.zeros(1, 3, TILE, TILE)
    with torch.no_grad():
        traced = torch.jit.trace(model, example)

    converted = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        inputs=[ct.ImageType(name="input", shape=example.shape, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
    )
    converted.short_description = "Real-ESRGAN animevideov3, 2x, 256x256 tile"
    converted.license = "BSD-3-Clause (xinntao/Real-ESRGAN)"
    converted.version = "1"

    package = args.out / f"{MODEL_NAME}.mlpackage"
    if package.exists():
        import shutil

        shutil.rmtree(package)
    converted.save(str(package))

    reference = args.out / "reference"
    reference.mkdir(parents=True, exist_ok=True)
    tile = reference_tile()
    with torch.no_grad():
        tensor = torch.from_numpy(tile.astype(np.float32)).permute(2, 0, 1).unsqueeze(0)
        output = model(tensor)[0].permute(1, 2, 0).round().numpy().astype(np.uint8)
    Image.fromarray(tile).save(reference / "input.png")
    Image.fromarray(output).save(reference / "pytorch.png")

    print(f"Saved {package}")


if __name__ == "__main__":
    main()
