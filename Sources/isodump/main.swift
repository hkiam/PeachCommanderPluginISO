// SPDX-License-Identifier: Apache-2.0
// isodump — list a disc image the way the plugin sees it.
//
// A development aid, not part of the plugin bundle: when a listing disagrees with `bsdtar` or with
// `hdiutil attach`, this is what says which of the three trees the reader chose and what it made
// of each entry, without going through the host at all.
import Foundation
import ISOPlugin

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    print("usage: isodump <image.iso> …")
    exit(2)
}
for path in paths {
    print("=== \(path)")
    do {
        let image = try DiscImage(path: path)
        print(image.volume.report)
        for entry in image.entries {
            let kind = entry.isDirectory ? "d" : (entry.isSymlink ? "l" : "-")
            print("  \(kind) \(String(format: "%10lld", entry.size))  \(entry.path)")
        }
    } catch {
        print("  error: \(error)")
    }
}
