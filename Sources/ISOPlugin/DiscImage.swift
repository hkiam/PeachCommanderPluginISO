// SPDX-License-Identifier: Apache-2.0
// DiscImage.swift - One tree out of a disc that may describe itself two or three times over.
//
// A disc can carry an ISO 9660 tree and a UDF tree at once, and they need not agree. A Windows
// installer's ISO half is often a stub that exists only so the disc is readable at all; a video
// DVD's UDF half is the real one; a Linux disc usually has no UDF and its ISO half carries Rock
// Ridge. There is no field that says which one the author meant.
//
// So the rule is stated rather than guessed at: **read both, keep the one that lists more files,
// and let UDF win a tie** — UDF carries the longer names and real timestamps. The choice is
// recorded in the `.disc-info.txt` at the root, so a user who disagrees can at least see what
// happened rather than wonder where their files went.

import Foundation

public struct DiscEntry {
    public enum Source {
        /// Byte ranges in the image file, in order.
        case extents([(offset: Int64, length: Int64)])
        /// Contents the plugin produced or found inline.
        case bytes(Data)
        case none
    }

    public var path: String
    public var size: Int64
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var modified: Date
    public var source: Source
}

/// A disc image, parsed once.
public final class DiscImage {
    /// The synthetic directory boot images are listed under. Brackets because no ISO 9660 or
    /// Joliet writer can produce them, so it cannot collide with a directory that is really there.
    public static let bootDirectory = "[boot]"
    public static let infoFileName = ".disc-info.txt"

    let reader: ImageReader
    public let entries: [DiscEntry]
    public let volume: VolumeInfo
    private let index: [String: Int]

    public init(path: String) throws {
        let reader = try ImageReader(path: path)
        self.reader = reader

        let isoResult = (try? ISO9660.read(reader)).map { result in
            (entries: result.entries.map { entry -> DiscEntry in
                // A symlink's bytes are its target, not the directory record's extent — see
                // ISOEntry.symlinkTarget. Its size follows from the same place, so that what the
                // panel shows and what a copy produces are the same thing.
                if entry.isSymlink {
                    // Rock Ridge's SL entry when there is one. There often is not: `hdiutil` marks
                    // the link through the PX mode and Apple's own AA entry and then stores the
                    // target as the file's ordinary contents, so a reader that only understands SL
                    // reports a symlink pointing nowhere.
                    var target = entry.symlinkTarget ?? ""
                    if target.isEmpty, let offset = entry.dataOffset, entry.size > 0, entry.size < 4096 {
                        let raw = reader.readPartial(at: offset, length: Int(entry.size))
                        let text = String(decoding: raw, as: UTF8.self)
                        if !text.isEmpty,
                           text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
                            target = text
                        }
                    }
                    let bytes = Data(target.utf8)
                    return DiscEntry(path: entry.path, size: Int64(bytes.count), isDirectory: false,
                                     isSymlink: true, modified: entry.modified, source: .bytes(bytes))
                }
                return DiscEntry(path: entry.path, size: entry.size, isDirectory: entry.isDirectory,
                                 isSymlink: entry.isSymlink, modified: entry.modified,
                                 source: entry.isDirectory || entry.isSymlink
                                     ? .none
                                     : .extents([(entry.dataOffset ?? 0, entry.size)]))
            }, volume: result.volume)
        }

        let udfResult: (entries: [DiscEntry], volume: VolumeInfo)? = {
            guard UDF.looksLikeUDF(reader) else { return nil }
            guard let result = try? UDF.read(reader) else { return nil }
            return (result.entries.map { entry -> DiscEntry in
                if entry.isSymlink {
                    // A UDF symlink's contents are ECMA-167 path components, not a path. Decoded
                    // here so the panel shows "../bin/sh" rather than the record bytes around it.
                    var raw = entry.embedded ?? Data()
                    if raw.isEmpty {
                        for extent in entry.extents {
                            raw.append(reader.readPartial(at: extent.offset, length: Int(min(extent.length, 1 << 16))))
                        }
                    }
                    let bytes = Data(UDF.decodeSymlinkTarget(raw).utf8)
                    return DiscEntry(path: entry.path, size: Int64(bytes.count), isDirectory: false,
                                     isSymlink: true, modified: entry.modified, source: .bytes(bytes))
                }
                return DiscEntry(path: entry.path, size: entry.size, isDirectory: entry.isDirectory,
                                 isSymlink: entry.isSymlink, modified: entry.modified,
                                 source: entry.isDirectory
                                     ? .none
                                     : (entry.embedded.map { DiscEntry.Source.bytes($0) } ?? .extents(entry.extents)))
            }, volume: result.volume)
        }()

