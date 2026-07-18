import Foundation
import OrzAudioKitCXX

public struct DecoderStreamInfo: Sendable, Equatable {
    public let sampleRate: Int
    public let channels: Int
    public let duration: Double
    public let subsongCount: Int
    public let capabilities: UInt32
}

public struct DecoderFormatInfo: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let decoderID: String
    public let decoderVersion: String
    public let category: String
    public let capabilities: UInt32
}

public enum OrzAudioCoreError: Error, Sendable, CustomStringConvertible {
    case status(Int32, String)

    public var description: String {
        switch self { case let .status(code, message): return "OrzAudioCore error \(code): \(message)" }
    }
}

/// Official Swift binding for the stable OrzAudioCore C ABI.
///
/// Each object owns one decoder handle. Calls on one object are serialized;
/// separate objects can render concurrently.
public final class AudioDecoder: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()
    public let info: DecoderStreamInfo

    public static var abiVersion: UInt32 { orz_abi_version() }
    public static var buildInfo: String { String(cString: orz_build_info()) }
    public static let cacheFingerprint: String = {
        guard let data = buildInfo.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["fingerprint"] as? String else { return "orzcore-abi-\(abiVersion)" }
        return value
    }()

    public static var supportedFormats: [DecoderFormatInfo] {
        (0..<orz_get_format_count()).compactMap { index in
            var value = orz_format_info()
            value.struct_size = UInt32(MemoryLayout<orz_format_info>.size)
            value.abi_version = orz_abi_version()
            guard orz_get_format_info(index, &value) == ORZ_OK,
                  let id = value.format_id, let name = value.display_name,
                  let decoder = value.decoder_id, let version = value.decoder_version,
                  let category = value.category else { return nil }
            return DecoderFormatInfo(id: String(cString: id), displayName: String(cString: name),
                                     decoderID: String(cString: decoder), decoderVersion: String(cString: version),
                                     category: String(cString: category), capabilities: value.capabilities)
        }
    }

    public static func probe(_ data: Data, extensionHint: String? = nil) throws -> (format: String, confidence: Int) {
        var result = orz_probe_result()
        result.struct_size = UInt32(MemoryLayout<orz_probe_result>.size)
        result.abi_version = orz_abi_version()
        let status = data.withUnsafeBytes { bytes in
            if let extensionHint {
                return extensionHint.withCString { orz_probe(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, $0, &result) }
            }
            return orz_probe(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, nil, &result)
        }
        try check(status)
        guard let format = result.format_id else { throw OrzAudioCoreError.status(-7, "probe returned no format") }
        return (String(cString: format), Int(result.confidence))
    }

    public init(data: Data, format: String, subsong: Int = 0, maxInputBytes: UInt64 = 0) throws {
        var config = orz_decoder_config()
        config.struct_size = UInt32(MemoryLayout<orz_decoder_config>.size)
        config.abi_version = orz_abi_version()
        config.subsong = UInt32(clamping: subsong)
        config.max_input_bytes = maxInputBytes
        var created: OpaquePointer?
        let status = data.withUnsafeBytes { bytes in
            format.withCString { formatPointer in
                orz_decoder_create_memory(
                    bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    bytes.count,
                    formatPointer,
                    &config,
                    &created
                )
            }
        }
        try Self.check(status)
        guard let created else { throw OrzAudioCoreError.status(Int32(ORZ_ERROR_INTERNAL.rawValue), "missing decoder handle") }
        handle = created
        do {
            info = try Self.readInfo(created)
        } catch {
            orz_decoder_destroy_v1(created)
            handle = nil
            throw error
        }
    }

    deinit { if let handle { orz_decoder_destroy_v1(handle) } }

    public func render(maxFrames: Int) throws -> [Float] {
        try lock.withLock {
            guard let handle, maxFrames > 0 else {
                throw OrzAudioCoreError.status(Int32(ORZ_ERROR_INVALID_ARGUMENT.rawValue), "invalid decoder or frame count")
            }
            var output = [Float](repeating: 0, count: maxFrames * info.channels)
            var rendered: UInt32 = 0
            let status = orz_decoder_render_f32(handle, &output, UInt32(clamping: maxFrames), &rendered)
            if status == ORZ_END_OF_STREAM { return [] }
            try Self.check(status)
            output.removeSubrange(Int(rendered) * info.channels..<output.count)
            return output
        }
    }

    public func seek(milliseconds: UInt64) throws {
        try lock.withLock { guard let handle else { return }; try Self.check(orz_decoder_seek(handle, milliseconds)) }
    }

    public func selectSubsong(_ subsong: Int) throws {
        try lock.withLock {
            guard let handle, subsong >= 0 else { throw OrzAudioCoreError.status(Int32(ORZ_ERROR_INVALID_ARGUMENT.rawValue), "invalid subsong") }
            try Self.check(orz_decoder_select_subsong_v1(handle, UInt32(subsong)))
        }
    }

    public func reset() throws {
        try lock.withLock { guard let handle else { return }; try Self.check(orz_decoder_reset(handle)) }
    }

    /// Cancellation is intentionally not locked so another task can request it
    /// while a render call is in progress. Decoders observe it between chunks.
    public func cancel() { if let handle { _ = orz_decoder_cancel(handle) } }

    private static func readInfo(_ handle: OpaquePointer) throws -> DecoderStreamInfo {
        var value = orz_stream_info()
        value.struct_size = UInt32(MemoryLayout<orz_stream_info>.size)
        value.abi_version = orz_abi_version()
        try check(orz_decoder_get_stream_info(handle, &value))
        return DecoderStreamInfo(sampleRate: Int(value.sample_rate), channels: Int(value.channels),
                                 duration: value.duration_seconds, subsongCount: Int(value.subsong_count),
                                 capabilities: value.capabilities)
    }

    private static func check(_ status: orz_status) throws {
        guard status == ORZ_OK else {
            throw OrzAudioCoreError.status(Int32(status.rawValue), String(cString: orz_status_message(status)))
        }
    }
}
