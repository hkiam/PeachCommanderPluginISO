// SPDX-License-Identifier: Apache-2.0
// RockRidge.swift - The System Use area of a directory record (SUSP / IEEE P1282).
//
// Plain ISO 9660 names are eight characters, a dot, three more, upper case, plus a `;1` version
// suffix — and nothing else: no symlinks, no permissions, no modification time finer than the
// directory record's own. Rock Ridge is the extension every Unix-written disc carries to say what
// the file was actually called and what it actually was.
//
// The entries are a chain of {two-letter signature, length, version, payload} inside the record's
// tail. Four matter here:
//
//   NM  the real name, possibly continued across several entries
//   PX  POSIX mode, link count, uid, gid — the mode is what tells a symlink from a file
//   TF  timestamps, in a fixed order selected by a flags byte
//   SL  a symbolic link's target, as a list of components
//
// plus CE, which is not a field at all but a pointer to *more* entries in a separate block. A
// reader that ignores CE looks correct on small discs and starts losing names on large ones,
// because the writer only spills into a continuation area when the entries no longer fit — so the
// bug appears exactly when there is the most to lose.

import Foundation

/// What the System Use area of one directory record said.
struct RockRidgeInfo {
    var name: String?
    var mode: UInt32?
    var modified: Date?
    var symlinkTarget: String?
    /// Set when this record is a "relocated" deep directory that should not be listed where it is.
    var relocated = false

    var isSymlink: Bool { (mode ?? 0) & 0xF000 == 0xA000 }
}

enum RockRidge {
    /// Parse the System Use area, following continuation areas.
    ///
    /// `skip` is the SUSP "bytes to skip" from the SP entry in the root directory: some discs put
    /// a fixed prefix in front of every System Use area, and reading the signature out of the
    /// middle of it yields two bytes of nothing that happen not to match anything.
    static func parse(_ area: Data, reader: ImageReader, blockSize: Int, skip: Int = 0) -> RockRidgeInfo {
        var info = RockRidgeInfo()
        var nameParts: [String] = []
        var nameContinues = false
        var linkComponents: [String] = []
        var linkContinues = false
        var pending: [Data] = [area.count > skip ? area.advanced(by: skip) : Data()]
        // A malformed or hostile image can chain continuation areas in a circle. The budget is the
        // termination condition; there is no legitimate disc that needs more than a handful.
        var budget = 16

        while !pending.isEmpty, budget > 0 {
            budget -= 1
            let block = pending.removeFirst()
            var offset = 0
            while offset + 4 <= block.count {
                let sig = String(decoding: block.subdata(in: (block.startIndex + offset)..<(block.startIndex + offset + 2)),
                                 as: UTF8.self)
                let length = Int(block.u8(offset + 2))
                guard length >= 4, offset + length <= block.count else { break }
                // Signature (2), length (1), version (1), then the data — so the payload begins
                // four bytes in, not five. One byte out and PX reads the version as the top of the
                // mode, which turns every file into something with no recognisable type at all.
                let payload = block.subdata(in: (block.startIndex + offset + 4)..<(block.startIndex + offset + length))

                switch sig {
                case "NM":
                    // Flags bit 0 continues into the next NM; bits 1 and 2 mean "." and "..",
                    // which are the entries we synthesise ourselves and must not adopt a name from.
                    let flags = payload.u8(0)
                    if flags & 0x06 == 0 {
                        let part = String(decoding: payload.dropFirst(), as: UTF8.self)
                        if nameContinues { nameParts.append(part) } else { nameParts = [part] }
                        nameContinues = flags & 0x01 != 0
                    }
                case "PX":
                    if let mode = payload.both32(0) { info.mode = mode }
                case "TF":
                    info.modified = parseTF(payload) ?? info.modified
                case "SL":
                    let flags = payload.u8(0)
                    let components = parseSL(payload.dropFirst())
                    if linkContinues { linkComponents += components } else { linkComponents = components }
                    linkContinues = flags & 0x01 != 0
                case "RE":
                    info.relocated = true
                case "CE":
                    // block(both32), offset(both32), length(both32) — the rest of the entries.
                    if let lba = payload.both32(0), let start = payload.both32(8),
                       let len = payload.both32(16), len > 0, len < 1 << 20 {
                        let at = Int64(lba) * Int64(blockSize) + Int64(start)
                        if let more = reader.read(at: at, length: Int(len)) { pending.append(more) }
                    }
                case "ST":
                    offset = block.count       // explicit end of the area
                    continue
                default:
                    break
                }
                offset += length
            }
        }

        if !nameParts.isEmpty { info.name = nameParts.joined() }
        if !linkComponents.isEmpty { info.symlinkTarget = linkComponents.joined(separator: "/") }
        return info
    }

    /// The SUSP "SP" entry in the root directory's own record, giving the skip length.
    static func skipLength(inRootSystemUse area: Data) -> Int {
        var offset = 0
        while offset + 7 <= area.count {
            let sig = String(decoding: area.subdata(in: (area.startIndex + offset)..<(area.startIndex + offset + 2)),
                             as: UTF8.self)
            let length = Int(area.u8(offset + 2))
            guard length >= 4, offset + length <= area.count else { break }
            // Layout: "SP", length, version, 0xBE, 0xEF, LEN_SKP — so the magic is at +4/+5 and the
            // skip length at +6. The magic is checked because two bytes reading "SP" are not
            // otherwise distinguishable from the start of some other extension's entry.
            if sig == "SP", length >= 7, area.u8(offset + 4) == 0xBE, area.u8(offset + 5) == 0xEF {
                return Int(area.u8(offset + 6))
            }
            offset += length
        }
        return 0
    }

    /// TF: a flags byte, then the selected timestamps in a fixed order. We want the modify time,
    /// which is second — after creation, if that one is present.
    private static func parseTF(_ payload: Data) -> Date? {
        let flags = payload.u8(0)
        let long = flags & 0x80 != 0
        let width = long ? 17 : 7
        var offset = 1
        // The order is fixed by the standard: creation, modify, access, attributes, backup,
        // expiration, effective. Only the ones whose bit is set are present, so reaching "modify"
        // means stepping over "creation" if and only if its bit is set.
        if flags & 0x01 != 0 { offset += width }          // creation
        guard flags & 0x02 != 0, offset + width <= payload.count else { return nil }
        let field = payload.subdata(in: (payload.startIndex + offset)..<(payload.startIndex + offset + width))
        return long ? ISO9660.parseLongDate(field) : ISO9660.parseShortDate(field)
    }

    /// SL: component records — a flags byte, a length, then the bytes. Flags name "." and ".." and
    /// "/" rather than spelling them out.
    private static func parseSL(_ payload: Data) -> [String] {
        var components: [String] = []
        var offset = 0
        var isAbsolute = false
        while offset + 2 <= payload.count {
            let flags = payload.u8(offset)
            let length = Int(payload.u8(offset + 1))
            guard offset + 2 + length <= payload.count else { break }
            if flags & 0x08 != 0 {                    // ROOT
                isAbsolute = true
            } else if flags & 0x02 != 0 {
                components.append(".")
            } else if flags & 0x04 != 0 {
                components.append("..")
            } else {
                let body = payload.subdata(in: (payload.startIndex + offset + 2)..<(payload.startIndex + offset + 2 + length))
                components.append(String(decoding: body, as: UTF8.self))
            }
            offset += 2 + length
        }
        if isAbsolute { components.insert("", at: 0) }
        return components
    }
}
