// SPDX-License-Identifier: Apache-2.0
// UDF.swift - ECMA-167 / UDF, enough of it to read a DVD, a Blu-ray, or a hybrid disc.
//
// This is the half that has no alternative. libarchive has no UDF reader at all, so a UDF-only
// image — every video DVD, every Blu-ray, anything written by `hdiutil makehybrid -udf` without
// `-iso` — does not open as an archive on this machine by any other route. A hybrid disc opens,
// but through its ISO 9660 half, which on a DVD is often a stub that lists nothing useful.
//
// The structures, in the order they are followed:
//
//   Anchor Volume Descriptor Pointer   at LBA 256, and at the last sector, and 256 before it.
//                                      Points at the Main Volume Descriptor Sequence.
//   Partition Descriptor               where the partition starts, in sectors.
//   Logical Volume Descriptor          the logical block size, and a long_ad to the File Set.
//   File Set Descriptor                a long_ad to the root directory's ICB.
//   File Entry / Extended File Entry   one per file: length, times, and allocation descriptors.
//   File Identifier Descriptor         one per directory entry: the name, and an ICB pointing at
//                                      the File Entry above.
//
// What is deliberately not implemented, because a disc needing it is not a disc a file manager is
// asked to open: virtual and sparable partition maps (packet-written CD-RW), metadata partitions
// (UDF 2.50 Blu-ray — read through the physical partition instead), and named streams. Each is
// detected and reported rather than silently mis-read.

import Foundation

enum UDF {
    static let sectorSize = 2048

    /// The volume recognition sequence at sector 16 — "BEA01" then "NSR02"/"NSR03".
    ///
    /// Checked before anything else because it is cheap and because an ISO 9660 disc with no UDF
    /// on it must be refused here rather than half-parsed: the anchor at LBA 256 is a plausible
    /// place for ordinary file data to sit.
    static func looksLikeUDF(_ reader: ImageReader) -> Bool {
        var offset = Int64(16 * sectorSize)
        for _ in 0..<8 {
            guard let block = reader.read(at: offset, length: 7) else { return false }
            let id = block.strA(1, 5)
            if id == "NSR02" || id == "NSR03" { return true }
            if id.isEmpty { return false }
            offset += Int64(sectorSize)
        }
        return false
    }

    // MARK: - Descriptor tag

    private struct Tag {
        var identifier: UInt16
        var location: UInt32
    }

    private static func tag(_ data: Data, at offset: Int = 0) -> Tag? {
        guard offset + 16 <= data.count else { return nil }
        let identifier = UInt16(truncatingIfNeeded: data.le(offset, 2))
        guard identifier > 0 else { return nil }
        // The tag checksum is the sum of the other fifteen bytes, mod 256. It is the only cheap
        // way to tell a real descriptor from a sector of file data that happens to start with a
        // plausible number, and skipping it is how a reader ends up following garbage.
        var sum: UInt32 = 0
        for i in 0..<16 where i != 4 { sum &+= UInt32(data.u8(offset + i)) }
        guard UInt8(truncatingIfNeeded: sum) == data.u8(offset + 4) else { return nil }
        return Tag(identifier: identifier, location: UInt32(truncatingIfNeeded: data.le(offset + 12, 4)))
    }

    // MARK: - Volume structure

    private struct Volume {
        var partitionStart: UInt32 = 0
        var partitionLength: UInt32 = 0
        var logicalBlockSize: Int = 2048
        var fileSetICB: LongAD?
        var volumeID: String = ""
        var unsupportedMap: String?
    }

    /// A long allocation descriptor: 4-byte length, then a logical block number and partition.
    struct LongAD {
        var length: UInt32
        var block: UInt32
        var partition: UInt16
        /// The top two bits of `length` are the extent type; only 0 (recorded and allocated) has data.
        var type: UInt8 { UInt8(truncatingIfNeeded: length >> 30) }
        var byteLength: UInt32 { length & 0x3FFF_FFFF }
    }

    private static func longAD(_ data: Data, at offset: Int) -> LongAD? {
        guard offset + 16 <= data.count else { return nil }
        return LongAD(length: UInt32(truncatingIfNeeded: data.le(offset, 4)),
                      block: UInt32(truncatingIfNeeded: data.le(offset + 4, 4)),
                      partition: UInt16(truncatingIfNeeded: data.le(offset + 8, 2)))
    }

