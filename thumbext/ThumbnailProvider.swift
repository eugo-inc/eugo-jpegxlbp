//
//  ThumbnailProvider.swift
//  thumbext
//
//  Created by Vyacheslav Gorlov on 9/30/25.
//

import UIKit
import QuickLookThumbnailing

import SDWebImage
import SDWebImageJPEGXLCoder


final
class ThumbnailProvider: QLThumbnailProvider {
    
    override
    func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        // There are three ways to provide a thumbnail through a QLThumbnailReply. Only one of them should be used.
        
        // First way: Draw the thumbnail into the current context, set up with UIKit's coordinate system.
        handler(QLThumbnailReply(contextSize: request.maximumSize, currentContextDrawing: { () -> Bool in
            // Draw the thumbnail here.
            do {
                let jpegxlData = try Data(contentsOf: request.fileURL)
                
                let decodingOptions: [SDImageCoderOption : Any] = [
                    .decodeThumbnailPixelSize: request.maximumSize,
                    .decodeScaleFactor: request.scale,
                    .decodePreserveAspectRatio: true
                ]
                guard let decodedImage = SDImageJPEGXLCoder.shared.decodedImage(with: jpegxlData, options: decodingOptions) else {
                    throw NSError(domain: "eugo", code: 1161)
                }
                
                decodedImage.draw(in: CGRect(origin: .zero, size: request.maximumSize))
                
                // Return true if the thumbnail was successfully drawn inside this block.
                return true
            } catch {
                print(error)
                return false
            }
        }), nil)
        
        /*
        
        // Second way: Draw the thumbnail into a context passed to your block, set up with Core Graphics's coordinate system.
        handler(QLThumbnailReply(contextSize: request.maximumSize, drawing: { (context) -> Bool in
            // Draw the thumbnail here.
         
            // Return true if the thumbnail was successfully drawn inside this block.
            return true
        }), nil)
         
        // Third way: Set an image file URL.
        handler(QLThumbnailReply(imageFileURL: Bundle.main.url(forResource: "fileThumbnail", withExtension: "jpg")!), nil)
        
        */
    }
}
