// SPDX-License-Identifier: Apache-2.0
// VolumeInfo.swift - What the disc says about itself, and the note the plugin leaves in the tree.
//
// The volume label, who prepared it, when, and which of the three naming schemes the reader chose.
// None of it is a file, so it is surfaced as one: a small `.disc-info.txt` at the root of the
// mounted image, which is a thing a file manager can already show, search and copy — as opposed to
// a dialog nobody would go looking for.
//
// It is opt-out rather than opt-in: an ISO usually has fewer than a dozen top-level entries, one
// more costs nothing, and the question "what disc is this" is the first one anybody has.

import Foundation

public struct VolumeInfo {
    public enum Naming: String {
        case iso9660 = "ISO 9660"
        case joliet = "Joliet"
        case rockRidge = "Rock Ridge"
        case udf = "UDF"
    }

    public var volumeID: String = ""
    public var jolietVolumeID: String?
    public var systemID: String = ""
    public var volumeSetID: String = ""
    public var publisher: String = ""
    public var preparer: String = ""
    public var application: String = ""
    public var created: Date?
    public var naming: Naming = .iso9660
    public var blockSize: Int = 2048
    public var blockCount: UInt32 = 0

    public init() {}

    /// Read the fields out of a primary volume descriptor.
    public init(from primary: Data, joliet: Data?, naming: Naming) {
        self.naming = naming
        systemID = primary.strA(8, 32)
        volumeID = primary.strA(40, 32)
        blockCount = primary.both32(80) ?? 0
        blockSize = Int(primary.both16(128) ?? 2048)
        volumeSetID = primary.strA(190, 128)
        publisher = primary.strA(318, 128)
        preparer = primary.strA(446, 128)
        application = primary.strA(574, 128)
        if primary.count >= 830 {
            created = ISO9660.parseLongDate(
                primary.subdata(in: (primary.startIndex + 813)..<(primary.startIndex + 830)))
        }
        if let joliet { jolietVolumeID = joliet.strUCS2(40, 32) }
    }

    /// The `.disc-info.txt` body.
    public var report: String {
        var lines: [String] = []
        func row(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            // Padded by character count rather than `padding(toLength:)`, which counts UTF-16
            // units — a translated label with an umlaut in it would come out a column short.
            let pad = String(repeating: " ", count: max(0, 16 - label.count))
            lines.append("\(label)\(pad) \(value)")
        }
        lines.append(L("Disc image"))
        lines.append("==========")
        lines.append("")
        row(L("Volume"), volumeID.isEmpty ? jolietVolumeID : volumeID)
        if let jolietVolumeID, jolietVolumeID != volumeID { row(L("Volume (Joliet)"), jolietVolumeID) }
        row(L("Volume set"), volumeSetID)
        row(L("System"), systemID)
        row(L("Publisher"), publisher)
        row(L("Prepared by"), preparer)
        row(L("Application"), application)
        if let created {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(identifier: "UTC")
            row(L("Created"), formatter.string(from: created))
        }
        row(L("Names read as"), naming.rawValue)
        if blockCount > 0 {
            let bytes = Int64(blockCount) * Int64(blockSize)
            row(L("Size"), "\(blockCount) × \(blockSize) \(L("bytes")) = \(bytes) \(L("bytes"))")
        }
        lines.append("")
        lines.append(L("Listed by the Peach Commander ISO / UDF plugin."))
        return lines.joined(separator: "\n") + "\n"
    }
}