    /// Follow the anchor to the volume descriptors.
    private static func readVolume(_ reader: ImageReader) throws -> Volume {
        // Three places the anchor may be, in the order of decreasing likelihood. An image that was
        // truncated during a download still has the one at 256, which is why it is tried first.
        let lastSector = max(reader.size / Int64(sectorSize) - 1, 0)
        let candidates: [Int64] = [256, lastSector, lastSector - 256].filter { $0 > 0 }

        var mainExtent: (length: UInt32, location: UInt32)?
        for candidate in candidates {
            guard let block = reader.read(at: candidate * Int64(sectorSize), length: sectorSize),
                  let t = tag(block), t.identifier == 2 else { continue }
            mainExtent = (UInt32(truncatingIfNeeded: block.le(16, 4)),
                          UInt32(truncatingIfNeeded: block.le(20, 4)))
            break
        }
        guard let mainExtent, mainExtent.length > 0 else { throw ImageError.notThisFormat }

        var volume = Volume()
        var sawPartition = false
        var sawLogicalVolume = false
        let sectors = Int(mainExtent.length) / sectorSize
        for i in 0..<max(sectors, 1) {
            let at = Int64(mainExtent.location + UInt32(i)) * Int64(sectorSize)
            guard let block = reader.read(at: at, length: sectorSize), let t = tag(block) else { continue }
            switch t.identifier {
            case 1:                                        // Primary Volume Descriptor
                volume.volumeID = dString(block, at: 24, length: 32)
            case 5:                                        // Partition Descriptor
                volume.partitionStart = UInt32(truncatingIfNeeded: block.le(188, 4))
                volume.partitionLength = UInt32(truncatingIfNeeded: block.le(192, 4))
                sawPartition = true
            case 6:                                        // Logical Volume Descriptor
                let blockSize = Int(block.le(212, 4))
                if blockSize > 0 { volume.logicalBlockSize = blockSize }
                volume.fileSetICB = longAD(block, at: 248)  // logicalVolumeContentsUse
                let mapCount = Int(block.le(268, 4))
                if mapCount > 0 {
                    // Partition map type 1 is a plain physical partition. Type 2 is virtual,
                    // sparable or metadata, and each needs a translation layer this reader does
                    // not have — so it is named rather than mis-read.
                    let mapType = block.u8(440)
                    if mapType != 1 {
                        volume.unsupportedMap = "partition map type \(mapType)"
                    }
                }
            case 8:                                        // Terminating Descriptor
                break
            default:
                break
            }
            if t.identifier == 6 { sawLogicalVolume = true }
            if t.identifier == 8 { break }
        }
        guard sawPartition, sawLogicalVolume else { throw ImageError.notThisFormat }
        if let unsupported = volume.unsupportedMap {
            throw ImageError.malformed("this UDF volume uses \(unsupported), which this reader does not translate")
        }
        return volume
    }

    /// A UDF d-string: a compression id byte, then 8- or 16-bit characters, in a fixed-width field
    /// whose last byte is the used length.
    private static func dString(_ data: Data, at offset: Int, length: Int) -> String {
        guard offset + length <= data.count, length >= 2 else { return "" }
        let used = Int(data.u8(offset + length - 1))
        guard used >= 2, used <= length else { return "" }
        return characters(data, at: offset, length: used)
    }

