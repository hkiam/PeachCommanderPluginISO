// SPDX-License-Identifier: Apache-2.0
// DiscImageTests.swift - The reader, against images this plugin did not write.
//
// Two rules the tests here follow, both of them the application repository's own doctrine:
//
//   * Fixtures come from a third party. Every image is produced by `hdiutil`, and the listings are
//     compared against `bsdtar` — a second, independent reader. A reader and a writer from the
//     same hand agree with each other and prove nothing.
//
//   * The interesting case is the one the alternative cannot do. `udf.iso` is the fixture that
//     matters most: bsdtar opens nothing in it at all, which is the whole reason this plugin is
//     worth installing over the built-in path.

import XCTest
@testable import ISOPlugin

final class DiscImageTests: XCTestCase {
    /// Fixtures are copied into the test bundle by SwiftPM (see Package.swift).
    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) else {
            throw XCTSkip("fixture \(name) is missing — run Tools/make-fixtures.sh")
        }
        return url.path
    }

    private func image(_ name: String) throws -> DiscImage {
        try DiscImage(path: try fixture(name))
    }

    /// Paths of the real entries, with the plugin's own additions filtered out.
    private func realPaths(_ image: DiscImage) -> Set<String> {
        Set(image.entries.map(\.path)
            .filter { $0 != DiscImage.infoFileName && !$0.hasPrefix(DiscImage.bootDirectory) })
    }

    // MARK: - Listing

    func test_iso9660_listsTheTree() throws {
        let image = try image("iso9660.iso")
        XCTAssertEqual(realPaths(image), [
            "A-DIRECTORY-WITH-A-LONG-NAME",
            "A-DIRECTORY-WITH-A-LONG-NAME/LONG NAME WITH SPACES.TXT",
            "BIG.BIN",
            "LINK-TO-README",
            "README.TXT",
            "SUBDIR",
            "SUBDIR/NESTED.TXT",
        ])
        XCTAssertEqual(image.volume.naming, .rockRidge,
                       "hdiutil writes Rock Ridge alongside plain ISO 9660, and it must be preferred")
    }

    /// UDF keeps the names the files actually had; the ISO 9660 half of the same tree cannot.
    func test_udf_keepsTheRealNames() throws {
        let image = try image("udf.iso")
        XCTAssertEqual(image.volume.naming, .udf)
        let paths = realPaths(image)
        XCTAssertTrue(paths.contains("a-directory-with-a-long-name/long name with spaces.txt"),
                      "got \(paths.sorted())")
        XCTAssertTrue(paths.contains("subdir/NESTED.TXT"))
        XCTAssertTrue(paths.contains("link-to-readme"))
    }

    /// On a disc that carries both, the tree with more in it wins — and it says so in the report.
    func test_hybrid_prefersTheFullerTree() throws {
        let image = try image("hybrid.iso")
        XCTAssertEqual(image.volume.naming, .udf)
        XCTAssertTrue(image.volume.report.contains("Names read as"))
        XCTAssertTrue(image.volume.report.contains("UDF"))
    }

    // MARK: - Cross-check against a reader that is not ours

    /// Every name bsdtar finds, this reader finds too.
    ///
    /// One direction only, deliberately: this reader also lists things bsdtar does not (the disc
    /// report, and boot images), so equality would fail for the right reasons. What must not
    /// happen is a file bsdtar can see and we cannot.
    func test_listingCoversEverythingBsdtarSees() throws {
        for name in ["iso9660.iso", "joliet.iso"] {
            let path = try fixture(name)
            guard let listing = Self.bsdtarNames(path) else { throw XCTSkip("bsdtar unavailable") }
            XCTAssertFalse(listing.isEmpty, "bsdtar listed nothing in \(name)")
            let ours = realPaths(try DiscImage(path: path))
            let missing = listing.subtracting(ours)
            XCTAssertTrue(missing.isEmpty, "\(name): bsdtar sees \(missing.sorted()) and we do not")
        }
    }

    /// The claim the plugin is built on, asserted rather than assumed.
    func test_bsdtarCannotOpenTheUDFOnlyImage() throws {
        let path = try fixture("udf.iso")
        guard let listing = Self.bsdtarNames(path) else { throw XCTSkip("bsdtar unavailable") }
        XCTAssertTrue(listing.isEmpty,
                      "bsdtar listed \(listing.sorted()) — if this ever passes, the plugin's "
                      + "advantage on UDF-only images has gone away and the README should say so")
        XCTAssertFalse(realPaths(try DiscImage(path: path)).isEmpty,
                       "…and we must still read it")
    }

    // MARK: - Contents

    func test_readsFileContents() throws {
        for name in ["iso9660.iso", "udf.iso", "hybrid.iso"] {
            let image = try DiscImage(path: try fixture(name))
            let readme = image.entries.first { $0.path.hasSuffix("README.TXT") && !$0.isSymlink }
            let path = try XCTUnwrap(readme?.path, "\(name) has no README.TXT")
            let data = try XCTUnwrap(image.read(path: path, offset: 0, length: 1 << 20))
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "Hello from a disc image.\n",
                           "in \(name)")
        }
    }

    /// A file spanning many sectors comes back byte-identical, and identically from both readers.
    func test_aLargeFileIsTheSameThroughEitherTree() throws {
        let viaISO = try XCTUnwrap(image("iso9660.iso").read(path: "BIG.BIN", offset: 0, length: 1 << 22))
        let viaUDF = try XCTUnwrap(image("udf.iso").read(path: "BIG.BIN", offset: 0, length: 1 << 22))
        XCTAssertEqual(viaISO.count, 300_000)
        XCTAssertEqual(viaISO, viaUDF,
                       "the same file read through the ISO 9660 and UDF trees must be the same bytes")
    }

    /// The three answers a random-access read has to get right.
    func test_randomAccessSliceShortReadAndPastTheEnd() throws {
        let image = try image("iso9660.iso")
        let whole = try XCTUnwrap(image.read(path: "BIG.BIN", offset: 0, length: 300_000))

        let middle = try XCTUnwrap(image.read(path: "BIG.BIN", offset: 100_000, length: 4_096))
        XCTAssertEqual(middle.count, 4_096)
        XCTAssertEqual(Array(middle), Array(whole[100_000..<104_096]))

        // Asking for more than is left yields what is left, not an error and not padding.
        let tail = try XCTUnwrap(image.read(path: "BIG.BIN", offset: 299_000, length: 8_192))
        XCTAssertEqual(tail.count, 1_000)
        XCTAssertEqual(Array(tail), Array(whole[299_000...]))

        // At or past the end: empty. This is what tells a streaming reader to stop.
        XCTAssertEqual(image.read(path: "BIG.BIN", offset: 300_000, length: 4_096)?.count, 0)
        XCTAssertEqual(image.read(path: "BIG.BIN", offset: 999_999, length: 4_096)?.count, 0)

        // An entry that is not there is nil, which is a different answer from "no bytes left".
        XCTAssertNil(image.read(path: "NOT-THERE.BIN", offset: 0, length: 16))
    }

    /// The padding trap: an extent is rounded up to a sector, the file is not.
    func test_aFileIsNotPaddedOutToItsSector() throws {
        let image = try image("iso9660.iso")
        let data = try XCTUnwrap(image.read(path: "README.TXT", offset: 0, length: 1 << 16))
        XCTAssertEqual(data.count, 25, "the extent is 2048 bytes; the file is 25")
    }

    // MARK: - Symlinks

    /// A symlink reports its target as its contents, and its size matches.
    ///
    /// The failure this guards is quiet: the directory record's data length is not the target's
    /// length, so reporting one and serving the other produces an empty file when the link is
    /// copied out — with no error anywhere.
    func test_symlinkTargetIsItsContents() throws {
        for (name, entryPath) in [("iso9660.iso", "LINK-TO-README"), ("udf.iso", "link-to-readme")] {
            let image = try DiscImage(path: try fixture(name))
            let entry = try XCTUnwrap(image.entries.first { $0.path == entryPath }, name)
            XCTAssertTrue(entry.isSymlink, "\(name): \(entryPath) should be a symlink")
            let data = try XCTUnwrap(image.read(path: entryPath, offset: 0, length: 4_096))
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "README.TXT", "in \(name)")
            XCTAssertEqual(entry.size, Int64(data.count),
                           "\(name): the reported size and the served bytes must agree")
        }
    }

    // MARK: - Metadata

    func test_timestampsAreReal() throws {
        // The bsdtar-backed path in the host gives every member the *archive file's* mtime, because
        // ShellArchiveSource reports `modified: nil` and ArchiveFS falls back to the container's
        // date. So the difference is not "a date versus none" — it is each file's own date versus
        // one date for all of them, which is the more misleading of the two failures and the reason
        // this is asserted rather than assumed.
        let image = try image("iso9660.iso")
        let entry = try XCTUnwrap(image.entries.first { $0.path == "README.TXT" })
        let year = Calendar(identifier: .gregorian).component(.year, from: entry.modified)
        XCTAssertGreaterThan(year, 2000, "got \(entry.modified)")
        XCTAssertLessThan(year, 2100, "got \(entry.modified)")
    }

    func test_theDiscDescribesItself() throws {
        let image = try image("iso9660.iso")
        let info = try XCTUnwrap(image.entries.first { $0.path == DiscImage.infoFileName })
        let data = try XCTUnwrap(image.read(path: info.path, offset: 0, length: 1 << 16))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("Volume"), text)
        XCTAssertTrue(text.contains("Names read as"), text)
        XCTAssertEqual(info.size, Int64(data.count))
    }

    // MARK: - Refusal

    /// Not every file is a disc image, and the ones that are not must be handed back cleanly —
    /// this is what lets the host fall through to its own readers.
    func test_refusesWhatIsNotADiscImage() throws {
        let junk = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-an-image-\(UUID().uuidString).iso")
        try Data(repeating: 0x41, count: 200_000).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }

        XCTAssertFalse(DiscImage.canRead(path: junk.path))
        XCTAssertThrowsError(try DiscImage(path: junk.path)) { error in
            XCTAssertEqual(error as? ImageError, .notThisFormat,
                           "the host reads this exact case as “not mine” and tries its own readers")
        }
        // A file that does not exist is a different failure from one that is not an image.
        XCTAssertFalse(DiscImage.canRead(path: "/nonexistent/\(UUID().uuidString).iso"))
    }

    func test_recognisesImagesByContentRatherThanName() throws {
        // The case an extension list can never cover: a disc image called something else.
        let source = try fixture("udf.iso")
        let renamed = FileManager.default.temporaryDirectory
            .appendingPathComponent("dump-\(UUID().uuidString).bin")
        try FileManager.default.copyItem(atPath: source, toPath: renamed.path)
        defer { try? FileManager.default.removeItem(at: renamed) }
        XCTAssertTrue(DiscImage.canRead(path: renamed.path))
    }

    // MARK: - Cache

    func test_theTreeIsParsedOnce() throws {
        TreeCache.shared.removeAll()
        let path = try fixture("hybrid.iso")
        let first = try TreeCache.shared.image(for: path)
        let second = try TreeCache.shared.image(for: path)
        XCTAssertTrue(first === second,
                      "the host opens an archive to list it and again to read from it; parsing "
                      + "twice is the cost this cache exists to remove")
    }

    // MARK: - Helpers

    /// The names bsdtar reports, normalised the way this reader spells them. Nil when bsdtar is
    /// absent; empty when it opened the file and found nothing.
    private static func bsdtarNames(_ path: String) -> Set<String>? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/bsdtar") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-tf", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var names = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            var name = String(line)
            if name.hasPrefix("./") { name.removeFirst(2) }
            while name.hasSuffix("/") { name.removeLast() }
            if name.isEmpty || name == "." { continue }
            names.insert(name)
        }
        return names
    }
}
