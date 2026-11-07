//
//  PageResolutionProbe.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation

/// What a page's content stream actually draws. Reading the resource dictionary alone isn't enough:
/// resources can be shared with the whole book, and images can be cropped, stripped or nested in forms.
nonisolated struct PageRasterInfo: Equatable, Sendable {
    /// Share of the crop box under continuous tone images, 0...1
    var coverage: Double = 0
    /// Share of the crop box under 1-bit images and stencil masks, 0...1
    var bitonalCoverage: Double = 0
    /// Resolution of the image covering the most of the page, in image pixels per page point
    var pixelsPerPoint: Double = 0
}

nonisolated enum PageResolutionProbe {
    private static let maxFormDepth = 8

    private final class Scan {
        let cropBox: CGRect
        var transform = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var depth = 0
        var info = PageRasterInfo()
        var largestArea = 0.0
        /// for forms without their own resources
        let pageResources: CGPDFDictionaryRef?

        init(cropBox: CGRect, pageResources: CGPDFDictionaryRef?) {
            self.cropBox = cropBox
            self.pageResources = pageResources
        }

        func addImage(width: Int, height: Int, bitonal: Bool) {
            guard width > 0, height > 0 else {
                return
            }
            let placed = CGRect(x: 0, y: 0, width: 1, height: 1).applying(transform)
            let visible = placed.intersection(cropBox)
            guard !visible.isNull, placed.width > 0, placed.height > 0, cropBox.width > 0, cropBox.height > 0 else {
                return
            }
            let share = Double(visible.width * visible.height) / Double(cropBox.width * cropBox.height)
            if bitonal {
                info.bitonalCoverage = min(1, info.bitonalCoverage + share)
                return
            }
            info.coverage = min(1, info.coverage + share)
            if share > largestArea {
                largestArea = share
                info.pixelsPerPoint = (Double(width * height) / Double(placed.width * placed.height)).squareRoot()
            }
        }
    }

    static func probe(_ page: CGPDFPage) -> PageRasterInfo {
        let scan = Scan(cropBox: page.getBoxRect(.cropBox), pageResources: inheritedResources(of: page))
        let stream = CGPDFContentStreamCreateWithPage(page)
        run(stream, scan: scan)
        CGPDFContentStreamRelease(stream)
        return scan.info
    }
    
    /// Resources can sit on any ancestor in the page tree
    private static func inheritedResources(of page: CGPDFPage) -> CGPDFDictionaryRef? {
        var node = page.dictionary
        while let current = node {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources {
                return resources
            }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(current, "Parent", &parent) else {
                return nil
            }
            node = parent
        }
        return nil
    }

    private static func run(_ stream: CGPDFContentStreamRef, scan: Scan) {
        guard let table = CGPDFOperatorTableCreate() else {
            return
        }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            scan.stack.append(scan.transform)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            if let transform = scan.stack.popLast() {
                scan.transform = transform
            }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in stride(from: 5, through: 0, by: -1) {
                guard CGPDFScannerPopNumber(scanner, &values[index]) else {
                    return
                }
            }
            let matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            scan.transform = matrix.concatenating(scan.transform)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            var value: CGPDFStreamRef?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", name),
                  CGPDFObjectGetValue(object, .stream, &value), let value,
                  let dictionary = CGPDFStreamGetDictionary(value) else {
                return
            }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else {
                return
            }
            switch String(cString: subtype) {
            case "Image":
                PageResolutionProbe.addImage(dictionary, keys: .long, scan: scan)
            case "Form":
                PageResolutionProbe.runForm(value, dictionary: dictionary, parent: CGPDFScannerGetContentStream(scanner), scan: scan)
            default:
                break
            }
        }
        // an inline image ends with EI, and its dictionary comes on the stack as a stream
        CGPDFOperatorTableSetCallback(table, "EI") { scanner, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            var value: CGPDFStreamRef?
            guard CGPDFScannerPopStream(scanner, &value), let value,
                  let dictionary = CGPDFStreamGetDictionary(value) else {
                return
            }
            PageResolutionProbe.addImage(dictionary, keys: .inline, scan: scan)
        }

        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(scan).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
    }

    private struct ImageKeys {
        let width: [String]
        let height: [String]
        let bits: [String]
        let mask: [String]

        static let long = ImageKeys(width: ["Width"], height: ["Height"], bits: ["BitsPerComponent"], mask: ["ImageMask"])
        static let inline = ImageKeys(width: ["Width", "W"], height: ["Height", "H"], bits: ["BitsPerComponent", "BPC"], mask: ["ImageMask", "IM"])
    }

    private static func addImage(_ dictionary: CGPDFDictionaryRef, keys: ImageKeys, scan: Scan) {
        func integer(_ names: [String]) -> Int {
            for name in names {
                var value: CGPDFInteger = 0
                if CGPDFDictionaryGetInteger(dictionary, name, &value) {
                    return value
                }
            }
            return 0
        }
        var isMask: CGPDFBoolean = 0
        for name in keys.mask where isMask == 0 {
            _ = CGPDFDictionaryGetBoolean(dictionary, name, &isMask)
        }
        let bitonal = isMask != 0 || integer(keys.bits) == 1
        scan.addImage(width: integer(keys.width), height: integer(keys.height), bitonal: bitonal)
    }

    private static func runForm(_ form: CGPDFStreamRef, dictionary: CGPDFDictionaryRef, parent: CGPDFContentStreamRef, scan: Scan) {
        guard scan.depth < maxFormDepth else {
            return
        }
        var own: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &own)
        guard let resources = own ?? scan.pageResources else {
            return
        }
        let saved = scan.transform
        let savedStack = scan.stack
        scan.depth += 1
        defer {
            scan.depth -= 1
            scan.transform = saved
            scan.stack = savedStack
        }
        var matrix: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in 0..<6 {
                _ = CGPDFArrayGetNumber(matrix, index, &values[index])
            }
            let transform = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            scan.transform = transform.concatenating(scan.transform)
        }
        let stream = CGPDFContentStreamCreateWithStream(form, resources, parent)
        run(stream, scan: scan)
        CGPDFContentStreamRelease(stream)
    }
}

nonisolated enum UpscalePolicy {
    enum SkipReason: Equatable, Sendable {
        /// vector pages, partly raster pages (vector lettering would be baked in) and placement the probe can't explain
        case notRaster
        /// 1-bit scans, and stencil masks over a low resolution background
        case bitonal
        /// already at or above the screen's resolution
        case sharpEnough
    }

    enum Decision: Equatable, Sendable {
        case upscale(inputLongSide: CGFloat)
        case skip(SkipReason)
    }

    /// A 2048 px input takes up to ~70 tiles and fills about 4096 px on output
    static let maxInputLongSide: CGFloat = 2048
    static let minCoverage = 0.9
    static let maxBitonalCoverage = 0.1

    /// `pageLongSide` is in points. The input stays at the source's native size, because resampling screentone
    /// before inference damages it, and a zoomed page would look worse than PDFKit's original underneath.
    static func decide(_ info: PageRasterInfo, pageLongSide: CGFloat, screenLongSide: CGFloat) -> Decision {
        if info.bitonalCoverage > maxBitonalCoverage {
            return .skip(.bitonal)
        }
        guard info.coverage >= minCoverage, info.pixelsPerPoint > 0 else {
            return .skip(.notRaster)
        }
        let native = (pageLongSide * info.pixelsPerPoint).rounded()
        if native >= screenLongSide {
            return .skip(.sharpEnough)
        }
        return .upscale(inputLongSide: min(native, maxInputLongSide))
    }
}