    /// The same encoding, but where the length is known rather than trailing (a file identifier).
    private static func characters(_ data: Data, at offset: Int, length: Int) -> String {
        guard length >= 2, offset + length <= data.count else { return "" }
        let compression = data.u8(offset)
        let body = data.subdata(in: (data.startIndex + offset + 1)..<(data.startIndex + offset + length))
        switch compression {
        case 8:
            return String(decoding: body, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        case 16:
            var units: [UInt16] = []
            var i = 0
            while i + 1 < body.count {
                units.append(UInt16(truncatingIfNeeded: body.be(i, 2)))
                i += 2
            }
            return String(decoding: units, as: UTF16.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        default:
            return ""
        }
    }

    /// The 12-byte UDF timestamp.
    private static func timestamp(_ data: Data, at offset: Int) -> Date? {
        guard offset + 12 <= data.count else { return nil }
        var components = DateComponents()
        components.year = Int(Int16(bitPattern: UInt16(truncatingIfNeeded: data.le(offset + 2, 2))))
        components.month = Int(data.u8(offset + 4))
        components.day = Int(data.u8(offset + 5))
        components.hour = Int(data.u8(offset + 6))
        components.minute = Int(data.u8(offset + 7))
        components.second = Int(data.u8(offset + 8))
        guard let year = components.year, year > 1900, year < 3000,
              (1...12).contains(components.month ?? 0), (1...31).contains(components.day ?? 0) else {
            return nil
        }
        // The low twelve bits of the type/timezone field are the offset from UTC in minutes,
        // signed; 0x800 (-2048) means "no offset recorded".
        let raw = Int(UInt16(truncatingIfNeeded: data.le(offset, 2)) & 0x0FFF)
        let minutes = raw >= 2048 ? raw - 4096 : raw
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = (minutes == -2048 ? nil : TimeZone(secondsFromGMT: minutes * 60))
            ?? TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }

    // MARK: - Files

    /// One file's extents plus what the directory needs to know about it.
    private struct FileEntry {
        var isDirectory = false
        var isSymlink = false
        var length: Int64 = 0
        var modified: Date?
        /// Byte ranges in the image, in order.
        var extents: [(offset: Int64, length: Int64)] = []
        /// Contents stored inside the File Entry itself, for a very small file.
        var embedded: Data?
    }

    /// Read the tree.
    static func read(_ reader: ImageReader) throws -> (entries: [UDFEntry], volume: VolumeInfo) {
        let volume = try readVolume(reader)
        guard let fileSetICB = volume.fileSetICB, fileSetICB.byteLength > 0 else {
            throw ImageError.notThisFormat
        }

        func absolute(block: UInt32) -> Int64 {
            (Int64(volume.partitionStart) + Int64(block)) * Int64(volume.logicalBlockSize)
        }

        guard let fileSet = reader.read(at: absolute(block: fileSetICB.block), length: volume.logicalBlockSize),
              let fileSetTag = tag(fileSet), fileSetTag.identifier == 256,
              let rootICB = longAD(fileSet, at: 400) else {
            throw ImageError.malformed("the file set descriptor is missing or unreadable")
        }

        var entries: [UDFEntry] = []
        var visited = Set<UInt32>()
        try walk(reader, volume: volume, icb: rootICB, prefix: "",
                 entries: &entries, visited: &visited, depth: 0, absolute: absolute)

        var info = VolumeInfo()
        info.naming = .udf
        info.volumeID = volume.volumeID
        info.blockSize = volume.logicalBlockSize
        info.blockCount = volume.partitionLength
        return (entries, info)
    }

    private static func walk(_ reader: ImageReader, volume: Volume, icb: LongAD, prefix: String,
                             entries: inout [UDFEntry], visited: inout Set<UInt32>, depth: Int,
                             absolute: (UInt32) -> Int64) throws {
        guard depth < 64, visited.insert(icb.block).inserted else { return }
        guard let entry = readFileEntry(reader, volume: volume, icb: icb, absolute: absolute),
              entry.isDirectory else { return }

        // A directory's contents are File Identifier Descriptors laid end to end across its extents.
        var directory = Data()
        if let embedded = entry.embedded {
            directory = embedded
        } else {
            for extent in entry.extents {
                directory.append(reader.readPartial(at: extent.offset, length: Int(min(extent.length, 1 << 24))))
            }
        }

        var offset = 0
        var children: [(name: String, icb: LongAD)] = []
        while offset + 38 <= directory.count {
            guard let t = tag(directory, at: offset), t.identifier == 257 else { break }
            let implementationUseLength = Int(directory.le(offset + 36, 2))
            let nameLength = Int(directory.u8(offset + 19))
            let characteristics = directory.u8(offset + 18)
            let childICB = longAD(directory, at: offset + 20)
            let nameStart = offset + 38 + implementationUseLength
            let total = 38 + implementationUseLength + nameLength
            let padded = (total + 3) & ~3                     // descriptors are 4-byte aligned
            guard nameStart + nameLength <= directory.count, offset + padded <= directory.count else { break }

            // bit 3 is the parent entry ("..", which the host synthesises), bit 2 is deleted.
            if characteristics & 0x08 == 0, characteristics & 0x04 == 0, nameLength > 0,
               let childICB {
                let name = characters(directory, at: nameStart, length: nameLength)
                if !name.isEmpty, name != ".", name != "..", !name.contains("/") {
                    children.append((name, childICB))
                }
            }
            offset += padded
        }

        for (name, childICB) in children {
            guard let child = readFileEntry(reader, volume: volume, icb: childICB, absolute: absolute) else {
                continue
            }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            entries.append(UDFEntry(
                path: path,
                size: child.isDirectory ? 0 : child.length,
                isDirectory: child.isDirectory,
                isSymlink: child.isSymlink,
                modified: child.modified ?? Date(timeIntervalSince1970: 0),
                extents: child.extents,
                embedded: child.embedded))
            if child.isDirectory {
                try walk(reader, volume: volume, icb: childICB, prefix: path,
                         entries: &entries, visited: &visited, depth: depth + 1, absolute: absolute)
            }
        }
    }

    /// A File Entry (tag 261) or Extended File Entry (tag 266).
    private static func readFileEntry(_ reader: ImageReader, volume: Volume, icb: LongAD,
                                      absolute: (UInt32) -> Int64) -> FileEntry? {
        // A File Entry is at most one logical block; reading two covers an entry whose allocation
        // descriptors run past the block boundary, which large fragmented files do produce.
        let want = volume.logicalBlockSize * 2
        guard let block = reader.read(at: absolute(icb.block), length: want)
                ?? reader.read(at: absolute(icb.block), length: volume.logicalBlockSize),
              let t = tag(block), t.identifier == 261 || t.identifier == 266 else { return nil }

        let extended = t.identifier == 266
        var entry = FileEntry()

        // icbTag.fileType is at +11 within the 20-byte ICB tag, which starts at +16.
        let fileType = block.u8(16 + 11)
        entry.isDirectory = fileType == 4 || fileType == 2   // directory, or stream directory
        entry.isSymlink = fileType == 12
        // icbTag.flags, low three bits: 0 short_ad, 1 long_ad, 2 extended_ad, 3 embedded.
        let adKind = block.u8(16 + 18) & 0x07

        // The two entry shapes differ by 40 bytes of extra timestamps in the extended form.
        let base = extended ? 216 : 176
        entry.length = Int64(block.le(56, 8))
        // Modification time: byte 84 in a File Entry, 92 in an Extended one — the extended form
        // inserts an object size and a creation time ahead of it. Reading the wrong one yields a
        // plausible date from the neighbouring field rather than an error.
        entry.modified = timestamp(block, at: extended ? 92 : 84)
        let extendedAttributeLength = Int(block.le(base - 8, 4))
        let allocationLength = Int(block.le(base - 4, 4))
        let allocationStart = base + extendedAttributeLength

        guard allocationStart >= 0, allocationLength >= 0,
              allocationStart + allocationLength <= block.count else { return entry }

        if adKind == 3 {
            let start = block.startIndex + allocationStart
            entry.embedded = block.subdata(in: start..<(start + allocationLength))
            entry.length = Int64(allocationLength)
            return entry
        }

        var offset = allocationStart
        let end = allocationStart + allocationLength
        while offset < end {
            let length: UInt32
            let blockNumber: UInt32
            let step: Int
            if adKind == 0 {                                  // short_ad
                guard offset + 8 <= end else { break }
                length = UInt32(truncatingIfNeeded: block.le(offset, 4))
                blockNumber = UInt32(truncatingIfNeeded: block.le(offset + 4, 4))
                step = 8
            } else if adKind == 1 {                           // long_ad
                guard offset + 16 <= end, let ad = longAD(block, at: offset) else { break }
                length = ad.length
                blockNumber = ad.block
                step = 16
            } else {
                break                                          // extended_ad: not produced in practice
            }
            offset += step
            let type = UInt8(truncatingIfNeeded: length >> 30)
            let byteLength = Int64(length & 0x3FFF_FFFF)
            // Type 0 is recorded and allocated. Types 1 and 2 are holes — allocated but not
            // written — and reading them as data would return whatever was on the disc before.
            if type == 0, byteLength > 0 {
                entry.extents.append((absolute(blockNumber), byteLength))
            }
        }
        return entry
    }

    /// Decode ECMA-167's path components into an ordinary path.
    ///
    /// A UDF symlink's contents are not a string: they are a list of records, each naming one
    /// component or one of root/./.. by a type code. Handing those bytes to a file manager as the
    /// link target shows a user four bytes of structure in front of every name.
    static func decodeSymlinkTarget(_ data: Data) -> String {
        var components: [String] = []
        var offset = 0
        var absolute = false
        while offset + 4 <= data.count {
            let type = data.u8(offset)
            let length = Int(data.u8(offset + 1))
            guard offset + 4 + length <= data.count else { break }
            switch type {
            case 1, 2: absolute = true          // root, and "mounted volume" — both start at /
            case 3: components.append("..")
            case 4: components.append(".")
            case 5:
                if length > 0 {
                    components.append(characters(data, at: offset + 4, length: length))
                }
            default: break
            }
            offset += 4 + length
        }
        let joined = components.joined(separator: "/")
        if !joined.isEmpty { return absolute ? "/" + joined : joined }

        // Not every writer uses the path-component form. `hdiutil` stores the target as a plain
        // string, and a strict decoder returns nothing at all for those — a symlink with no
        // target, which is worse than the small guess made here. So: if the bytes are printable
        // text, they are the target.
        let raw = String(decoding: data, as: UTF8.self)
        let printable = !raw.isEmpty && raw.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        return printable ? raw : ""
    }
}

/// One UDF entry, flattened.
struct UDFEntry {
    var path: String
    var size: Int64
    var isDirectory: Bool
    var isSymlink: Bool
    var modified: Date
    var extents: [(offset: Int64, length: Int64)]
    var embedded: Data?
}
