// SPDX-License-Identifier: GPL-3.0-only
// Eiscue video pipeline: bounded wire decoding, actor-owned codec, explicit crop.
import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import VideoToolbox
import ImageIO

private struct VideoBytes {
    private let storage: [UInt8]
    private(set) var offset = 0
    var remaining: Int { storage.count - offset }
    init(_ data: Data) { storage = Array(data) }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw NativeBackendError.malformedEvent }
        defer { offset += count }
        return Data(storage[offset..<offset + count])
    }
    mutating func integer(_ width: Int, littleEndian: Bool) throws -> UInt64 {
        let part = try take(width)
        return (littleEndian ? Array(part.reversed()) : Array(part)).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

private enum HEVCUnits {
    static func decode(_ data: Data) throws -> [Data] {
        var cursor = VideoBytes(data), units: [Data] = []
        while cursor.remaining > 0 {
            let count = Int(try cursor.integer(4, littleEndian: false))
            guard count >= 2, units.count < 256 else { throw NativeBackendError.malformedEvent }
            units.append(try cursor.take(count))
        }
        return units
    }
    static func encode(_ units: [Data]) -> Data {
        var result = Data()
        for unit in units {
            let size = UInt32(unit.count)
            for shift in [24, 16, 8, 0] { result.append(UInt8(truncatingIfNeeded: size >> shift)) }
            result.append(unit)
        }
        return result
    }
}

struct NCMVideoSample {
    let serial: UInt64, epoch: UInt64, ageMS: UInt64, revision: UInt64
    let timestamp: UInt32, sync: Bool, width: Int, height: Int
    let visibleSize: CGSize?
    let parameters: [Data]
    let bytes: Data
    init(_ data: Data) throws {
        guard (64...8 * 1024 * 1024).contains(data.count) else { throw NativeBackendError.malformedEvent }
        var cursor = VideoBytes(data)
        let sequence = try (0..<4).map { _ in try cursor.integer(8, littleEndian: true) }
        serial = sequence[0]; epoch = sequence[1]; ageMS = sequence[2]; revision = sequence[3]
        timestamp = UInt32(try cursor.integer(4, littleEndian: true))
        let flags = try cursor.integer(4, littleEndian: true)
        width = Int(try cursor.integer(4, littleEndian: true))
        height = Int(try cursor.integer(4, littleEndian: true))
        guard serial != 0, flags < 4, (1...16384).contains(width), (1...16384).contains(height),
              width * height <= 33_554_432 else { throw NativeBackendError.malformedEvent }
        sync = flags & 1 == 1
        let lengths = try (0..<4).map { _ in Int(try cursor.integer(4, littleEndian: true)) }
        if flags & 2 == 2 {
            let visibleWidth = Int(try cursor.integer(4, littleEndian: true))
            let visibleHeight = Int(try cursor.integer(4, littleEndian: true))
            guard visibleWidth > 0, visibleHeight > 0, (0..<64).contains(width - visibleWidth),
                  (0..<64).contains(height - visibleHeight) else { throw NativeBackendError.malformedEvent }
            visibleSize = CGSize(width: visibleWidth, height: visibleHeight)
        } else { visibleSize = nil }
        guard lengths.allSatisfy({ $0 > 0 }), lengths.prefix(3).allSatisfy({ $0 <= 1_048_576 }),
              lengths.reduce(0, +) == cursor.remaining else { throw NativeBackendError.malformedEvent }
        let payloads = try lengths.map { try cursor.take($0) }
        parameters = Array(payloads[0..<3]); bytes = payloads[3]
        _ = try HEVCUnits.decode(bytes)
    }
}

struct NCMDisplayPicture {
    let bytes: Data
    let visibleWidth: Int?, visibleHeight: Int?
    init(_ data: Data, codedWidth: Int, codedHeight: Int) throws {
        var size: CGSize?
        let units = try HEVCUnits.decode(data).map { unit -> Data in
            guard ((unit[0] >> 1) & 63) < 32 else { return unit }
            let body = Self.rbsp(Data(unit.dropFirst(2)))
            guard let marker = body.last, marker == 2 || marker == 3 else { return unit }
            let count = marker == 2 ? 9 : 13
            guard body.count > count else { return unit }
            var trailer = VideoBytes(Data(body.suffix(count)))
            if marker == 3 {
                let width = Int(try trailer.integer(2, littleEndian: false))
                let height = Int(try trailer.integer(2, littleEndian: false))
                guard width == codedWidth, height == codedHeight else { return unit }
            }
            let left = try trailer.integer(2, littleEndian: false), top = try trailer.integer(2, littleEndian: false)
            let width = Int(try trailer.integer(2, littleEndian: false)), height = Int(try trailer.integer(2, littleEndian: false))
            guard left == 0, top == 0, width > 0, height > 0,
                  (0..<64).contains(codedWidth - width), (0..<64).contains(codedHeight - height) else { return unit }
            let found = CGSize(width: width, height: height)
            guard size == nil || size == found else { throw NativeBackendError.malformedEvent }
            size = found
            return Data(unit.prefix(2)) + Self.ebsp(Data(body.dropLast(count)))
        }
        bytes = HEVCUnits.encode(units)
        visibleWidth = size.map { Int($0.width) }; visibleHeight = size.map { Int($0.height) }
    }
    private static func rbsp(_ input: Data) -> Data {
        let bytes = Array(input)
        var output = Data(), index = 0
        while index < bytes.count {
            if index + 3 < bytes.count, bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 3, bytes[index + 3] <= 3 {
                output.append(contentsOf: [0, 0]); index += 3
            } else { output.append(bytes[index]); index += 1 }
        }
        return output
    }
    private static func ebsp(_ input: Data) -> Data {
        var output = Data()
        for byte in input {
            if byte <= 3, output.count >= 2, output.suffix(2) == Data([0, 0]) { output.append(3) }
            output.append(byte)
        }
        return output
    }
}

private final class DecodedFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CVPixelBuffer, Error>?
    func receive(status: OSStatus, image: CVPixelBuffer?) {
        lock.withLock {
            if status == noErr, let image { result = .success(image) }
            else { result = .failure(Self.failure(status)) }
        }
    }
    func pixels() throws -> CVPixelBuffer {
        try lock.withLock { try (result ?? .failure(Self.failure(-1))).get() }
    }
    static func failure(_ status: OSStatus) -> NativeBackendError {
        NSLog("Eiscue video codec status=%d", status)
        return .screenshotFailure(stage: 20, cause: status == kVTInvalidSessionErr ? 13 : 14)
    }
}

