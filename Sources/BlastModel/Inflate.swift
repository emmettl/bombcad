import Foundation

/// Raw Deflate (RFC 1951) decoded in Swift, for where Apple's Compression framework is not (Linux):
/// stored, fixed-Huffman and dynamic-Huffman blocks, after Mark Adler's `puff`. It reads what a
/// GeoTIFF's Deflate strips hold; it is not tuned for speed.
enum Inflate {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// The decoded bytes of `input`, a raw Deflate stream (no zlib header), at most `limit` of them.
    static func decode(_ input: [UInt8], limit: Int = .max) throws -> [UInt8] {
        var state = State(input: input, limit: limit)
        var last = false
        while !last {
            last = try state.bits(1) == 1
            switch try state.bits(2) {
            case 0: try state.stored()
            case 1: try state.codes(State.fixed.lengths, State.fixed.distances)
            case 2: try state.dynamic()
            default: throw Failure(description: "a Deflate block of reserved type 3")
            }
            if state.output.count > limit { break }
        }
        return Array(state.output.prefix(limit))
    }

    /// A canonical Huffman code: how many codes of each length, and the symbols in code order.
    struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int]

        init(lengths: [Int]) {
            symbols = [Int](repeating: 0, count: lengths.count)
            for length in lengths { counts[length] += 1 }
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }
    }

    struct State {
        let input: [UInt8]
        var position = 0
        var bitBuffer = 0
        var bitCount = 0
        var output: [UInt8] = []
        /// Past this many bytes a block stops being decoded: one block of codes can make 1,032
        /// times its size, and so ran far past what a strip was to hold before its end was seen.
        let limit: Int

        init(input: [UInt8], limit: Int = .max) {
            self.input = input
            self.limit = limit
            output.reserveCapacity(min(input.count * 4, limit))
        }

        mutating func bits(_ count: Int) throws -> Int {
            var value = bitBuffer
            while bitCount < count {
                guard position < input.count else { throw Failure(description: "a Deflate stream cut short") }
                value |= Int(input[position]) << bitCount
                position += 1
                bitCount += 8
            }
            bitBuffer = value >> count
            bitCount -= count
            return value & ((1 << count) - 1)
        }

        mutating func stored() throws {
            bitBuffer = 0
            bitCount = 0
            guard position + 4 <= input.count else { throw Failure(description: "a stored block cut short") }
            let length = Int(input[position]) | Int(input[position + 1]) << 8
            let check = Int(input[position + 2]) | Int(input[position + 3]) << 8
            guard length == ~check & 0xffff else {
                throw Failure(description: "a stored block's length unchecked")
            }
            position += 4
            guard position + length <= input.count else {
                throw Failure(description: "a stored block cut short")
            }
            output.append(contentsOf: input[position..<position + length])
            position += length
        }

        mutating func decode(_ code: Huffman) throws -> Int {
            var value = 0
            var first = 0
            var index = 0
            for length in 1..<16 {
                value |= try bits(1)
                let count = code.counts[length]
                if value - count < first { return code.symbols[index + (value - first)] }
                index += count
                first += count
                first <<= 1
                value <<= 1
            }
            throw Failure(description: "a Deflate code past 15 bits")
        }

        static let lengthBase = [
            3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
            163, 195,
            227, 258,
        ]
        static let lengthExtra = [
            0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
        ]
        static let distanceBase = [
            1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049,
            3073,
            4097, 6145, 8193, 12289, 16385, 24577,
        ]
        static let distanceExtra = [
            0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
        ]

        mutating func codes(_ lengths: Huffman, _ distances: Huffman) throws {
            while true {
                let symbol = try decode(lengths)
                if symbol < 256 {
                    output.append(UInt8(symbol))
                } else if symbol == 256 {
                    return
                } else {
                    let s = symbol - 257
                    guard s < 29 else { throw Failure(description: "a Deflate length code out of range") }
                    let length = Self.lengthBase[s] + (try bits(Self.lengthExtra[s]))
                    let d = try decode(distances)
                    guard d < 30 else { throw Failure(description: "a Deflate distance code out of range") }
                    let distance = Self.distanceBase[d] + (try bits(Self.distanceExtra[d]))
                    guard distance <= output.count else {
                        throw Failure(description: "a Deflate distance too far back")
                    }
                    let from = output.count - distance
                    for k in 0..<length { output.append(output[from + k]) }
                }
                if output.count > limit { return }
            }
        }

        static let fixed: (lengths: Huffman, distances: Huffman) = {
            var lengths = [Int](repeating: 8, count: 288)
            for symbol in 144..<256 { lengths[symbol] = 9 }
            for symbol in 256..<280 { lengths[symbol] = 7 }
            return (Huffman(lengths: lengths), Huffman(lengths: [Int](repeating: 5, count: 30)))
        }()

        mutating func dynamic() throws {
            let literals = try bits(5) + 257
            let distances = try bits(5) + 1
            let codeLengths = try bits(4) + 4
            guard literals <= 286, distances <= 30 else {
                throw Failure(description: "a Deflate header out of range")
            }
            let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
            var lengths = [Int](repeating: 0, count: 19)
            for k in 0..<codeLengths { lengths[order[k]] = try bits(3) }
            let lengthCode = Huffman(lengths: lengths)
            var all: [Int] = []
            while all.count < literals + distances {
                let symbol = try decode(lengthCode)
                switch symbol {
                case 0..<16: all.append(symbol)
                case 16:
                    guard let previous = all.last else {
                        throw Failure(description: "a repeat with nothing before it")
                    }
                    all += [Int](repeating: previous, count: 3 + (try bits(2)))
                case 17: all += [Int](repeating: 0, count: 3 + (try bits(3)))
                default: all += [Int](repeating: 0, count: 11 + (try bits(7)))
                }
            }
            guard all.count == literals + distances else {
                throw Failure(description: "Deflate lengths overrun")
            }
            try codes(Huffman(lengths: Array(all[..<literals])), Huffman(lengths: Array(all[literals...])))
        }
    }
}
