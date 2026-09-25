import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// QR codes for card images: text or a link encoded on this device, drawn with
/// whole-pixel modules and a quiet zone so the 1-bit reader image scans
/// reliably. The reader never enlarges images, so the size is chosen here.
enum ContentQRCode {
    enum Failure: LocalizedError, Equatable {
        case empty, tooLong
        var errorDescription: String? {
            switch self {
            case .empty: "Enter the text or link to encode."
            case .tooLong: "This is too long for a QR code the reader can show. Shorten the text or link."
            }
        }
    }

    /// Byte limit that keeps modules at least 3 px within `targetPixels`.
    static let maximumBytes = 300
    /// About 24 mm on an X3 and 27 mm on an X4.
    static let targetPixels = 240
    static let quietModules = 4

    static func image(for text: String) throws -> ContentImageImport.Imported {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }
        let payload = Data(trimmed.utf8)
        guard payload.count <= maximumBytes else { throw Failure.tooLong }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { throw Failure.tooLong }
        // One pixel per module, including the generator's one-module margin.
        let extent = output.extent.integral
        let modules = Int(extent.width)
        guard modules > 0, Int(extent.height) == modules else { throw Failure.tooLong }
        var gray = [UInt8](repeating: 255, count: modules * modules)
        CIContext(options: [.useSoftwareRenderer: true]).render(
            output, toBitmap: &gray, rowBytes: modules, bounds: extent, format: .L8,
            colorSpace: CGColorSpaceCreateDeviceGray())
        let quiet = quietModules - 1  // the generator already added one
        let span = modules + quiet * 2
        let scale = targetPixels / span
        guard scale >= 3 else { throw Failure.tooLong }
        let size = span * scale
        let rowBytes = (size + 7) / 8
        var raster = Data(repeating: 0, count: rowBytes * size)
        for y in 0..<size {
            let moduleY = y / scale - quiet
            guard moduleY >= 0, moduleY < modules else { continue }
            for x in 0..<size {
                let moduleX = x / scale - quiet
                guard moduleX >= 0, moduleX < modules, gray[moduleY * modules + moduleX] < 128 else { continue }
                raster[y * rowBytes + x / 8] |= 0x80 >> (x % 8)
            }
        }
        return try ContentImageImport.imported(ContentImage(width: size, height: size, raster: raster))
    }
}
