import AppKit
import CoreText
import Foundation
import ImageIO

struct PDFExporter {
    private let paths: StoryLibraryPaths
    private let bundle: Bundle
    private let pageSize = CGSize(width: 595, height: 842)
    private let margin: CGFloat = 42
    private let paperColor = NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.91, alpha: 1)
    private let inkColor = NSColor(calibratedRed: 0.15, green: 0.13, blue: 0.12, alpha: 1)

    init(paths: StoryLibraryPaths, bundle: Bundle = .main) {
        self.paths = paths
        self.bundle = bundle
    }

    @discardableResult
    func export(_ book: StoryBook, to destination: URL) throws -> URL {
        guard !book.pages.isEmpty else { throw StoryPressError.exportLayout("The book has no pages.") }
        let pageArtwork = try book.pages.map { page -> CGImage in
            guard let image = resolveImage(page, book: book) else {
                throw StoryPressError.missingAsset(page.sampleImageAssetName ?? page.imageFilename ?? "page \(page.pageNumber)")
            }
            return image
        }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw StoryPressError.exportLayout("A PDF document could not be created.")
        }

        do {
            try drawCover(book, image: pageArtwork[0], in: context)
            for (index, page) in book.pages.enumerated() {
                try drawPage(page, image: pageArtwork[index], in: context)
            }
            context.closePDF()
            guard !output.isEmpty else {
                throw StoryPressError.exportLayout("The PDF file was empty.")
            }
            try (output as Data).write(to: destination, options: [.atomic])
            return destination
        } catch {
            if let error = error as? StoryPressError { throw error }
            throw StoryPressError.exportLayout(error.localizedDescription)
        }
    }

    private func drawCover(_ book: StoryBook, image: CGImage, in context: CGContext) throws {
        context.beginPDFPage(nil)
        fillPaper(in: context)

        let titleRect = CGRect(
            x: margin,
            y: pageSize.height - margin - 88,
            width: pageSize.width - margin * 2,
            height: 84
        )
        let titleFonts = [38, 36, 34, 32, 30].map { serifFont(size: CGFloat($0), bold: true) }
        guard let titleFit = fittingText(book.title, fonts: titleFonts, in: titleRect, alignment: .center) else {
            throw StoryPressError.exportLayout("The title does not fit on the cover.")
        }
        try drawText(book.title, font: titleFit.font, alignment: .center, in: titleRect, context: context,
                     message: "The title does not fit on the cover.")

        let imageArea = CGRect(
            x: margin,
            y: 116,
            width: pageSize.width - margin * 2,
            height: pageSize.height - margin - 116 - 88 - 34
        )
        let fittedImageBounds = aspectFit(CGSize(width: image.width, height: image.height), inside: imageArea)
        let imageBounds = CGRect(
            x: fittedImageBounds.minX,
            y: imageArea.maxY - fittedImageBounds.height,
            width: fittedImageBounds.width,
            height: fittedImageBounds.height
        )
        context.draw(image, in: imageBounds)

        let creditRect = CGRect(x: margin, y: 43, width: pageSize.width - margin * 2, height: 16)
        try drawText("STORYPRESS", font: NSFont.systemFont(ofSize: 9, weight: .medium), alignment: .center,
                     in: creditRect, context: context, message: "The cover credit does not fit.")
        context.endPDFPage()
    }

    private func drawPage(_ page: StoryPage, image: CGImage, in context: CGContext) throws {
        context.beginPDFPage(nil)
        fillPaper(in: context)

        let pageNumberRect = CGRect(x: margin, y: 36, width: pageSize.width - margin * 2, height: 16)
        let narrationBottom = pageNumberRect.maxY + 24
        let narrationGap: CGFloat = 24
        let maximumNarrationHeight: CGFloat = 188
        let imageTop = pageSize.height - margin
        let imageBottom = narrationBottom + maximumNarrationHeight + narrationGap
        let imageArea = CGRect(
            x: margin,
            y: imageBottom,
            width: pageSize.width - margin * 2,
            height: imageTop - imageBottom
        )
        let fittedImageBounds = aspectFit(CGSize(width: image.width, height: image.height), inside: imageArea)
        let imageBounds = CGRect(
            x: fittedImageBounds.minX,
            y: imageArea.maxY - fittedImageBounds.height,
            width: fittedImageBounds.width,
            height: fittedImageBounds.height
        )
        context.draw(image, in: imageBounds)

        let narrationFonts = [20, 19, 18, 17].map { serifFont(size: CGFloat($0), bold: false) }
        let measureRect = CGRect(x: margin, y: narrationBottom, width: pageSize.width - margin * 2,
                                 height: maximumNarrationHeight - 4)
        guard let narrationFit = fittingText(page.text, fonts: narrationFonts, in: measureRect, alignment: .center) else {
            throw StoryPressError.exportLayout("Page \(page.pageNumber) text is too long to fit. Shorten the text before exporting.")
        }
        let narrationHeight = min(narrationFit.size.height + 4, maximumNarrationHeight)
        let narrationRect = CGRect(
            x: margin,
            y: imageBounds.minY - narrationGap - narrationHeight,
            width: pageSize.width - margin * 2,
            height: narrationHeight
        )
        guard narrationRect.minY >= narrationBottom - 1 else {
            throw StoryPressError.exportLayout("Page \(page.pageNumber) text is too long to fit. Shorten the text before exporting.")
        }
        try drawText(page.text, font: narrationFit.font, alignment: .center, in: narrationRect, context: context,
                     message: "Page \(page.pageNumber) text is too long to fit. Shorten the text before exporting.")
        try drawText("Page \(page.pageNumber)", font: NSFont.systemFont(ofSize: 10, weight: .regular), alignment: .center,
                     in: pageNumberRect, context: context, message: "Page number does not fit.")
        context.endPDFPage()
    }

    private func fillPaper(in context: CGContext) {
        context.setFillColor(paperColor.cgColor)
        context.fill(CGRect(origin: .zero, size: pageSize))
    }

    private func drawText(
        _ text: String,
        font: NSFont,
        alignment: NSTextAlignment,
        in rect: CGRect,
        context: CGContext,
        message: String
    ) throws {
        let attributed = attributedText(text, font: font, alignment: alignment)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        var fitRange = CFRange(location: 0, length: 0)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            setter,
            CFRange(location: 0, length: attributed.length),
            nil,
            CGSize(width: rect.width, height: rect.height),
            &fitRange
        )
        guard fitRange.length >= attributed.length, fit.height <= rect.height + 1 else {
            throw StoryPressError.exportLayout(message)
        }
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: attributed.length), path, nil)
        context.saveGState()
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func fittingText(
        _ text: String,
        fonts: [NSFont],
        in rect: CGRect,
        alignment: NSTextAlignment
    ) -> (font: NSFont, size: CGSize)? {
        for font in fonts {
            let attributed = attributedText(text, font: font, alignment: alignment)
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            var fitRange = CFRange(location: 0, length: 0)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(
                setter,
                CFRange(location: 0, length: attributed.length),
                nil,
                rect.size,
                &fitRange
            )
            if fitRange.length >= attributed.length, fit.height <= rect.height + 1 {
                return (font, fit)
            }
        }
        return nil
    }

    private func attributedText(_ text: String, font: NSFont, alignment: NSTextAlignment) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: inkColor,
            .paragraphStyle: paragraphStyle
        ])
    }

    private func serifFont(size: CGFloat, bold: Bool) -> NSFont {
        let familyName = bold ? "Georgia-Bold" : "Georgia"
        return NSFont(name: familyName, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    private func resolveImage(_ page: StoryPage, book: StoryBook) -> CGImage? {
        if let relativePath = page.imageFilename,
           let url = try? paths.assetURL(bookID: book.id, relativePath: relativePath),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        if let assetName = page.sampleImageAssetName,
           let image = bundle.image(forResource: NSImage.Name(assetName)) {
            var proposed = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        }
        return nil
    }

    private func aspectFit(_ image: CGSize, inside rect: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return rect }
        let scale = min(rect.width / image.width, rect.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
}
