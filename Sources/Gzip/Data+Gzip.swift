//
//  Data+Gzip.swift
//

/*
The MIT License (MIT)

© 2014-2023 1024jp <wolfrosch.com>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/

import struct Foundation.Data

#if os(Linux)
    import zlibLinux
#else
    import zlib
#endif

public enum Gzip {
    public static let maxWindowBits = MAX_WBITS
}

public struct CompressionLevel: RawRepresentable, Sendable {
    public let rawValue: Int32
    
    public static let noCompression = Self(Z_NO_COMPRESSION)
    public static let bestSpeed = Self(Z_BEST_SPEED)
    public static let bestCompression = Self(Z_BEST_COMPRESSION)
    public static let defaultCompression = Self(Z_DEFAULT_COMPRESSION)
    
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }
    
    public init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }
}

public struct GzipError: Swift.Error, Sendable {
    public enum Kind: Equatable, Sendable {
        case stream
        case data
        case memory
        case buffer
        case version
        case unknown(code: Int)
    }
    
    public let kind: Kind
    public let message: String
    
    internal init(code: Int32, msg: UnsafePointer<CChar>?) {
        self.message = msg.flatMap(String.init(validatingUTF8:)) ?? "Unknown gzip error"
        self.kind = Kind(code: code)
    }
    
    public var localizedDescription: String {
        return self.message
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
        return self.starts(with: [0x1f, 0x8b])
    }
    
    public func gzipped(level: CompressionLevel = .defaultCompression, wBits: Int32 = Gzip.maxWindowBits + 16) throws -> Data {
        guard !self.isEmpty else {
            return Data()
        }
        
        var stream = z_stream()
        var status: Int32
        
        status = deflateInit2_(&stream, level.rawValue, Z_DEFLATED, wBits, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        
        guard status == Z_OK else {
            throw GzipError(code: status, msg: stream.msg)
        }
        
        var data = Data(capacity: 1 << 14)
        repeat {
            if Int(stream.total_out) >= data.count {
                data.count += 1 << 14
            }
            
            let inputCount = self.count
            let outputCount = data.count
            
            self.withUnsafeBytes { (inputPointer: UnsafeRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputPointer.bindMemory(to: Bytef.self).baseAddress!).advanced(by: Int(stream.total_in))
                stream.avail_in = uInt(inputCount) - uInt(stream.total_in)
                
                data.withUnsafeMutableBytes { (outputPointer: UnsafeMutableRawBufferPointer) in
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
    
    public func gunzipped(wBits: Int32 = Gzip.maxWindowBits + 32) throws -> Data {
        guard !self.isEmpty else {
            return Data()
        }
        
        var data = Data(capacity: self.count * 2)
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
                    data.count += self.count / 2
                }
                
                let inputCount = self.count
                let outputCount = data.count
                
                self.withUnsafeBytes { (inputPointer: UnsafeRawBufferPointer) in
                    let inputStartPosition = totalIn + stream.total_in
                    stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputPointer.bindMemory(to: Bytef.self).baseAddress!).advanced(by: Int(inputStartPosition))
                    stream.avail_in = uInt(inputCount) - uInt(inputStartPosition)
                    
                    data.withUnsafeMutableBytes { (outputPointer: UnsafeMutableRawBufferPointer) in
                        let outputStartPosition = totalOut + stream.total_out
                        stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress!.advanced(by: Int(outputStartPosition))
                        stream.avail_out = uInt(outputCount) - uInt(outputStartPosition)
                        
                        status = inflate(&stream, Z_SYNC_FLUSH)
                        
                        stream.next_out = nil
                    }
                    
                    stream.next_in = nil
                }
            } while status == Z_OK || status == Z_BUF_ERROR
            
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
