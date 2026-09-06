// SPDX-License-Identifier: Apache-2.0
// ISO9660.swift - Volume descriptors, directory records, and picking which name to believe.
//
// A disc can carry the same directory tree described three ways at once: plain ISO 9660 with
// eight-character upper-case names, Joliet with UCS-2 names in a second descriptor, and Rock Ridge
// with POSIX names hidden in the tail of each ISO record. Discs written on a Mac or a Linux box
// usually have all three, and they do not always agree.
//
// The order this reader trusts them in is Rock Ridge, then Joliet, then plain — because Rock Ridge
// is the only one that also carries the mode bits, and losing "this is a symlink" is worse than
// losing a nicer spelling of a name. `bsdtar` makes the same choice; `hdiutil attach` does not
// always, which is why the tests compare against both rather than either.

import Foundation

/// One entry in the image, flattened out of the directory tree.
struct ISOEntry {
    var path: String            // '/'-separated, no leading slash
    var size: Int64
    var isDirectory: Bool
    var isSymlink: Bool
    var modified: Date
    var extentLBA: UInt32
    var blockSize: Int
    /// Where a symlink points, as Rock Ridge recorded it.
    ///
    /// Carried here rather than left implicit because the directory record's data length for a
    /// symlink is not its contents: reporting that length and then serving nothing produces an
    /// empty file when somebody copies the link out, which is the one outcome worse than either
    /// refusing or resolving it.
    var symlinkTarget: String?
    /// Where the bytes are. Nil for a directory or a symlink.
    var dataOffset: Int64? { isDirectory ? nil : Int64(extentLBA) * Int64(blockSize) }
}

/// A parsed volume descriptor we care about.
private struct VolumeDescriptor {
    var type: UInt8
    var rootRecord: Data
    var blockSize: Int
    var volumeID: String
    var isJoliet: Bool
    var raw: Data
}

enum ISO9660 {
    static let sectorSize = 2048
    /// Volume descriptors start here, always: 16 sectors of "system area" first.
    static let descriptorStart: Int64 = 16 * 2048

    /// Whether `reader` opens an ISO 9660 volume — the two bytes of magic the format is known by.
    static func looksLikeISO(_ reader: ImageReader) -> Bool {
        guard let block = reader.read(at: descriptorStart, length: 8) else { return false }
        return block.strA(1, 5) == "CD001"
    }

    /// Read the whole tree.
    ///
    /// Returns the entries in directory order, parents before children, which is what the host's
    /// flat entry list wants and what makes the tree it rebuilds come out in the order the disc
    /// was written rather than in hash order.
    static func read(_ reader: ImageReader) throws -> (entries: [ISOEntry], volume: VolumeInfo) {
        let descriptors = try readDescriptors(reader)
        guard let primary = descriptors.first(where: { $0.type == 1 }) else {
            throw ImageError.notThisFormat
        }

        // Is there a Joliet supplementary descriptor? Its escape sequence says so.
        let joliet = descriptors.first { $0.isJoliet }

        // Rock Ridge lives in the *primary* tree, so whether it is present decides which tree to
        // walk before any name is read.
        //
        // Both answers come from the root directory itself, not from the copy of its record inside
        // the volume descriptor: that copy is 34 bytes with no System Use area at all, and looking
        // for SUSP in it finds nothing on every disc ever written — which reads as "no Rock Ridge"
        // and quietly costs the symlinks and the real names on every disc that has them.
        let probe = probeRockRidge(reader, descriptor: primary)

        // Rock Ridge and Joliet answer *different* questions, and conflating them is how a disc
        // written by hdiutil ends up listed in upper case. Rock Ridge always decides the
        // attributes — a symlink is a symlink whatever it is called. It decides the *names* only
        // when it actually carries any: `hdiutil` writes PX and TF but no NM at all, so its Rock
        // Ridge names are the plain ISO 9660 ones, and Joliet's are the real ones. `bsdtar` makes
        // the same distinction, which is why the listings agree.
        var entries: [ISOEntry] = []
        var seen = Set<UInt32>()
        try walk(reader, descriptor: primary, record: primary.rootRecord, prefix: "",
                 useRockRidge: probe.present, skip: probe.skip,
                 entries: &entries, visited: &seen, depth: 0)

        var naming: VolumeInfo.Naming = probe.present ? .rockRidge : .iso9660
        if !probe.hasNames, let joliet {
            var jolietEntries: [ISOEntry] = []
            var jolietSeen = Set<UInt32>()
            try walk(reader, descriptor: joliet, record: joliet.rootRecord, prefix: "",
                     useRockRidge: false, skip: 0,
                     entries: &jolietEntries, visited: &jolietSeen, depth: 0)
            if jolietEntries.count >= entries.count {
                entries = merge(names: jolietEntries, attributes: entries)
                naming = probe.present ? .rockRidge : .joliet
            }
        }

        let volume = VolumeInfo(from: primary.raw, joliet: joliet?.raw, naming: naming)
        return (entries, volume)
    }

