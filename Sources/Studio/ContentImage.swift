import Foundation
import CoreGraphics

/// Canonical single-image P4 PBM; 1=black, MSB-first, zero unused row bits.
struct ContentImage: Equatable {
    let width: Int
    let height: Int
    let raster: Data
    enum ValidationError: Error { case dimensions, shape, padding }

    init(width: Int, height: Int, raster: Data) throws {
        guard (1...512).contains(width), (1...512).contains(height) else { throw ValidationError.dimensions }
        let rowBytes = (width + 7) / 8
        guard raster.count == rowBytes * height else { throw ValidationError.shape }
        let mask: UInt8 = width % 8 == 0 ? 0 : UInt8((1 << (8 - width % 8)) - 1)
        for y in 0..<height {
            guard raster[raster.startIndex + (y + 1) * rowBytes - 1] & mask == 0 else { throw ValidationError.padding }
        }
        self.width = width
        self.height = height
        self.raster = Data(raster)
    }

    func encoded() -> Data { Data("P4\n\(width) \(height)\n".utf8) + raster }

    /// Exact stored pixels, not a simulation of the reader's card layout.
    func previewImage() -> CGImage? {
        var pixels = Data(repeating: 255, count: width * height)
        let rowBytes = (width + 7) / 8
        for y in 0..<height {
            for x in 0..<width where raster[y * rowBytes + x / 8] & (0x80 >> (x % 8)) != 0 {
                pixels[y * width + x] = 0
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func decode(_ data: Data) throws -> ContentImage {
        guard (8...32779).contains(data.count) else { throw ValidationError.shape }
        let bytes = Array(data)
        guard Array(bytes.prefix(3)) == [80, 52, 10] else { throw ValidationError.shape }
        var offset = 3
        func dimension(delimiter: UInt8) throws -> Int {
            var value = 0
            for digit in 0..<4 {
                guard offset < bytes.count else { throw ValidationError.shape }
                let byte = bytes[offset]
                offset += 1
                if byte == delimiter && digit > 0 { return value }
                guard digit < 3, (48...57).contains(byte), digit > 0 || byte != 48 else {
                    throw ValidationError.dimensions
                }
                value = value * 10 + Int(byte - 48)
                guard value <= 512 else { throw ValidationError.dimensions }
            }
            throw ValidationError.dimensions
        }
        let width = try dimension(delimiter: 32)
        let height = try dimension(delimiter: 10)
        return try ContentImage(width: width, height: height, raster: Data(bytes[offset...]))
    }
}
