import Foundation
import Testing
@testable import Squatter

/// The sidecar trim operates on raw bytes (no depth decode), so a synthetic
/// sidecar with arbitrary record payloads exercises it end to end.
struct RecordingTrimmerTests {
    private struct Record {
        let time: TimeInterval
        let description: Data
        let depth: Data
    }

    private func sidecarData(records: [Record]) -> Data {
        var data = DepthSidecar.magic
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(DepthSidecar.version)
        append(Float(1234.5).bitPattern) // focal length
        append(Float(0.25).bitPattern) // camera pitch
        for record in records {
            append(record.time.bitPattern)
            append(UInt32(record.description.count))
            append(UInt32(record.depth.count))
            data.append(record.description)
            data.append(record.depth)
        }
        return data
    }

    private func parse(_ data: Data) -> (header: Data, records: [Record]) {
        func read<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
            T(littleEndian: data.subdata(in: offset ..< offset + MemoryLayout<T>.size)
                .withUnsafeBytes { $0.loadUnaligned(as: T.self) })
        }
        var records: [Record] = []
        var offset = 16
        while offset + 16 <= data.count {
            let time = Double(bitPattern: read(UInt64.self, at: offset))
            let descriptionLength = Int(read(UInt32.self, at: offset + 8))
            let depthLength = Int(read(UInt32.self, at: offset + 12))
            let descriptionStart = offset + 16
            records.append(Record(
                time: time,
                description: data.subdata(in: descriptionStart ..< descriptionStart + descriptionLength),
                depth: data.subdata(
                    in: descriptionStart + descriptionLength
                        ..< descriptionStart + descriptionLength + depthLength
                )
            ))
            offset = descriptionStart + descriptionLength + depthLength
        }
        return (data.subdata(in: 0 ..< 16), records)
    }

    @Test func keepsOnlyRecordsNearTheWindowAndRebasesTimes() throws {
        let records = stride(from: 0.0, through: 10.0, by: 0.5).map {
            Record(time: $0, description: Data([1, 2]), depth: Data(repeating: UInt8($0 * 2), count: 5))
        }
        let original = sidecarData(records: records)

        let trimmed = try RecordingTrimmer.trimmedSidecar(original, keeping: 3.0 ... 7.0, rebasedTo: 3.0)
        let (header, kept) = parse(trimmed)

        #expect(header == original.subdata(in: 0 ..< 16))
        let expected = records.filter {
            $0.time >= 3.0 - RecordingTrimmer.sidecarSlack
                && $0.time <= 7.0 + RecordingTrimmer.sidecarSlack
        }
        #expect(kept.count == expected.count)
        for (keptRecord, expectedRecord) in zip(kept, expected) {
            #expect(abs(keptRecord.time - (expectedRecord.time - 3.0)) < 1e-9)
            #expect(keptRecord.description == expectedRecord.description)
            #expect(keptRecord.depth == expectedRecord.depth)
        }
    }

    @Test func trimmedSidecarStillReadsThroughDepthSidecarHeaderParsing() throws {
        let original = sidecarData(records: [
            Record(time: 1.0, description: Data([9]), depth: Data([8, 7])),
            Record(time: 2.0, description: Data([6]), depth: Data([5, 4])),
        ])
        let trimmed = try RecordingTrimmer.trimmedSidecar(original, keeping: 1.5 ... 3.0, rebasedTo: 1.5)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(DepthSidecar.fileExtension)
        try trimmed.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Header fields survive the rewrite; record decoding legitimately
        // fails on the synthetic payloads (not real AVDepthData), which the
        // reader treats as skippable records.
        let reader = try DepthSidecarReader(url: url)
        #expect(reader.focalLengthPixels == 1234.5)
        #expect(reader.cameraPitchRadians == 0.25)
        #expect(reader.next() == nil)
    }

    @Test func rejectsForeignBytes() {
        #expect(throws: (any Error).self) {
            _ = try RecordingTrimmer.trimmedSidecar(
                Data("not a sidecar".utf8), keeping: 0 ... 1, rebasedTo: 0
            )
        }
    }
}