        let chosen: (entries: [DiscEntry], volume: VolumeInfo)
        switch (isoResult, udfResult) {
        case (nil, nil):
            throw ImageError.notThisFormat
        case (let iso?, nil):
            chosen = iso
        case (nil, let udf?):
            chosen = udf
        case (let iso?, let udf?):
            chosen = udf.entries.count >= iso.entries.count ? udf : iso
        }

        var all = chosen.entries
        var volume = chosen.volume
        // The primary descriptor's fields are richer than UDF's, so keep them when both were read.
        if let iso = isoResult?.volume, chosen.volume.naming == .udf {
            volume.publisher = iso.publisher
            volume.preparer = iso.preparer
            volume.application = iso.application
            volume.created = iso.created
            volume.systemID = iso.systemID
            if volume.volumeID.isEmpty { volume.volumeID = iso.volumeID }
        }

        // Boot images, which live outside both trees.
        let bootImages = ElTorito.read(reader)
        if !bootImages.isEmpty {
            all.append(DiscEntry(path: Self.bootDirectory, size: 0, isDirectory: true,
                                 isSymlink: false, modified: volume.created ?? Date(timeIntervalSince1970: 0),
                                 source: .none))
            for image in bootImages {
                all.append(DiscEntry(
                    path: "\(Self.bootDirectory)/\(image.name)",
                    size: image.size,
                    isDirectory: false,
                    isSymlink: false,
                    modified: volume.created ?? Date(timeIntervalSince1970: 0),
                    source: .extents([(Int64(image.lba) * 2048, image.size)])))
            }
        }

        let report = Data(volume.report.utf8)
        all.append(DiscEntry(path: Self.infoFileName, size: Int64(report.count), isDirectory: false,
                             isSymlink: false, modified: volume.created ?? Date(timeIntervalSince1970: 0),
                             source: .bytes(report)))

        self.entries = all
        self.volume = volume
        var index: [String: Int] = [:]
        index.reserveCapacity(all.count)
        for (i, entry) in all.enumerated() where index[entry.path] == nil { index[entry.path] = i }
        self.index = index
    }

    /// Up to `length` bytes of `path` from `offset`. Empty at or past the end.
    public func read(path: String, offset: Int64, length: Int64) -> Data? {
        guard let i = index[path] else { return nil }
        let entry = entries[i]
        guard !entry.isDirectory, offset >= 0, length > 0 else { return Data() }

        switch entry.source {
        case .none:
            return Data()
        case .bytes(let data):
            guard offset < Int64(data.count) else { return Data() }
            let start = Int(offset)
            let end = Int(min(Int64(data.count), offset + length))
            return data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))
        case .extents(let extents):
            var out = Data()
            var remaining = length
            var cursor: Int64 = 0
            for extent in extents {
                if remaining <= 0 { break }
                let extentEnd = cursor + extent.length
                if offset >= extentEnd { cursor = extentEnd; continue }
                let within = max(offset - cursor, 0)
                let take = min(extent.length - within, remaining)
                if take > 0 {
                    out.append(reader.readPartial(at: extent.offset + within, length: Int(take)))
                    remaining -= take
                }
                cursor = extentEnd
            }
            // The declared size wins over the extents when they disagree: an extent rounded up to
            // a block boundary would otherwise hand back the padding as file content.
            let limit = max(entry.size - offset, 0)
            if Int64(out.count) > limit { out = out.prefix(Int(limit)) }
            return out
        }
    }

    /// Whether the file at `path` is a disc image this plugin can open, judged by its contents.
    ///
    /// Cheap on purpose — the host asks this of every file whose extension matched nothing, so it
    /// reads two sectors and no more.
    public static func canRead(path: String) -> Bool {
        guard let reader = try? ImageReader(path: path) else { return false }
        return ISO9660.looksLikeISO(reader) || UDF.looksLikeUDF(reader)
    }
}