private final class HEVCSession {
    let format: CMVideoFormatDescription
    private let session: VTDecompressionSession
    init(sample: NCMVideoSample) throws {
        var description: CMVideoFormatDescription?
        let code = withSlices(sample.parameters) { slices in
            let pointers = slices.map { $0.data! }, sizes = slices.map { $0.size }
            return pointers.withUnsafeBufferPointer { p in sizes.withUnsafeBufferPointer { n in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: slices.count,
                    parameterSetPointers: p.baseAddress!, parameterSetSizes: n.baseAddress!, nalUnitHeaderLength: 4,
                    extensions: nil, formatDescriptionOut: &description)
            } }
        }
        guard code == noErr, let description else { throw NativeBackendError.screenshotFailure(stage: 20, cause: 1) }
        let coded = CMVideoFormatDescriptionGetDimensions(description)
        let displayed = CMVideoFormatDescriptionGetPresentationDimensions(description, usePixelAspectRatio: false, useCleanAperture: true)
        guard CGSize(width: Int(coded.width), height: Int(coded.height)) == CGSize(width: sample.width, height: sample.height)
                || displayed == CGSize(width: sample.width, height: sample.height) else { throw NativeBackendError.malformedEvent }
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil,
            imageBufferAttributes: [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else { throw DecodedFrame.failure(status) }
        format = description; session = created
    }
    deinit { VTDecompressionSessionInvalidate(session) }
    func decode(_ bytes: Data, timestamp: UInt32) throws -> CVPixelBuffer {
        var memory: CMBlockBuffer?
        let allocation = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &memory)
        guard allocation == noErr, let memory else { throw NativeBackendError.malformedEvent }
        let copied = bytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: memory, offsetIntoDestination: 0, dataLength: raw.count)
        }
        guard copied == noErr else { throw NativeBackendError.malformedEvent }
        var input: CMSampleBuffer?, byteCount = bytes.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(timestamp), timescale: 90_000), decodeTimeStamp: .invalid)
        let packaged = CMSampleBufferCreateReady(allocator: nil, dataBuffer: memory, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &byteCount, sampleBufferOut: &input)
        guard packaged == noErr, let input else { throw NativeBackendError.malformedEvent }
        let output = DecodedFrame()
        // With both asynchronous and temporal flags clear, the callback finishes
        // before this call returns. No unmanaged callback reference crosses it.
        let submitted = VTDecompressionSessionDecodeFrame(session, sampleBuffer: input, flags: [], infoFlagsOut: nil) {
            status, _, pixels, _, _ in output.receive(status: status, image: pixels)
        }
        guard submitted == noErr else { throw DecodedFrame.failure(submitted) }
        return try output.pixels()
    }
}

