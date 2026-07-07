import AVFoundation
import ImageIO

/// Sidecar file storing LiDAR depth frames alongside a recorded video, used
/// by the offline analysis pipeline to measure the lifter's metric scale.
/// Format (little-endian):
///
///   "SQDP" magic, UInt32 version
///   v2+: Float32 camera focal length in pixels (0 = unknown)
///   repeated frames:
///     Float64 presentationTimeSeconds
///     UInt32 descriptionPlistLength, UInt32 compressedDepthLength
///     [description plist bytes][zlib-compressed DepthFloat16 pixel bytes]
enum DepthSidecar {
    static let magic = Data("SQDP".utf8)
    static let version: UInt32 = 2
    static let fileExtension = "depth"
}

struct DepthSidecarFrame {
    let time: TimeInterval
    let depthData: AVDepthData
}

final class DepthSidecarWriter {
    private let handle: FileHandle
    private(set) var frameCount = 0
    /// Camera focal length in pixels, from the capture connection's intrinsic
    /// matrix. Set any time before `finish()`; 0 = unknown.
    var focalLengthPixels: Float = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        var header = DepthSidecar.magic
        header.appendLittleEndian(DepthSidecar.version)
        header.appendLittleEndian(focalLengthPixels.bitPattern)
        try handle.write(contentsOf: header)
    }

    func append(_ depthData: AVDepthData, at time: CMTime) throws {
        let depth = depthData.depthDataType == kCVPixelFormatType_DepthFloat16
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat16)
        let dict = depth.dictionaryRepresentation(forAuxiliaryDataType: nil)
        guard let dict,
              let pixelData = dict[kCGImageAuxiliaryDataInfoData as String] as? Data,
              let description = dict[kCGImageAuxiliaryDataInfoDataDescription as String]
        else { return }

        let descriptionPlist = try PropertyListSerialization.data(
            fromPropertyList: description, format: .binary, options: 0
        )
        let compressed = try (pixelData as NSData).compressed(using: .zlib) as Data

        var record = Data()
        record.appendLittleEndian(time.seconds.bitPattern)
        record.appendLittleEndian(UInt32(descriptionPlist.count))
        record.appendLittleEndian(UInt32(compressed.count))
        record.append(descriptionPlist)
        record.append(compressed)
        try handle.write(contentsOf: record)
        frameCount += 1
    }

    func finish() throws {
        // The focal length arrives with the first video frame, after the
        // header was written — patch it in before closing.
        try handle.seek(toOffset: UInt64(DepthSidecar.magic.count) + 4)
        var focal = Data()
        focal.appendLittleEndian(focalLengthPixels.bitPattern)
        try handle.write(contentsOf: focal)
        try handle.close()
    }
}

/// Sequential reader; frames are stored in presentation order.
final class DepthSidecarReader {
    private let data: Data
    private var offset: Int
    /// Camera focal length in pixels; nil for v1 sidecars or when the capture
    /// connection did not deliver intrinsics.
    let focalLengthPixels: Float?

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 8, data.prefix(4) == DepthSidecar.magic else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let version = UInt32(littleEndian: data.subdata(in: 4 ..< 8)
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard version <= DepthSidecar.version else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if version >= 2, data.count >= 12 {
            let focal = Float(bitPattern: UInt32(littleEndian: data.subdata(in: 8 ..< 12)
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            focalLengthPixels = focal > 0 ? focal : nil
            offset = 12
        } else {
            focalLengthPixels = nil
            offset = 8
        }
        self.data = data
    }

    func next() -> DepthSidecarFrame? {
        while let record = readRecord() {
            if let frame = decode(record) { return frame }
            // Skip records whose AVDepthData reconstruction fails; analysis
            // degrades to RGB-only for those frames.
        }
        return nil
    }

    private struct RawRecord {
        let time: TimeInterval
        let descriptionPlist: Data
        let compressedDepth: Data
    }

    private func readRecord() -> RawRecord? {
        guard offset + 16 <= data.count else { return nil }
        let timeBits: UInt64 = readLittleEndian()
        let descriptionLength = Int(readLittleEndian() as UInt32)
        let depthLength = Int(readLittleEndian() as UInt32)
        guard offset + descriptionLength + depthLength <= data.count else { return nil }
        let description = data.subdata(in: offset ..< offset + descriptionLength)
        offset += descriptionLength
        let depth = data.subdata(in: offset ..< offset + depthLength)
        offset += depthLength
        return RawRecord(
            time: Double(bitPattern: timeBits),
            descriptionPlist: description,
            compressedDepth: depth
        )
    }

    private func decode(_ record: RawRecord) -> DepthSidecarFrame? {
        guard
            let description = try? PropertyListSerialization.propertyList(
                from: record.descriptionPlist, format: nil
            ),
            let pixelData = try? (record.compressedDepth as NSData).decompressed(using: .zlib),
            let depthData = try? AVDepthData(fromDictionaryRepresentation: [
                kCGImageAuxiliaryDataInfoData as String: pixelData as Data,
                kCGImageAuxiliaryDataInfoDataDescription as String: description,
            ])
        else { return nil }
        return DepthSidecarFrame(time: record.time, depthData: depthData)
    }

    private func readLittleEndian<T: FixedWidthInteger>() -> T {
        let value = data.subdata(in: offset ..< offset + MemoryLayout<T>.size)
            .withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        offset += MemoryLayout<T>.size
        return T(littleEndian: value)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
