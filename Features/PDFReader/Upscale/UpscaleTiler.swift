//
//  UpscaleTiler.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Tile geometry follows float_tile_processor.h from HaoweiLi97/mihon_img_upscale (Apache-2.0).
//

import Foundation

nonisolated protocol UpscaleTileModel {
    /// Both buffers are tightly packed BGRA
    func run(input: UnsafePointer<UInt8>, output: UnsafeMutablePointer<UInt8>) throws
}

nonisolated enum UpscaleError: Error {
    case modelMissing
    case modelOutput
    case corruptOutput
    case render
    case encode
}

nonisolated struct UpscaleTile: Equatable, Sendable {
    /// Top left of the model's input window in page pixels, past the page's edge when it needs mirrored context
    let originX: Int
    let originY: Int
    /// The part of the page this tile produces
    let coreX: Int
    let coreY: Int
    let coreWidth: Int
    let coreHeight: Int
}

nonisolated struct UpscaleTiler: Sendable {
    /// animevideov3's 18 3x3 convolutions see exactly 18 pixels around each pixel, so a core cropped with this padding has no seams
    static let animeV3 = UpscaleTiler(inputSize: 256, padding: 18, scale: 2)

    /// A wrong model output is far off the input's brightness, real output stays close to it
    private static let maxMeanDifference = 48

    let inputSize: Int
    let padding: Int
    let scale: Int

    var coreSize: Int {
        inputSize - 2 * padding
    }

    func tiles(width: Int, height: Int) -> [UpscaleTile] {
        guard width > 0, height > 0 else {
            return []
        }
        var tiles: [UpscaleTile] = []
        for y in stride(from: 0, to: height, by: coreSize) {
            for x in stride(from: 0, to: width, by: coreSize) {
                tiles.append(UpscaleTile(
                    originX: origin(start: x, length: width),
                    originY: origin(start: y, length: height),
                    coreX: x,
                    coreY: y,
                    coreWidth: min(coreSize, width - x),
                    coreHeight: min(coreSize, height - y)
                ))
            }
        }
        return tiles
    }

    /// Windows only reach `padding` past the page, the last one slides back instead of mirroring more.
    private func origin(start: Int, length: Int) -> Int {
        if length <= coreSize {
            return -(inputSize - length) / 2
        }
        return min(start - padding, length + padding - inputSize)
    }

    /// Throws CancellationError between tiles
    func upscale(_ source: UpscaleBitmap, model: some UpscaleTileModel) throws -> UpscaleBitmap {
        var output = UpscaleBitmap(width: source.width * scale, height: source.height * scale)
        var tileInput = [UInt8](repeating: 0, count: inputSize * inputSize * 4)
        var tileOutput = [UInt8](repeating: 0, count: inputSize * scale * inputSize * scale * 4)

        for tile in tiles(width: source.width, height: source.height) {
            try Task.checkCancellation()
            fill(&tileInput, from: source, tile: tile)
            try tileInput.withUnsafeBufferPointer { input in
                try tileOutput.withUnsafeMutableBufferPointer { result in
                    try model.run(input: input.baseAddress!, output: result.baseAddress!)
                }
            }
            try Self.check(input: tileInput, inputSize: inputSize, output: tileOutput, tile: tile, scale: scale)
            copyCore(of: tile, from: tileOutput, to: &output)
        }
        return output
    }

    private func fill(_ window: inout [UInt8], from source: UpscaleBitmap, tile: UpscaleTile) {
        let size = inputSize
        let width = source.width
        let height = source.height
        source.pixels.withUnsafeBufferPointer { pixels in
            window.withUnsafeMutableBufferPointer { window in
                for y in 0..<size {
                    let row = Self.reflect(tile.originY + y, size: height) * width * 4
                    for x in 0..<size {
                        let from = row + Self.reflect(tile.originX + x, size: width) * 4
                        let to = (y * size + x) * 4
                        window[to] = pixels[from + 2]
                        window[to + 1] = pixels[from + 1]
                        window[to + 2] = pixels[from]
                        window[to + 3] = 255
                    }
                }
            }
        }
    }

    private func copyCore(of tile: UpscaleTile, from tileOutput: [UInt8], to output: inout UpscaleBitmap) {
        let outputSize = inputSize * scale
        let offsetX = (tile.coreX - tile.originX) * scale
        let offsetY = (tile.coreY - tile.originY) * scale
        let outputWidth = output.width
        output.pixels.withUnsafeMutableBufferPointer { pixels in
            tileOutput.withUnsafeBufferPointer { tileOutput in
                for y in 0..<(tile.coreHeight * scale) {
                    let row = ((tile.coreY * scale + y) * outputWidth + tile.coreX * scale) * 4
                    for x in 0..<(tile.coreWidth * scale) {
                        let from = ((offsetY + y) * outputSize + offsetX + x) * 4
                        let to = row + x * 4
                        pixels[to] = tileOutput[from + 2]
                        pixels[to + 1] = tileOutput[from + 1]
                        pixels[to + 2] = tileOutput[from]
                        pixels[to + 3] = 255
                    }
                }
            }
        }
    }

    /// Image outputs saturate instead of going non-finite, so a broken model shows up as a brightness shift.
    private static func check(input: [UInt8], inputSize: Int, output: [UInt8], tile: UpscaleTile, scale: Int) throws {
        func mean(_ pixels: [UInt8], size: Int, factor: Int) -> Int {
            let offsetX = (tile.coreX - tile.originX) * factor
            let offsetY = (tile.coreY - tile.originY) * factor
            let width = tile.coreWidth * factor
            let height = tile.coreHeight * factor
            var total = 0
            pixels.withUnsafeBufferPointer { pixels in
                for y in 0..<height {
                    for x in 0..<width {
                        total += Int(pixels[((offsetY + y) * size + offsetX + x) * 4 + 1])
                    }
                }
            }
            return total / max(1, width * height)
        }
        let before = mean(input, size: inputSize, factor: 1)
        let after = mean(output, size: inputSize * scale, factor: scale)
        if Swift.abs(before - after) > maxMeanDifference {
            throw UpscaleError.corruptOutput
        }
    }

    private static func reflect(_ coordinate: Int, size: Int) -> Int {
        guard size > 1 else {
            return 0
        }
        var coordinate = coordinate
        while coordinate < 0 || coordinate >= size {
            coordinate = coordinate < 0 ? -coordinate : 2 * size - 2 - coordinate
        }
        return coordinate
    }
}