actor NCMVideoDecoder {
    private struct Picture {
        let pixels: CVPixelBuffer, crop: CGRect, captured: ContinuousClock.Instant, serial: UInt64
    }
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var codec: HEVCSession?
    private var generation: (epoch: UInt64, revision: UInt64)?
    private var latest: Picture?
    private var contentSize: CGSize?
    private var geometry = NCMVideoGeometryTracker()
    private var lastSerial: UInt64 = 0, decodedCount: UInt64 = 0
    #if DEBUG
    private var keyframe: Data?
    func diagnosticKeyframe() -> Data? { keyframe }
    #endif
    func reset() {
        codec = nil; latest = nil; generation = nil; contentSize = nil
        geometry.reset()
        #if DEBUG
        keyframe = nil
        #endif
    }
    func diagnosticStatus() -> String {
        "polled=\(lastSerial) decoded=\(decodedCount) latestAge=\(latest.map { String(describing: $0.captured.duration(to: .now)) } ?? "none") requiresSync=\(codec == nil)"
    }
    @discardableResult nonisolated func consume(_ data: Data) async throws -> Bool {
        // Include time queued behind compression in the frame's age.
        let arrived = ContinuousClock.now
        return try await decode(data, observed: arrived)
    }
    private func decode(_ data: Data, observed: ContinuousClock.Instant) throws -> Bool {
        do {
            let sample = try NCMVideoSample(data)
            guard sample.serial > lastSerial else { throw NativeBackendError.malformedEvent }
            if lastSerial > 0 && sample.serial != lastSerial &+ 1 { geometry.reset() }
            lastSerial = sample.serial
            if generation?.epoch != sample.epoch || generation?.revision != sample.revision { reset() }
            if codec == nil {
                guard sample.sync else { return false }
                codec = try HEVCSession(sample: sample)
                generation = (sample.epoch, sample.revision)
            }
            guard let codec else { throw NativeBackendError.malformedEvent }
            let canvas = CMVideoFormatDescriptionGetDimensions(codec.format)
            let picture = try NCMDisplayPicture(sample.bytes, codedWidth: Int(canvas.width), codedHeight: Int(canvas.height))
            if let width = picture.visibleWidth, let height = picture.visibleHeight { contentSize = CGSize(width: width, height: height) }
            let pixels = try codec.decode(picture.bytes, timestamp: sample.timestamp)
            let crop: CGRect
            if let visible = contentSize ?? sample.visibleSize {
                crop = CGRect(x: 0, y: CGFloat(CVPixelBufferGetHeight(pixels)) - visible.height, width: visible.width, height: visible.height)
                guard CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)).contains(crop) else { throw NativeBackendError.malformedEvent }
            } else {
                crop = try NCMVideoImage.visibleRect(buffer: pixels, width: sample.width, height: sample.height,
                    formatAperture: CMVideoFormatDescriptionGetCleanAperture(codec.format, originIsAtTopLeft: true))
            }
            let age = Int64(clamping: sample.ageMS)
            latest = Picture(pixels: pixels, crop: crop, captured: observed.advanced(by: .milliseconds(-age)), serial: sample.serial)
            _ = geometry.update(epoch: sample.epoch, revision: sample.revision, bufferWidth: CVPixelBufferGetWidth(pixels),
                                bufferHeight: CVPixelBufferGetHeight(pixels), visibleRect: crop)
            decodedCount &+= 1
            #if DEBUG
            if sample.sync {
                keyframe = (sample.parameters + (try HEVCUnits.decode(sample.bytes))).reduce(into: Data()) {
                    $0.append(contentsOf: [0, 0, 0, 1]); $0.append($1)
                }
            }
            #endif
            return true
        } catch { reset(); throw error }
    }
    func currentGeometry() -> (geometry: NativeVideoGeometry, serial: UInt64)? {
        guard let frame = latest, let identity = geometry.current, codec != nil else { return nil }
        return (identity, frame.serial)
    }
    func jpeg(notBefore: ContinuousClock.Instant, confirmedEpoch: UInt64? = nil, confirmedSerial: UInt64 = 0) throws -> Data? {
        try jpegWithGeometry(notBefore: notBefore, confirmedEpoch: confirmedEpoch, confirmedSerial: confirmedSerial)?.data
    }
    func jpegWithGeometry(notBefore: ContinuousClock.Instant, confirmedEpoch: UInt64? = nil, confirmedSerial: UInt64 = 0) throws -> NativeVideoSnapshot? {
        guard let frame = latest, let identity = geometry.current, codec != nil else { return nil }
        let confirmed = confirmedSerial > 0 && generation?.epoch == confirmedEpoch && frame.serial >= confirmedSerial
        guard frame.captured >= notBefore || confirmed else { return nil }
        return NativeVideoSnapshot(data: try NCMVideoImage.jpeg(buffer: frame.pixels, rect: frame.crop, context: context), geometry: identity)
    }
}

