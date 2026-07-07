import AVFoundation
import ImageIO

/// Sidecar file storing LiDAR depth frames alongside a recorded video, so the
/// offline analysis pipeline can hand `AVDepthData` to Vision for
/// depth-assisted 3D body pose. Format (little-endian):
///
///   "SQDP" magic, UInt32 version
///   repeated frames:
///     Float64 presentationTimeSeconds
///     UInt32 descriptionPlistLength, UInt32 compressedDepthLength
///     [description plist bytes][zlib-compressed DepthFloat16 pixel bytes]
enum DepthSidecar {
    static let magic = Data("SQDP".utf8)
    static let version: UInt32 = 1
    static let fileExtension = "depth"
}

struct DepthSidecarFrame {
    let time: TimeInterval
    let depthData: AVDepthData
}

final class DepthSidecarWriter {
    private let handle: FileHandle
    private(set) var frameCount = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        var header = DepthSidecar.magic
        header.appendLittleEndian(DepthSidecar.version)
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
        try handle.close()
    }
}

/// Sequential reader; frames are stored in presentation order.
final class DepthSidecarReader {
    private let data: Data
    private var offset: Int

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 8, data.prefix(4) == DepthSidecar.magic else {
            throw CocoaError(.fileReadCorruptFile)
        }
        offset = 8
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
