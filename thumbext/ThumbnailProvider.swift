//
//  ThumbnailProvider.swift
//  thumbext
//
//  Created by Vyacheslav Gorlov on 9/30/25.
//


import UIKit
import QuickLookThumbnailing


final
class ThumbnailProvider: QLThumbnailProvider {

    override
    func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        // There are three ways to provide a thumbnail through a QLThumbnailReply. Only one of them should be used.
        //
        // We follow a way of drawing the thumbnail into the current graphics context, set up with UIKit's coordinate system.
        handler(QLThumbnailReply(contextSize: request.maximumSize, currentContextDrawing: { () -> Bool in
            // Draw the thumbnail here.
            do {
                let jpegxlData = try Data(contentsOf: request.fileURL)

                // Cap the longest side at the requested maximum so we never
                // hold a full-resolution decode in extension memory longer
                // than necessary.
                let maxSide = max(request.maximumSize.width, request.maximumSize.height) * request.scale
                let decodedImage = try JXLDecoder.decode(jpegxlData, maxDimension: maxSide)

                decodedImage.draw(in: CGRect(origin: .zero, size: request.maximumSize))

                // Return true if the thumbnail was successfully drawn inside this block.
                return true
            } catch {
                print(error)
                return false
            }
        }), nil)
    }

}
