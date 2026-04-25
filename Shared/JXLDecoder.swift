//
//  JXLDecoder.swift
//
//  Thin Swift wrapper over libjxl's C decoder. Replaces the previous
//  SDImageJPEGXLCoder dependency so we can ship libjxl as our own
//  XCFramework built with the project's CPU flags.
//

import Foundation
import CoreGraphics
import UIKit
import libjxl

enum JXLDecoderError: Error {
    case decoderInit
    case parseError
    case unexpectedStatus(UInt32)
    case noPixels
    case cgImage
}

enum JXLDecoder {

    /// Decode JPEG XL data into a `UIImage`.
    ///
    /// - Parameters:
    ///   - data: Raw `.jxl` bytes.
    ///   - maxDimension: If set and the decoded image's longest side exceeds
    ///     this value, the result is downscaled (preserving aspect ratio) via
    ///     Core Graphics. libjxl 0.11 has no zero-copy "decode at smaller
    ///     size" API for non-progressive images, so this is decode-then-scale
    ///     — same as what SDImageJPEGXLCoder did under the hood.
    static func decode(_ data: Data, maxDimension: CGFloat? = nil) throws -> UIImage {
        guard let decoder = JxlDecoderCreate(nil) else {
            throw JXLDecoderError.decoderInit
        }
        defer { JxlDecoderDestroy(decoder) }

        let events = Int32(JXL_DEC_BASIC_INFO.rawValue) | Int32(JXL_DEC_FULL_IMAGE.rawValue)
        guard JxlDecoderSubscribeEvents(decoder, events) == JXL_DEC_SUCCESS else {
            throw JXLDecoderError.parseError
        }

        var width: Int = 0
        var height: Int = 0
        var pixels: UnsafeMutableRawPointer?
        var pixelsSize: Int = 0

        // We free `pixels` ourselves below once it's been copied into a CFData,
        // but on the throwing paths we need to release it too.
        defer { if let p = pixels { free(p) } }

        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Void in
            guard let base = buf.baseAddress else { throw JXLDecoderError.parseError }
            let setIn = JxlDecoderSetInput(decoder, base.assumingMemoryBound(to: UInt8.self), buf.count)
            guard setIn == JXL_DEC_SUCCESS else {
                throw JXLDecoderError.unexpectedStatus(setIn.rawValue)
            }
            JxlDecoderCloseInput(decoder)

            loop: while true {
                let status = JxlDecoderProcessInput(decoder)
                switch status {
                case JXL_DEC_ERROR, JXL_DEC_NEED_MORE_INPUT:
                    throw JXLDecoderError.parseError

                case JXL_DEC_BASIC_INFO:
                    var info = JxlBasicInfo()
                    let r = JxlDecoderGetBasicInfo(decoder, &info)
                    guard r == JXL_DEC_SUCCESS else {
                        throw JXLDecoderError.unexpectedStatus(r.rawValue)
                    }
                    width = Int(info.xsize)
                    height = Int(info.ysize)

                case JXL_DEC_NEED_IMAGE_OUT_BUFFER:
                    var fmt = JxlPixelFormat(
                        num_channels: 4,
                        data_type: JXL_TYPE_UINT8,
                        endianness: JXL_NATIVE_ENDIAN,
                        align: 0
                    )
                    var needed: Int = 0
                    let r = JxlDecoderImageOutBufferSize(decoder, &fmt, &needed)
                    guard r == JXL_DEC_SUCCESS else {
                        throw JXLDecoderError.unexpectedStatus(r.rawValue)
                    }
                    pixelsSize = needed
                    pixels = malloc(needed)
                    guard let p = pixels else { throw JXLDecoderError.parseError }
                    let setOut = JxlDecoderSetImageOutBuffer(decoder, &fmt, p, needed)
                    guard setOut == JXL_DEC_SUCCESS else {
                        throw JXLDecoderError.unexpectedStatus(setOut.rawValue)
                    }

                case JXL_DEC_FULL_IMAGE:
                    continue loop

                case JXL_DEC_SUCCESS:
                    break loop

                default:
                    throw JXLDecoderError.unexpectedStatus(status.rawValue)
                }
            }
        }

        guard let p = pixels, width > 0, height > 0 else {
            throw JXLDecoderError.noPixels
        }

        // Hand pixels off to CGImage via a CFData copy. CFDataCreate copies,
        // so our buffer is freed by the deferred `free(p)` above.
        guard let cfData = CFDataCreate(nil, p.assumingMemoryBound(to: UInt8.self), pixelsSize),
              let provider = CGDataProvider(data: cfData) else {
            throw JXLDecoderError.cgImage
        }

        // libjxl emits straight (un-premultiplied) RGBA8. Use `.last` (straight
        // alpha), not `.premultipliedLast`, or composites darken on transparent
        // pixels.
        let bitmapInfo: CGBitmapInfo = [
            .byteOrder32Big,
            CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        ]
        guard let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw JXLDecoderError.cgImage
        }

        if let maxDim = maxDimension {
            let scale = min(maxDim / CGFloat(width), maxDim / CGFloat(height), 1.0)
            if scale < 1.0,
               let resized = Self.downscale(cg, to: CGSize(
                width: Int((CGFloat(width)  * scale).rounded()),
                height: Int((CGFloat(height) * scale).rounded())
               )) {
                return UIImage(cgImage: resized)
            }
        }
        return UIImage(cgImage: cg)
    }

    private static func downscale(_ image: CGImage, to size: CGSize) -> CGImage? {
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                       | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }
}