    /// Take the names and structure from one tree and the attributes from the other.
    ///
    /// The two describe the same files, and the extent each entry points at is what says so. An
    /// extent of zero is not an identity — every empty file on the disc shares it — so those keep
    /// whatever the name tree said.
    private static func merge(names: [ISOEntry], attributes: [ISOEntry]) -> [ISOEntry] {
        var byExtent: [UInt32: ISOEntry] = [:]
        for entry in attributes where entry.extentLBA != 0 {
            if byExtent[entry.extentLBA] == nil { byExtent[entry.extentLBA] = entry }
        }
        return names.map { entry in
            guard entry.extentLBA != 0, let attributed = byExtent[entry.extentLBA] else { return entry }
            var merged = entry
            merged.isSymlink = attributed.isSymlink
            merged.symlinkTarget = attributed.symlinkTarget
            merged.modified = attributed.modified
            return merged
        }
    }

    // MARK: - Volume descriptors

    private static func readDescriptors(_ reader: ImageReader) throws -> [VolumeDescriptor] {
        var out: [VolumeDescriptor] = []
        var offset = descriptorStart
        // The sequence is terminated by a type-255 descriptor. The cap is for an image whose
        // terminator was lost: without it a truncated disc walks to the end of the file one sector
        // at a time, and a "not an ISO" answer should be cheap.
        for _ in 0..<64 {
            guard let block = reader.read(at: offset, length: sectorSize) else { break }
            guard block.strA(1, 5) == "CD001" else {
                if out.isEmpty { throw ImageError.notThisFormat }
                break
            }
            let type = block.u8(0)
            if type == 255 { break }
            if type == 1 || type == 2 {
                let blockSize = Int(block.both16(128) ?? 2048)
                let root = block.subdata(in: (block.startIndex + 156)..<(block.startIndex + 156 + 34))
                let escape = block.subdata(in: (block.startIndex + 88)..<(block.startIndex + 88 + 32))
                out.append(VolumeDescriptor(
                    type: type,
                    rootRecord: root,
                    blockSize: blockSize > 0 ? blockSize : 2048,
                    volumeID: type == 2 && isJolietEscape(escape) ? block.strUCS2(40, 32) : block.strA(40, 32),
                    isJoliet: type == 2 && isJolietEscape(escape),
                    raw: block))
            }
            offset += Int64(sectorSize)
        }
        guard !out.isEmpty else { throw ImageError.notThisFormat }
        return out
    }

    /// Joliet announces itself with one of three UCS-2 escape sequences.
    private static func isJolietEscape(_ escape: Data) -> Bool {
        guard escape.count >= 3, escape.u8(0) == 0x25, escape.u8(1) == 0x2F else { return false }
        return [0x40, 0x43, 0x45].contains(escape.u8(2))     // @ C E — UCS-2 levels 1, 2, 3
    }

    // MARK: - Directory records

