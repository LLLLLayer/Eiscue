// Resize the supplied artwork without changing its content.
// Run from the repository root: swift Scripts/generate-app-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let source = URL(fileURLWithPath: "Apps/Eiscue/Resources/Assets.xcassets/Mascot.imageset/Mascot.png")
let output = URL(fileURLWithPath: "Apps/Eiscue/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                              bytesPerRow: 0, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Could not load the supplied icon artwork")
}
context.interpolationQuality = .high
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.draw(artwork, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not prepare app icon")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write app icon") }
print("Prepared AppIcon.png (1024 × 1024, opaque)")
