import Foundation

public enum ChunkedBodyDecoderError: Error, Equatable {
    case malformedChunkSize
    case malformedChunkTerminator
    case chunkSizeLineTooLong
    case trailerSectionTooLarge
}

/// Incremental `Transfer-Encoding: chunked` decoder.
///
/// The critical contract is `Output.consumedInputOffset`. A chunked body has no declared length,
/// and the bytes that follow the terminating `0\r\n` are not necessarily the next request — an
/// optional *trailer section* sits between them. Leftover for the next request on a persistent
/// connection must therefore be sliced from `consumedInputOffset`, never from a count derived
/// from the decoded body length; otherwise the next request parse starts mid-stream and the
/// connection desyncs.
///
/// Usage: hold a buffer of not-yet-consumed wire bytes, call `decode(buffer)`, then drop
/// `consumedInputOffset` bytes from the front of that buffer and append whatever arrives next.
/// The decoder carries its parse state across calls, so a chunk header split across two reads is
/// handled correctly.
public struct ChunkedBodyDecoder: Sendable {
    public struct Output: Sendable, Equatable {
        public var decodedBytes: Data
        public var consumedInputOffset: Int
        public var isComplete: Bool

        public init(decodedBytes: Data, consumedInputOffset: Int, isComplete: Bool) {
            self.decodedBytes = decodedBytes
            self.consumedInputOffset = consumedInputOffset
            self.isComplete = isComplete
        }
    }

    private enum Mode: Equatable {
        case chunkSize
        case chunkBody(remaining: Int64)
        case chunkTerminator
        case trailers
        case complete
    }

    /// A chunk-size line is a hex count plus optional `;name=value` extensions. Anything longer
    /// than this is a hostile or broken peer; bounding it stops an endless buffer grow while we
    /// wait for a CRLF that never comes.
    public static let maximumChunkSizeLineBytes = 1024
    public static let maximumTrailerSectionBytes = 8 * 1024

    private static let crlf = Data([0x0D, 0x0A])

    private var mode: Mode = .chunkSize
    private var trailerBytesSeen = 0

    public init() {}

    public var isComplete: Bool {
        mode == .complete
    }

    public mutating func decode(_ input: Data) throws -> Output {
        var cursor = 0
        var decoded = Data()

        parse: while true {
            switch mode {
            case .complete:
                break parse

            case .chunkSize:
                guard let lineEnd = Self.indexOfCRLF(in: input, from: cursor) else {
                    if input.count - cursor > Self.maximumChunkSizeLineBytes {
                        throw ChunkedBodyDecoderError.chunkSizeLineTooLong
                    }
                    break parse
                }
                if lineEnd - cursor > Self.maximumChunkSizeLineBytes {
                    throw ChunkedBodyDecoderError.chunkSizeLineTooLong
                }
                let line = Self.string(in: input, from: cursor, to: lineEnd)
                cursor = lineEnd + 2
                let size = try Self.parseChunkSize(line)
                mode = size == 0 ? .trailers : .chunkBody(remaining: size)

            case .chunkBody(let remaining):
                let available = Int64(input.count - cursor)
                guard available > 0 else { break parse }
                let take = Int(min(available, remaining))
                decoded.append(Self.slice(input, from: cursor, count: take))
                cursor += take
                let stillNeeded = remaining - Int64(take)
                if stillNeeded == 0 {
                    mode = .chunkTerminator
                } else {
                    mode = .chunkBody(remaining: stillNeeded)
                    break parse
                }

            case .chunkTerminator:
                guard input.count - cursor >= 2 else { break parse }
                guard Self.slice(input, from: cursor, count: 2) == Self.crlf else {
                    throw ChunkedBodyDecoderError.malformedChunkTerminator
                }
                cursor += 2
                mode = .chunkSize

            case .trailers:
                guard let lineEnd = Self.indexOfCRLF(in: input, from: cursor) else {
                    if trailerBytesSeen + (input.count - cursor) > Self.maximumTrailerSectionBytes {
                        throw ChunkedBodyDecoderError.trailerSectionTooLarge
                    }
                    break parse
                }
                let lineLength = lineEnd - cursor
                trailerBytesSeen += lineLength + 2
                if trailerBytesSeen > Self.maximumTrailerSectionBytes {
                    throw ChunkedBodyDecoderError.trailerSectionTooLarge
                }
                cursor = lineEnd + 2
                if lineLength == 0 {
                    mode = .complete
                }
            }
        }

        return Output(decodedBytes: decoded, consumedInputOffset: cursor, isComplete: mode == .complete)
    }

    /// `size[;ext-name[=ext-value]]*` — extensions are legal and must be tolerated, but a size
    /// that is not plain hex is rejected rather than looped on.
    private static func parseChunkSize(_ line: String) throws -> Int64 {
        let sizePart = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmed = sizePart.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty == false,
              trimmed.count <= 15,
              trimmed.allSatisfy({ $0.isHexDigit }),
              let value = Int64(trimmed, radix: 16),
              value >= 0 else {
            throw ChunkedBodyDecoderError.malformedChunkSize
        }
        return value
    }

    private static func indexOfCRLF(in data: Data, from offset: Int) -> Int? {
        guard offset <= data.count else { return nil }
        let base = data.startIndex
        let searchStart = data.index(base, offsetBy: offset)
        guard let range = data.range(of: crlf, in: searchStart..<data.endIndex) else {
            return nil
        }
        return data.distance(from: base, to: range.lowerBound)
    }

    private static func slice(_ data: Data, from offset: Int, count: Int) -> Data {
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        return Data(data[start..<end])
    }

    private static func string(in data: Data, from offset: Int, to end: Int) -> String {
        String(decoding: slice(data, from: offset, count: end - offset), as: UTF8.self)
    }
}
