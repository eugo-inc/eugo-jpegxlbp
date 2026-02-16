//
//  PreviewProvider.swift
//  previewext
//
//  Created by Vyacheslav Gorlov on 9/29/25.
//


import QuickLook

import SDWebImage
import SDWebImageJPEGXLCoder


final
class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let jpegxlData = try Data(contentsOf: request.fileURL)
        guard let decodedImage = SDImageJPEGXLCoder.shared.decodedImage(with: jpegxlData, options: nil) else {
            throw NSError(domain: "eugo", code: 1161)
        }
        
        let reply = QLPreviewReply(dataOfContentType: .jpeg, contentSize: decodedImage.size) { replyToUpdate in
            // 1. As the `decodedImage` is always a valid JPEG XL image at this moment, this function **must** always succeed, so we don't wrap it into `try-catch` for performance.
            // 2. `compressionQuality` is an inverse of `distance` and grows from `0.0` to `1.0`. Find more details in  [`libjxl` docs](https://libjxl.readthedocs.io/en/latest/api_encoder.html#_CPPv429JxlEncoderDistanceFromQualityf).
            return decodedImage.jpegData(compressionQuality: 1.0)!
        }

        return reply
    }

}