    /// The System Use area: whatever follows the name (and its padding byte) in a record.
    private static func systemUseArea(of record: Data) -> Data {
        let recordLength = Int(record.u8(0))
        let nameLength = Int(record.u8(32))
        var start = 33 + nameLength
        if nameLength % 2 == 0 { start += 1 }              // padding to an even boundary
        guard recordLength > start, recordLength <= record.count else { return Data() }
        return record.subdata(in: (record.startIndex + start)..<(record.startIndex + recordLength))
    }

    /// The SUSP skip length, and whether this disc carries Rock Ridge at all.
    ///
    /// Both are read from the root directory's own "." record and the entries beside it. The "."
    /// record is where SUSP puts its SP entry — the one that says how many bytes to skip at the
    /// front of every System Use area — and the entries after it are where PX and NM appear if
    /// they appear anywhere.
    ///
    /// Asked once, of the root, rather than per record: Rock Ridge is a property of the disc, and
    /// deciding per entry would produce a tree with two naming conventions in it.
    private static func probeRockRidge(_ reader: ImageReader,
                                       descriptor: VolumeDescriptor) -> (skip: Int, present: Bool, hasNames: Bool) {
        guard let lba = descriptor.rootRecord.both32(2),
              let length = descriptor.rootRecord.both32(10),
              length > 0,
              let block = reader.read(at: Int64(lba) * Int64(descriptor.blockSize),
                                      length: Int(min(length, UInt32(descriptor.blockSize)))) else {
            return (0, false, false)
        }

        var skip = 0
        var present = false
        var hasNames = false
        var offset = 0
        var isFirstRecord = true
        while offset < block.count {
            let recordLength = Int(block.u8(offset))
            if recordLength == 0 { break }
            guard offset + recordLength <= block.count, recordLength >= 33 else { break }
            let record = block.subdata(in: (block.startIndex + offset)..<(block.startIndex + offset + recordLength))
            let area = systemUseArea(of: record)
            if isFirstRecord {
                skip = RockRidge.skipLength(inRootSystemUse: area)
                isFirstRecord = false
            }
            if area.count > skip {
                let info = RockRidge.parse(area, reader: reader, blockSize: descriptor.blockSize, skip: skip)
                if info.name != nil { hasNames = true }
                if info.name != nil || info.mode != nil { present = true }
            }
            offset += recordLength
            // Keep scanning even after `present`: whether *any* record carries a name is a
            // separate question from whether the extension is there at all, and stopping at the
            // first PX would answer it wrongly for every disc that puts a plain entry first.
            if present && hasNames { break }
        }
        return (skip, present, hasNames)
    }

    private static func walk(_ reader: ImageReader, descriptor: VolumeDescriptor, record: Data,
                             prefix: String, useRockRidge: Bool, skip: Int,
                             entries: inout [ISOEntry], visited: inout Set<UInt32>, depth: Int) throws {
        guard depth < 64 else { return }                   // a cycle, or a disc nobody should trust
        guard let lba = record.both32(2), let length = record.both32(10), length > 0 else { return }
        guard visited.insert(lba).inserted else { return }

        let blockSize = descriptor.blockSize
        guard let content = reader.read(at: Int64(lba) * Int64(blockSize), length: Int(length)) else { return }

        var children: [(record: Data, name: String, info: RockRidgeInfo)] = []
        var offset = 0
        while offset < content.count {
            let recordLength = Int(content.u8(offset))
            if recordLength == 0 {
                // A record of length zero means "no more in this logical block"; the next one
                // starts at the next block boundary. Treating it as the end of the directory is
                // the bug that truncates every directory spanning more than one block.
                let nextBlock = ((offset / blockSize) + 1) * blockSize
                if nextBlock <= offset || nextBlock >= content.count { break }
                offset = nextBlock
                continue
            }
            guard offset + recordLength <= content.count, recordLength >= 33 else { break }
            let child = content.subdata(in: (content.startIndex + offset)..<(content.startIndex + offset + recordLength))
            offset += recordLength

            let nameLength = Int(child.u8(32))
            guard nameLength > 0 else { continue }
            // "." and ".." are stored as single bytes 0x00 and 0x01. The host synthesises both.
            if nameLength == 1, child.u8(33) <= 1 { continue }

            let area = systemUseArea(of: child)
            let info = useRockRidge && area.count > skip
                ? RockRidge.parse(area, reader: reader, blockSize: blockSize, skip: skip)
                : RockRidgeInfo()
            if info.relocated { continue }

            let rawName = descriptor.isJoliet
                ? child.strUCS2(33, nameLength)
                : child.strA(33, nameLength)
            let name = info.name ?? stripVersion(rawName)
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { continue }
            children.append((child, name, info))
        }

        for (child, name, info) in children {
            let flags = child.u8(25)
            let isDirectory = flags & 0x02 != 0
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let size = Int64(child.both32(10) ?? 0)
            entries.append(ISOEntry(
                path: path,
                size: isDirectory ? 0 : size,
                isDirectory: isDirectory,
                isSymlink: info.isSymlink,
                modified: info.modified ?? parseRecordDate(child) ?? Date(timeIntervalSince1970: 0),
                extentLBA: child.both32(2) ?? 0,
                blockSize: blockSize,
                symlinkTarget: info.symlinkTarget))
            if isDirectory {
                try walk(reader, descriptor: descriptor, record: child, prefix: path,
                         useRockRidge: useRockRidge, skip: skip,
                         entries: &entries, visited: &visited, depth: depth + 1)
            }
        }
    }

