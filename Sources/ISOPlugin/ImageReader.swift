// SPDX-License-Identifier: Apache-2.0
// ImageReader.swift - Reading bytes out of a disc image, and the integer soup on top of it.
//
// Everything in this plugin ultimately asks this file for "n bytes at offset". It is a plain
// pread(2) on a file descriptor rather than a memory map or a Data(contentsOf:), and that is
// deliberate: these images run to gigabytes, the host may ask for one file out of ten thousand,
// and the point of the whole plugin is not to read the other nine thousand nine hundred
// and ninety-nine.
//
// The integer helpers below look repetitive next to a generic one. They are separate on purpose:
// ISO 9660 stores most numbers *twice*, once little-endian and once big-endian, and a reader that
// forgets which half it is looking at produces sizes that are wrong by a factor of 2^24 without
// ever failing. Naming the layout at every call site is what keeps that honest.

import Foundation

public enum ImageError: Error, Equatable {
    case cannotOpen(String)
    case readFailed(offset: Int64)
    case notThisFormat
    case malformed(String)
}

/// A disc image open for reading, with a small cache in front of the sectors that get re-read.
final class ImageReader {
    let path: String
    let size: Int64
    private let fd: Int32

    init(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw ImageError.cannotOpen(path) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { close(fd); throw ImageError.cannotOpen(path) }
        self.fd = fd
        self.path = path
        self.size = Int64(st.st_size)
    }

    deinit { close(fd) }

    /// Exactly `length` bytes at `offset`, or nil when the image is shorter than that.
    ///
    /// Returning nil rather than a short buffer matters: every caller here is decoding a
    /// fixed-layout structure, and a structure half-read from the end of a truncated image is not
    /// a structure — it is whatever the previous contents of the buffer were.
    func read(at offset: Int64, length: Int) -> Data? {
        guard length > 0, offset >= 0, offset &+ Int64(length) <= size else { return nil }
        var buffer = Data(count: length)
        let got: Int = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            var total = 0
            while total < length {
                let n = pread(fd, base.advanced(by: total), length - total, off_t(offset) + off_t(total))
                if n <= 0 { break }
                total += n
            }
            return total
        }
        return got == length ? buffer : nil
    }

    /// As much of `length` as the image holds, from `offset`. For serving a file's contents, where
    /// a short read at the end is the ordinary case rather than a fault.
    func readPartial(at offset: Int64, length: Int) -> Data {
        guard length > 0, offset >= 0, offset < size else { return Data() }
        let want = Int(min(Int64(length), size - offset))
        return read(at: offset, length: want) ?? Data()
    }
}

// MARK: - Integers

extension Data {
    /// Little-endian unsigned integer of `count` bytes at `offset` within this Data.
    func le(_ offset: Int, _ count: Int) -> UInt64 {
        guard offset >= 0, count > 0, count <= 8, offset + count <= self.count else { return 0 }
        var value: UInt64 = 0
        for i in stride(from: count - 1, through: 0, by: -1) {
            value = (value << 8) | UInt64(self[self.startIndex + offset + i])
        }
        return value
    }

    /// Big-endian unsigned integer of `count` bytes at `offset`.
    func be(_ offset: Int, _ count: Int) -> UInt64 {
        guard offset >= 0, count > 0, count <= 8, offset + count <= self.count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<count {
            value = (value << 8) | UInt64(self[self.startIndex + offset + i])
        }
        return value
    }

    func u8(_ offset: Int) -> UInt8 {
        guard offset >= 0, offset < count else { return 0 }
        return self[startIndex + offset]
    }

    /// ISO 9660's "both-byte-order" 32-bit field: the same number little-endian then big-endian.
    ///
    /// The little half is returned, and the big half is *checked*. They disagree only in an image
    /// that is damaged or was written by something that does not understand the format, and
    /// silently trusting one half is how a wrong extent becomes a wrong file rather than an error.
    func both32(_ offset: Int) -> UInt32? {
        guard offset + 8 <= count else { return nil }
        let little = UInt32(truncatingIfNeeded: le(offset, 4))
        let big = UInt32(truncatingIfNeeded: be(offset + 4, 4))
        return little == big ? little : nil
    }

    /// The 16-bit both-byte-order field, same rule.
    func both16(_ offset: Int) -> UInt16? {
        guard offset + 4 <= count else { return nil }
        let little = UInt16(truncatingIfNeeded: le(offset, 2))
        let big = UInt16(truncatingIfNeeded: be(offset + 2, 2))
        return little == big ? little : nil
    }

    /// A fixed-width, space-padded ASCII field, trimmed.
    func strA(_ offset: Int, _ length: Int) -> String {
        guard offset >= 0, offset + length <= count else { return "" }
        let bytes = subdata(in: (startIndex + offset)..<(startIndex + offset + length))
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }

    /// A fixed-width UCS-2 big-endian field (Joliet), trimmed.
    ///
    /// Decoded as UTF-16 rather than scalar by scalar. Joliet is nominally UCS-2 and so has no
    /// surrogates, but writers do emit them for characters outside the BMP, and a per-scalar
    /// decoder turns each half of such a pair into nothing at all — a name that loses a character
    /// silently rather than visibly.
    func strUCS2(_ offset: Int, _ length: Int) -> String {
        guard offset >= 0, offset + length <= count, length >= 2 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(length / 2)
        var i = offset
        while i + 1 < offset + length {
            let unit = UInt16(truncatingIfNeeded: be(i, 2))
            i += 2
            if unit == 0 { break }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }
}
