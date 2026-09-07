// SPDX-License-Identifier: Apache-2.0
// isodump — list a disc image the way the plugin sees it.
//
// A development aid, not part of the plugin bundle: when a listing disagrees with `bsdtar` or with
// `hdiutil attach`, this is what says which of the three trees the reader chose and what it made
// of each entry, without going through the host at all.
import Foundation
import ISOPlugin

var arguments = Array(CommandLine.arguments.dropFirst())
// `--read` also pulls every entry's bytes. Listing exercises the directory parsing; reading
// exercises the extent arithmetic, which is the half that trusts numbers out of the image most —
// so it is the half worth pointing a corrupted file at.
let readContents = arguments.contains("--read")
arguments.removeAll { $0 == "--read" }
let quiet = arguments.contains("--quiet")
arguments.removeAll { $0 == "--quiet" }

guard !arguments.isEmpty else {
    print("usage: isodump [--read] [--quiet] <image.iso> …")
    exit(2)
}

for path in arguments {
    if !quiet { print("=== \(path)") }
    do {
        let image = try DiscImage(path: path)
        if !quiet { print(image.volume.report) }
        var total: Int64 = 0
        for entry in image.entries {
            let kind = entry.isDirectory ? "d" : (entry.isSymlink ? "l" : "-")
            if !quiet {
                print("  \(kind) \(String(format: "%10lld", entry.size))  \(entry.path)")
            }
            guard readContents, !entry.isDirectory else { continue }
            var offset: Int64 = 0
            while offset < entry.size {
                guard let chunk = image.read(path: entry.path, offset: offset, length: 1 << 16),
                      !chunk.isEmpty else { break }
                offset += Int64(chunk.count)
                total += Int64(chunk.count)
            }
        }
        if readContents { print("  read \(total) bytes from \(image.entries.count) entries") }
    } catch {
        print("  error: \(error)")
    }
}
