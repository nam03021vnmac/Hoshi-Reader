//
//  CoreMLTileModel.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreML
import CoreVideo
import Foundation

nonisolated final class CoreMLTileModel: UpscaleTileModel {
    private let model: MLModel
    private let inputSize: Int
    private let outputSize: Int
    private let inputBuffer: CVPixelBuffer

    /// `url` is a compiled .mlmodelc. Loading can take seconds the first time the Neural Engine sees the model.
    init(url: URL, inputSize: Int, outputSize: Int) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        self.model = try MLModel(contentsOf: url, configuration: configuration)
        self.inputSize = inputSize
        self.outputSize = outputSize

        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, inputSize, inputSize, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else {
            throw UpscaleError.modelOutput
        }
        self.inputBuffer = buffer
    }

    func run(input: UnsafePointer<UInt8>, output: UnsafeMutablePointer<UInt8>) throws {
        CVPixelBufferLockBaseAddress(inputBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(inputBuffer) {
            let stride = CVPixelBufferGetBytesPerRow(inputBuffer)
            for y in 0..<inputSize {
                memcpy(base + y * stride, input + y * inputSize * 4, inputSize * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(inputBuffer, [])

        // the framework's autoreleased buffers would otherwise pile up until the whole page is done
        try autoreleasepool {
            let features = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(pixelBuffer: inputBuffer)])
            let prediction = try model.prediction(from: features)
            guard let result = prediction.featureValue(for: "output")?.imageBufferValue,
                  CVPixelBufferGetPixelFormatType(result) == kCVPixelFormatType_32BGRA,
                  CVPixelBufferGetWidth(result) == outputSize,
                  CVPixelBufferGetHeight(result) == outputSize else {
                throw UpscaleError.modelOutput
            }
            CVPixelBufferLockBaseAddress(result, .readOnly)
            defer {
                CVPixelBufferUnlockBaseAddress(result, .readOnly)
            }
            guard let base = CVPixelBufferGetBaseAddress(result) else {
                throw UpscaleError.modelOutput
            }
            let stride = CVPixelBufferGetBytesPerRow(result)
            for y in 0..<outputSize {
                memcpy(output + y * outputSize * 4, base + y * stride, outputSize * 4)
            }
        }
    }

    /// Core ML quietly runs ops it can't place on the Neural Engine on the CPU instead of failing to load.
    /// nil if the plan can't be read.
    static func neuralEngineShare(url: URL) async -> Double? {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        guard let plan = try? await MLComputePlan.load(contentsOf: url, configuration: configuration),
              case .program(let program) = plan.modelStructure,
              let function = program.functions["main"] else {
            return nil
        }
        var neuralEngine = 0
        var total = 0
        for operation in function.block.operations where operation.operatorName != "const" {
            guard let usage = plan.deviceUsage(for: operation) else {
                continue
            }
            total += 1
            if case .neuralEngine = usage.preferred {
                neuralEngine += 1
            }
        }
        return total > 0 ? Double(neuralEngine) / Double(total) : nil
    }
}