enum NCMVideoImage {
    static func visibleRect(buffer: CVPixelBuffer, width: Int, height: Int, formatAperture: CGRect? = nil) throws -> CGRect {
        let allocation = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let fallback = CGRect(x: 0, y: allocation.height - CGFloat(height), width: CGFloat(width), height: CGFloat(height))
        guard width > 0, height > 0, allocation.contains(fallback) else { throw NativeBackendError.malformedEvent }
        var candidates = [preferredRect(buffer: buffer)]
        let clean = CVImageBufferGetCleanRect(buffer)
        if clean != allocation { candidates.append(clean) }
        candidates.append(formatAperture.map { CGRect(x: $0.minX, y: allocation.height - $0.maxY, width: $0.width, height: $0.height) })
        return candidates.compactMap { $0 }.first {
            !$0.isNull && !$0.isInfinite && !$0.isEmpty && $0 == $0.integral && allocation.contains($0)
                && $0.width <= CGFloat(width) && $0.height <= CGFloat(height)
        } ?? fallback
    }
    static func preferredRect(buffer: CVPixelBuffer) -> CGRect? {
        guard let attachment = CVBufferCopyAttachment(buffer, kCVImageBufferPreferredCleanApertureKey, nil) as? [String: NSNumber],
              let width = attachment[kCVImageBufferCleanApertureWidthKey as String]?.doubleValue,
              let height = attachment[kCVImageBufferCleanApertureHeightKey as String]?.doubleValue else { return nil }
        let centerX = Double(CVPixelBufferGetWidth(buffer)) / 2 + (attachment[kCVImageBufferCleanApertureHorizontalOffsetKey as String]?.doubleValue ?? 0)
        let centerY = Double(CVPixelBufferGetHeight(buffer)) / 2 - (attachment[kCVImageBufferCleanApertureVerticalOffsetKey as String]?.doubleValue ?? 0)
        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }
    static func jpeg(buffer: CVPixelBuffer, rect: CGRect, context: CIContext) throws -> Data {
        let cropped = CIImage(cvPixelBuffer: buffer).cropped(to: rect)
        let translated = cropped.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let encoded = context.jpegRepresentation(of: translated, colorSpace: colorSpace,
                  options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.85]) else {
            throw NativeBackendError.screenshotFailure(stage: 20, cause: 1)
        }
        return encoded
    }
}
