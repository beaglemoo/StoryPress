import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageAssetCodec {
    static func normalizedPNG(at url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw StoryPressError.missingAsset("reference image could not be decoded")
        }
        return try pngData(from: image)
    }

    static func normalizedPNG(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw StoryPressError.missingAsset("generated image could not be decoded")
        }
        return try pngData(from: image)
    }

    private static func pngData(from image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw StoryPressError.missingAsset("reference image could not be converted") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw StoryPressError.missingAsset("reference image could not be converted")
        }
        return output as Data
    }
}
