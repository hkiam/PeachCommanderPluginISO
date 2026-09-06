// SPDX-License-Identifier: Apache-2.0
// ElTorito.swift - The boot images a bootable disc carries, which nothing else exposes.
//
// A bootable CD or DVD keeps its boot image *outside* the ISO 9660 directory tree: a boot record
// volume descriptor points at a boot catalog, and the catalog's entries give a start sector and a
// length. Mount the disc and the file is not there; list it with bsdtar and the file is not there.
// It is one of the few things about an ISO that a file manager can show and a general-purpose
// archive reader cannot, which is exactly why it is worth the hundred lines.
//
// The images are surfaced under a synthetic `[boot]/` directory. The brackets are deliberate: a
// name no ISO 9660 or Joliet writer produces, so it cannot collide with a real directory.
//
// One honest limit, recorded here rather than discovered later: for a no-emulation boot the
// catalog's sector count is what the writer chose to put there, and many writers write 4 (2 KB)
// regardless of how large the image actually is, because the firmware only needs the first part.
// The size reported here is that number. It is what the disc claims, not necessarily what the
// author intended, and there is no field that says the latter.

import Foundation

struct BootImage {
    var name: String
    var lba: UInt32
    var size: Int64
    var platform: String
    var mediaType: String
    var bootable: Bool
}

enum ElTorito {
    /// The boot images the disc declares, or an empty array when it is not bootable.
    static func read(_ reader: ImageReader) -> [BootImage] {
        guard let catalogLBA = bootCatalogLBA(reader) else { return [] }
        guard let catalog = reader.read(at: Int64(catalogLBA) * 2048, length: 2048) else { return [] }

        // The first entry validates the catalog: header id 1, and the two key bytes at the end.
        guard catalog.u8(0) == 0x01, catalog.u8(30) == 0x55, catalog.u8(31) == 0xAA else { return [] }

        var images: [BootImage] = []
        var platform = platformName(catalog.u8(1))
        var offset = 32
        var index = 0
        while offset + 32 <= catalog.count {
            let entry = catalog.subdata(in: (catalog.startIndex + offset)..<(catalog.startIndex + offset + 32))
            offset += 32
            let indicator = entry.u8(0)

            // 0x90 / 0x91 begin a section for another platform; 0x91 is the last one.
            if indicator == 0x90 || indicator == 0x91 {
                platform = platformName(entry.u8(1))
                continue
            }
            // 0x88 bootable, 0x00 not bootable. Anything else ends the catalog: the remaining
            // bytes of the sector are zero padding, and reading them as entries invents images.
            guard indicator == 0x88 || indicator == 0x00 else { break }

            let media = entry.u8(1)
            let sectors = Int64(entry.le(6, 2))
            let lba = UInt32(truncatingIfNeeded: entry.le(8, 4))
            guard lba > 0, Int64(lba) * 2048 < reader.size else { continue }

            index += 1
            let (mediaName, emulatedSize) = mediaDescription(media)
            // Virtual sectors are 512 bytes regardless of the disc's 2048-byte ones.
            var size = sectors * 512
            if let emulatedSize, size < emulatedSize { size = emulatedSize }
            size = min(size, reader.size - Int64(lba) * 2048)

            images.append(BootImage(
                name: "\(index)-\(platform.lowercased())-\(mediaName).img",
                lba: lba,
                size: max(size, 0),
                platform: platform,
                mediaType: mediaName,
                bootable: indicator == 0x88))
        }
        return images
    }

    /// The boot record volume descriptor (type 0) names El Torito and points at the catalog.
    private static func bootCatalogLBA(_ reader: ImageReader) -> UInt32? {
        var offset = ISO9660.descriptorStart
        for _ in 0..<64 {
            guard let block = reader.read(at: offset, length: 2048) else { return nil }
            guard block.strA(1, 5) == "CD001" else { return nil }
            let type = block.u8(0)
            if type == 255 { return nil }
            if type == 0, block.strA(7, 23) == "EL TORITO SPECIFICATION" {
                let lba = UInt32(truncatingIfNeeded: block.le(71, 4))
                return lba > 0 ? lba : nil
            }
            offset += 2048
        }
        return nil
    }

    private static func platformName(_ id: UInt8) -> String {
        switch id {
        case 0x00: return "x86"
        case 0x01: return "PowerPC"
        case 0x02: return "Mac"
        case 0xEF: return "EFI"
        default:   return "platform\(id)"
        }
    }

    /// Media type, and the size the emulation implies when the catalog understates it.
    private static func mediaDescription(_ media: UInt8) -> (String, Int64?) {
        switch media & 0x0F {
        case 0: return ("noemul", nil)
        case 1: return ("floppy1200", 1_200 * 1024)
        case 2: return ("floppy1440", 1_440 * 1024)
        case 3: return ("floppy2880", 2_880 * 1024)
        case 4: return ("harddisk", nil)
        default: return ("media\(media)", nil)
        }
    }
}
