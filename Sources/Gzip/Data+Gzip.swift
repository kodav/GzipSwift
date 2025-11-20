//
//  Data+Gzip.swift
//

import struct Foundation.Data

#if os(Linux)
    import zlibLinux
#else
    import zlib
#endif

public enum Gzip {
    /// Maximum value for windowBits (`MAX_WBITS`)
    public static let maxWindowBits = MAX_WBITS
}

/// Compression level whose rawValue is based on the zlib's constants.
public struct CompressionLevel: RawRepresentable, Sendable {
    public let rawValue: Int32

    public static let noCompression = CompressionLevel(Z_NO_COMPRESSION)
    public static let bestSpeed = CompressionLevel(Z_BEST_SPEED)
    public static let bestCompression = CompressionLevel(Z_BEST_COMPRESSION)
    public static let `default` = CompressionLevel(Z_DEFAULT_COMPRESSION)
    public static let defaultCompression = CompressionLevel(Z_DEFAULT_COMPRESSION)

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }
}

/// Errors on gzipping / gunzipping based on zlib error codes.
public struct GzipError: Error, Sendable {
    public enum Kind: Equatable, Sendable {
        case stream          // Z_STREAM_ERROR
        case data            // Z_DATA_ERROR
        case memory          // Z_MEM_ERROR
        case buffer          // Z_BUF_ERROR
        case version         // Z_VERSION_ERROR
        case unknown(code: Int)
    }

    public let kind: Kind
    public let message: String

    internal init(code: Int32, msg: UnsafePointer<CChar>?) {
        self.message = msg.flatMap { String(validatingUTF8: $0) } ?? "Unknown gzip error"
        self.kind = Kind(code: code)
    }

    public var localizedDescription: String {
        return message
    }
}

private extension GzipError.Kind {
    init(code: Int32) {
        switch code {
        case Z_STREAM_ERROR:
            self = .stream
        case Z_DATA_ERROR:
            self = .data
        case Z_MEM_ERROR:
            self = .memory
        case Z_BUF_ERROR:
            self = .buffer
        case Z_VERSION_ERROR:
            self = .version
        default:
            self = .unknown(code: Int(code))
        }
    }
}

extension Data {
    public var isGzipped: Bool {
        // проверка magic gzip-заголовка
        return self.starts(with: [0x1f, 0x8b])
    }

    /// Сжатие данных в gzip
    public func gzipped(level: CompressionLevel = .defaultCompression,
                        wBits: Int32 = Gzip.maxWindowBits + 16) throws -> Data {
        guard !self.isEmpty else {
            return Data()
        }

        var stream = z_stream()
        var status: Int32

        status = deflateInit2_(&stream,
                               level.rawValue,
                               Z_DEFLATED,
                               wBits,
                               MAX_MEM_LEVEL,
                               Z_DEFAULT_STRATEGY,
                               ZLIB_VERSION,
                               Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw GzipError(code: status, msg: stream.msg)
        }

        var data = Data(capacity: DataSize.chunk)
        repeat {
            if Int(stream.total_out) >= data.count {
                data.count += DataSize.chunk
            }

            let inputCount = self.count
            let outputCount = data.count

            try self.withUnsafeBytes { (inputPointer: UnsafeRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer<Bytef>(
                    mutating: inputPointer.bindMemory(to: Bytef.self).baseAddress!
                ).advanced(by: Int(stream.total_in))
                stream.avail_in = uInt(inputCount) - uInt(stream.total_in)

                try data.withUnsafeMutableBytes { (outputPointer: UnsafeMutableRawBufferPointer) in
                    stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress!.advanced(by: Int(stream.total_out))
                    stream.avail_out = uInt(outputCount) - uInt(stream.total_out)

                    status = deflate(&stream, Z_FINISH)
                    stream.next_out = nil
                }

                stream.next_in = nil
            }

        } while stream.avail_out == 0 && status != Z_STREAM_END

        guard deflateEnd(&stream) == Z_OK, status == Z_STREAM_END else {
            throw GzipError(code: status, msg: stream.msg)
        }

        data.count = Int(stream.total_out)
        return data
    }

    /// Распаковка gzip-сжатых данных
    public func gunzipped(wBits: Int32 = Gzip.maxWindowBits + 32) throws -> Data {
        guard !self.isEmpty else {
            return Data()
        }

        var data = Data(capacity: count * 2)
        var totalIn: uLong = 0
        var totalOut: uLong = 0

        repeat {
            var stream = z_stream()
            var status: Int32

            status = inflateInit2_(&stream, wBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard status == Z_OK else {
                throw GzipError(code: status, msg: stream.msg)
            }

            repeat {
                if Int(totalOut + stream.total_out) >= data.count {
                    data.count += count / 2
                }

                let inputCount = self.count
                let outputCount = data.count

                try self.withUnsafeBytes { (inputPointer: UnsafeRawBufferPointer) in
                    let inputStart = totalIn + stream.total_in
                    stream.next_in = UnsafeMutablePointer<Bytef>(
                        mutating: inputPointer.bindMemory(to: Bytef.self).baseAddress!
                    ).advanced(by: Int(inputStart))
                    stream.avail_in = uInt(inputCount) - uInt(inputStart)

                    try data.withUnsafeMutableBytes { (outputPointer: UnsafeMutableRawBufferPointer) in
                        let outputStart = totalOut + stream.total_out
                        stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress!.advanced(by: Int(outputStart))
                        stream.avail_out = uInt(outputCount) - uInt(outputStart)

                        status = inflate(&stream, Z_SYNC_FLUSH)
                        stream.next_out = nil
                    }

                    stream.next_in = nil
                }

            } while status == Z_OK

            totalIn += stream.total_in
            guard inflateEnd(&stream) == Z_OK, status == Z_STREAM_END else {
                throw GzipError(code: status, msg: stream.msg)
            }

            totalOut += stream.total_out
        } while totalIn < self.count

        data.count = Int(totalOut)
        return data
    }
}

private enum DataSize {
    static let chunk = 1 << 14
    static let stream = MemoryLayout<z_stream>.size
}
