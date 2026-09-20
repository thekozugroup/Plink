import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct DecodedScreenFrame: @unchecked Sendable {
    public let requestID: String
    public let streamID: String
    public let index: Int
    public let width: Int
    public let height: Int
    public let image: CGImage

    public init(
        requestID: String,
        streamID: String,
        index: Int,
        width: Int,
        height: Int,
        image: CGImage
    ) {
        self.requestID = requestID
        self.streamID = streamID
        self.index = index
        self.width = width
        self.height = height
        self.image = image
    }
}

/// Native validation and ImageIO decoding shared by production preview and diagnostics.
public actor ScreenFrameDecoder {
    public init() {}

    public func decode(_ envelope: PlinkEnvelope) throws -> DecodedScreenFrame {
        guard case .frame(let frame) = try ScreenPreviewMessage(envelope: envelope) else {
            throw PayloadPolicyError.malformedFrame
        }
        let image = try Self.decodeJPEG(frame.jpegData, width: frame.width, height: frame.height)
        return DecodedScreenFrame(
            requestID: frame.requestID,
            streamID: frame.streamID,
            index: frame.index,
            width: frame.width,
            height: frame.height,
            image: image
        )
    }

    public nonisolated static func decodeJPEG(_ data: Data, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0,
              max(width, height) <= ScreenPreviewProtocol.maxLongEdge,
              min(width, height) <= ScreenPreviewProtocol.maxShortEdge,
              width <= ScreenPreviewProtocol.maxPixels / height,
              width * height <= ScreenPreviewProtocol.maxPixels,
              (1...ScreenPreviewProtocol.maxJPEGBytes).contains(data.count)
        else { throw PayloadPolicyError.malformedFrame }

        try validateBaselineJPEG(data, width: width, height: height)

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              integer(properties[kCGImagePropertyPixelWidth]) == width,
              integer(properties[kCGImagePropertyPixelHeight]) == height,
              (integer(properties[kCGImagePropertyOrientation]) ?? 1) == 1
        else { throw PayloadPolicyError.malformedFrame }

        let decodeOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ScreenPreviewProtocol.maxLongEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions),
              image.width == width, image.height == height,
              image.dataProvider?.data != nil,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else { throw PayloadPolicyError.malformedFrame }
        return image
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    public nonisolated static func validateBaselineJPEG(_ data: Data, width: Int, height: Int) throws {
        var validator = BaselineJPEGValidator(data: data)
        try validator.validate(width: width, height: height)
    }
}
