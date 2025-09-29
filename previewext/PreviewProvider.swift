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
            // As the `decodedImage` is always a valid JPEG XL image at this momenet, this **must** always succeed.
            // `compressionQuality` grows from 0 to 1 in contrast to `libjxl`'s `distance`
            return decodedImage.jpegData(compressionQuality: 1.0)!
        }

        return reply
    }

}