    /// `README.TXT;1` → `README.TXT`, and `DIR.;1` → `DIR`.
    ///
    /// The trailing dot is separate from the version: ISO 9660 stores a name with no extension as
    /// `NAME.`, so stripping only the `;1` leaves a directory called `bin.`.
    static func stripVersion(_ raw: String) -> String {
        var name = raw
        if let semicolon = name.lastIndex(of: ";") { name = String(name[name.startIndex..<semicolon]) }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    // MARK: - Dates

    /// The 7-byte binary date in a directory record and in Rock Ridge's short form.
    static func parseShortDate(_ field: Data) -> Date? {
        guard field.count >= 7 else { return nil }
        var components = DateComponents()
        components.year = 1900 + Int(field.u8(0))
        components.month = Int(field.u8(1))
        components.day = Int(field.u8(2))
        components.hour = Int(field.u8(3))
        components.minute = Int(field.u8(4))
        components.second = Int(field.u8(5))
        guard (1...12).contains(components.month ?? 0), (1...31).contains(components.day ?? 0) else {
            return nil
        }
        // Byte 6 is the offset from GMT in fifteen-minute intervals, signed.
        let quarterHours = Int(Int8(bitPattern: field.u8(6)))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: quarterHours * 15 * 60) ?? TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }

    /// The 17-byte decimal date in a volume descriptor and Rock Ridge's long form.
    static func parseLongDate(_ field: Data) -> Date? {
        guard field.count >= 16 else { return nil }
        let digits = field.strA(0, 16)
        guard digits.count == 16, digits.allSatisfy(\.isNumber) else { return nil }
        func number(_ start: Int, _ length: Int) -> Int {
            let s = digits.index(digits.startIndex, offsetBy: start)
            let e = digits.index(s, offsetBy: length)
            return Int(digits[s..<e]) ?? 0
        }
        var components = DateComponents()
        components.year = number(0, 4)
        components.month = number(4, 2)
        components.day = number(6, 2)
        components.hour = number(8, 2)
        components.minute = number(10, 2)
        components.second = number(12, 2)
        guard components.year! > 1900, (1...12).contains(components.month!), (1...31).contains(components.day!) else {
            return nil
        }
        let quarterHours = field.count >= 17 ? Int(Int8(bitPattern: field.u8(16))) : 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: quarterHours * 15 * 60) ?? TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }

    private static func parseRecordDate(_ record: Data) -> Date? {
        guard record.count >= 25 else { return nil }
        return parseShortDate(record.subdata(in: (record.startIndex + 18)..<(record.startIndex + 25)))
    }
}
