//
//  PreviewViewController.swift
//  previewext
//
//  Created by Vyacheslav Gorlov on 9/29/25.
//

import UIKit
import QuickLook

import SDWebImage
import SDWebImageJPEGXLCoder

class PreviewViewController: UIViewController, QLPreviewingController {
    
    
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        
        // Configure scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black
        view.addSubview(scrollView)
        
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // Configure image view
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false  // Important to not block gestures
        scrollView.addSubview(imageView)
        
        // Layout imageView centered with horizontal margin (10% padding each side)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            imageView.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, multiplier: 0.8),
            imageView.heightAnchor.constraint(lessThanOrEqualTo: scrollView.heightAnchor)
        ])
    }

    /*
    func preparePreviewOfSearchableItem(identifier: String, queryString: String?) async throws {
        // Implement this method and set QLSupportsSearchableItems to YES in the Info.plist of the extension if you support CoreSpotlight.

        // Perform any setup necessary in order to prepare the view.
        // Quick Look will display a loading spinner until this returns.
    }
    */

//    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping ((any Error)?) -> Void) {
//        imageView.sd_setImage(with: url) { _, error, _, _ in
//            if let error = error {
//                handler(error)
//            } else {
//                handler(nil)
//            }
//        }
//    }
//    
    func preparePreviewOfFile(at url: URL) async throws {
        let jpegxlData = try Data(contentsOf: url)
        if let decodedImage = SDImageJPEGXLCoder.shared.decodedImage(with: jpegxlData, options: nil) {
            imageView.image = decodedImage
        } else {
            throw NSError(domain: "eugo", code: 1161)
        }
        
        
//        imageView.sd_setImage(with: url)
        
        // Add the supported content types to the QLSupportedContentTypes array in the Info.plist of the extension.

        // Perform any setup necessary in order to prepare the view.

        // Quick Look will display a loading spinner until this returns.
        
        print("raptors")
    }

}
