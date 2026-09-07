// SPDX-License-Identifier: Apache-2.0
// PluginABITests.swift - The plugin as the host meets it: a bundle, dlopen'd, driven over the C ABI.
//
// The tests beside this one call the reader directly, which is the right way to test a parser and
// the wrong way to test a plugin: everything that goes wrong at the boundary — a name that does not
// fit the fixed 1024-byte field, a handle released twice, an export the build script forgot to
// keep — goes wrong only here.
//
// So this file builds the bundle exactly as `./build.sh` does, opens it with dlopen, resolves the
// symbols by the same names the host resolves, and calls them in the same order:
// OpenArchive → (ReadHeaderEx → ProcessFile)* → CloseArchive. No part of the plugin is imported.

import XCTest
import CPeachCommanderPlugin

final class PluginABITests: XCTestCase {
    /// Built once per test run. Building it per test cost about a second each, for an artefact
    /// that cannot differ between them.
    private static let bundle: Result<URL, Error> = {
        Result { try buildBundle() }
    }()

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)          // Tests/ISOPluginTests/PluginABITests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private struct BuildFailure: Error, CustomStringConvertible { var description: String }

    private static func buildBundle() throws -> URL {
        let root = repositoryRoot()
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("iso-plugin-abi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = root.appendingPathComponent("build.sh")
        process.arguments = [out.path]
        process.currentDirectoryURL = root
        // One slice is enough here and much faster; `pcplug-validate` is what checks that a
        // release carries both.
        var environment = ProcessInfo.processInfo.environment
        environment["PC_PLUGIN_ARCHS"] = currentArchitecture
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let log = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BuildFailure(description: "build.sh failed:\n" + String(decoding: log, as: UTF8.self))
        }
        return out.appendingPathComponent("ISO9660.pcxplugin")
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private func openLibrary() throws -> UnsafeMutableRawPointer {
        let bundle: URL
        do {
            bundle = try Self.bundle.get()
        } catch {
            throw XCTSkip("could not build the plugin: \(error)")
        }
        let binary = bundle.appendingPathComponent("Contents/MacOS/ISO9660")
        guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown"
            throw BuildFailure(description: "dlopen failed: \(message)")
        }
        return handle
    }

    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) else {
            throw XCTSkip("fixture \(name) is missing — run Tools/make-fixtures.sh")
        }
        return url.path
    }

    // The ABI, declared here rather than imported: this file must not share a definition with the
    // plugin, or a mistake in the plugin's own header use would cancel itself out.
    private struct OpenArchiveData {
        var arcName: UnsafeMutablePointer<CChar>?
        var openMode: Int32 = 1
        var openResult: Int32 = 0
        var comment: UnsafeMutablePointer<CChar>? = nil
        var commentLen: Int32 = 0
    }
    private typealias OpenFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias ReadFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer) -> Int32
    private typealias ProcFn = @convention(c) (UnsafeMutableRawPointer?, Int32,
                                               UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CChar>?) -> Int32
    private typealias CloseFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias CapsFn = @convention(c) () -> Int32
    private typealias CanHandleFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Int32
    private typealias ReadEntryFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int64, Int64,
                                                    UnsafeMutableRawPointer?, UnsafeMutablePointer<Int64>?) -> Int32

    // The two fields this test reads out of PcHeaderDataEx by hand, and the buffer it reads them
    // into. Hand-computed on purpose — the point is to poke at the raw bytes the way the host does,
    // not to let Swift's importer do the arithmetic — but checked against the real layout in
    // `test_theHeaderOffsetsThisFileAssumesAreStillTrue`, because a struct that gained a field
    // would otherwise leave every assertion here reading a neighbouring one and passing anyway.
    private static let unpSizeOffset = 1024 + 8
    private static let fileAttrOffset = 1024 + 24
    private static let headerSize = 1024 + 8 * 3 + 4 * 2 + 4 + 64 + 8    // + padding headroom

    func test_theHeaderOffsetsThisFileAssumesAreStillTrue() {
        XCTAssertEqual(MemoryLayout<PcHeaderDataEx>.offset(of: \.unpSize), Self.unpSizeOffset)
        XCTAssertEqual(MemoryLayout<PcHeaderDataEx>.offset(of: \.fileAttr), Self.fileAttrOffset)
        XCTAssertLessThanOrEqual(MemoryLayout<PcHeaderDataEx>.size, Self.headerSize)
    }

    private func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            throw BuildFailure(description: "the plugin does not export \(name)")
        }
        return unsafeBitCast(pointer, to: type)
    }

    /// Walk an image the way the host does, returning (name, size, isDirectory) per entry.
    private func list(_ handle: UnsafeMutableRawPointer, _ path: String) throws
        -> (archive: UnsafeMutableRawPointer, entries: [(name: String, size: Int64, isDirectory: Bool)]) {
        let open = try symbol(handle, "OpenArchive", as: OpenFn.self)
        let readHeader = try symbol(handle, "ReadHeaderEx", as: ReadFn.self)
        let process = try symbol(handle, "ProcessFile", as: ProcFn.self)

        var data = OpenArchiveData()
        let archive: UnsafeMutableRawPointer? = path.withCString { name in
            data.arcName = UnsafeMutablePointer(mutating: name)
            return withUnsafeMutableBytes(of: &data) { raw in open(raw.baseAddress!) }
        }
        guard let archive else {
            throw BuildFailure(description: "OpenArchive refused \(path) with \(data.openResult)")
        }

        var entries: [(String, Int64, Bool)] = []
        let header = UnsafeMutableRawPointer.allocate(byteCount: Self.headerSize, alignment: 8)
        defer { header.deallocate() }
        while true {
            header.initializeMemory(as: UInt8.self, repeating: 0, count: Self.headerSize)
            let rc = readHeader(archive, header)
            if rc == 10 { break }                                   // PC_E_END_ARCHIVE
            guard rc == 0 else { throw BuildFailure(description: "ReadHeaderEx returned \(rc)") }
            let name = String(cString: header.assumingMemoryBound(to: CChar.self))
            let size = header.advanced(by: Self.unpSizeOffset).assumingMemoryBound(to: Int64.self).pointee  // unpSize
            let attributes = header.advanced(by: Self.fileAttrOffset).assumingMemoryBound(to: UInt32.self).pointee
            entries.append((name, size, attributes & 0x10 != 0))     // PC_ATTR_DIR
            XCTAssertEqual(process(archive, 0, nil, nil), 0, "ProcessFile(PC_SKIP) on \(name)")
        }
        return (archive, entries)
    }

    // MARK: - Tests

    func test_theBundleLoadsAndExportsWhatTheHostRequires() throws {
        let handle = try openLibrary()
        defer { dlclose(handle) }
        for name in ["OpenArchive", "ReadHeaderEx", "ProcessFile", "CloseArchive",
                     "SetChangeVolProc", "SetProcessDataProc"] {
            XCTAssertNotNil(dlsym(handle, name), "required export \(name) is missing")
        }
        for name in ["GetPackerCaps", "CanYouHandleThisFile", "ReadEntryData", "PcGetApiVersion"] {
            XCTAssertNotNil(dlsym(handle, name), "optional export \(name) was meant to be there")
        }
        let version = try symbol(handle, "PcGetApiVersion", as: (@convention(c) () -> Int32).self)
        XCTAssertEqual(version(), 1)
    }

    func test_capabilitiesMatchWhatIsActuallyImplemented() throws {
        let handle = try openLibrary()
        defer { dlclose(handle) }
        let caps = try symbol(handle, "GetPackerCaps", as: CapsFn.self)()
        XCTAssertNotEqual(caps & 0x0004, 0, "PC_CAP_MULTIPLE")
        XCTAssertNotEqual(caps & 0x0040, 0, "PC_CAP_BY_CONTENT")
        XCTAssertNotEqual(caps & 0x0800, 0, "PC_CAP_RANDOM_ACCESS")
        // The host refuses to believe either claim without the export behind it, and so should we.
        XCTAssertNotNil(dlsym(handle, "CanYouHandleThisFile"))
        XCTAssertNotNil(dlsym(handle, "ReadEntryData"))
        // Read-only: claiming otherwise would put a writable archive in front of the user.
        XCTAssertEqual(caps & 0x0003, 0, "PC_CAP_NEW / PC_CAP_MODIFY must not be claimed")
        XCTAssertNil(dlsym(handle, "PackFiles"))
    }

    func test_listsAUDFImageThroughTheABI() throws {
        let handle = try openLibrary()
        defer { dlclose(handle) }
        let (archive, entries) = try list(handle, try fixture("udf.iso"))
        defer { _ = try? symbol(handle, "CloseArchive", as: CloseFn.self)(archive) }

        let names = Set(entries.map(\.name))
        XCTAssertTrue(names.contains("README.TXT"), "got \(names.sorted())")
        XCTAssertTrue(names.contains("subdir/NESTED.TXT"))
        XCTAssertTrue(names.contains("a-directory-with-a-long-name/long name with spaces.txt"))
        XCTAssertTrue(entries.contains { $0.name == "subdir" && $0.isDirectory })
        XCTAssertEqual(entries.first { $0.name == "BIG.BIN" }?.size, 300_000)
    }

    func test_extractsAFileThroughTheABI() throws {
        let handle = try openLibrary()
        defer { dlclose(handle) }
        let open = try symbol(handle, "OpenArchive", as: OpenFn.self)
        let readHeader = try symbol(handle, "ReadHeaderEx", as: ReadFn.self)
        let process = try symbol(handle, "ProcessFile", as: ProcFn.self)
        let close = try symbol(handle, "CloseArchive", as: CloseFn.self)

        var data = OpenArchiveData()
        let path = try fixture("iso9660.iso")
        let archive: UnsafeMutableRawPointer? = path.withCString { name in
            data.arcName = UnsafeMutablePointer(mutating: name)
            return withUnsafeMutableBytes(of: &data) { raw in open(raw.baseAddress!) }
        }
        let handleOK = try XCTUnwrap(archive)
        defer { _ = close(handleOK) }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("extracted-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        let header = UnsafeMutableRawPointer.allocate(byteCount: Self.headerSize, alignment: 8)
        defer { header.deallocate() }
        var extracted = false
        while true {
            header.initializeMemory(as: UInt8.self, repeating: 0, count: Self.headerSize)
            let rc = readHeader(handleOK, header)
            if rc == 10 { break }
            XCTAssertEqual(rc, 0)
            let name = String(cString: header.assumingMemoryBound(to: CChar.self))
            if name == "BIG.BIN" {
                let status = destination.path.withCString { dest in
                    process(handleOK, 2, nil, UnsafeMutablePointer(mutating: dest))   // PC_EXTRACT
                }
                XCTAssertEqual(status, 0, "ProcessFile(PC_EXTRACT)")
                extracted = true
                break
            }
            XCTAssertEqual(process(handleOK, 0, nil, nil), 0)
        }
        XCTAssertTrue(extracted, "BIG.BIN was not reached")

        let written = try Data(contentsOf: destination)
        XCTAssertEqual(written.count, 300_000, "the extracted file must be exactly its declared size")
    }

    /// The export the host needs before it will treat members as cheap to reach.
    func test_readEntryDataServesASliceWithoutWalkingTheArchive() throws {
        let handle = try openLibrary()
        defer { dlclose(handle) }
        let (archive, _) = try list(handle, try fixture("hybrid.iso"))
        defer { _ = try? symbol(handle, "CloseArchive", as: CloseFn.self)(archive) }
        let readEntry = try symbol(handle, "ReadEntryData", as: ReadEntryFn.self)

        var buffer = [UInt8](repeating: 0, count: 4096)
        var produced: Int64 = 0
        let rc = "README.TXT".withCString { name in
            buffer.withUnsafeMutableBytes { raw in
                readEntry(archive, name, 0, 4096, raw.baseAddress, &produced)
            }
        }
        XCTAssertEqual(rc, 0)
        XCTAssertEqual(produced, 25)
        XCTAssertEqual(String(decoding: buffer.prefix(Int(produced)), as: UTF8.self),
                       "Hello from a disc image.\n")

        // Past the end: zero bytes and PC_OK, which is how a streaming reader learns to stop.
        produced = -1
        let atEnd = "README.TXT".withCString { name in
            buffer.withUnsafeMutableBytes { raw in
                readEntry(archive, name, 9_999, 4096, raw.baseAddress, &produced)
            }
        }
        XCTAssertEqual(atEnd, 0)
        XCTAssertEqual(produced, 0)

        // An entry that is not there: PC_E_END_ARCHIVE, which is a different answer.
        let missing = "nope".withCString { name in
            buffer.withUnsafeMutableBytes { raw in
                readEntry(archive, name, 0, 16, raw.baseAddress, &produced)
            }
        }
        XCTAssertEqual(missing, 10)
    }

    /// The refusal that lets the host fall through to its own readers.
    func test_refusesAFileThatIsNotADiscImage() throws {
        let handle = try openLibrary()
        defer { dlclose(handle) }
        let open = try symbol(handle, "OpenArchive", as: OpenFn.self)
        let canHandle = try symbol(handle, "CanYouHandleThisFile", as: CanHandleFn.self)

        let junk = FileManager.default.temporaryDirectory
            .appendingPathComponent("junk-\(UUID().uuidString).iso")
        try Data(repeating: 0x5A, count: 100_000).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }

        XCTAssertEqual(junk.path.withCString { canHandle(UnsafeMutablePointer(mutating: $0)) }, 0)

        var data = OpenArchiveData()
        let archive: UnsafeMutableRawPointer? = junk.path.withCString { name in
            data.arcName = UnsafeMutablePointer(mutating: name)
            return withUnsafeMutableBytes(of: &data) { raw in open(raw.baseAddress!) }
        }
        XCTAssertNil(archive)
        XCTAssertEqual(data.openResult, 14,
                       "PC_E_UNKNOWN_FMT is what the host reads as “not mine”; any other code "
                       + "stops the file here instead of letting the built-in readers try")
    }

    func test_recognisesAnImageByContentWhateverItIsCalled() throws {
        let handle = try openLibrary()
        defer { dlclose(handle) }
        let canHandle = try symbol(handle, "CanYouHandleThisFile", as: CanHandleFn.self)
        let renamed = FileManager.default.temporaryDirectory
            .appendingPathComponent("firmware-\(UUID().uuidString).bin")
        try FileManager.default.copyItem(atPath: try fixture("udf.iso"), toPath: renamed.path)
        defer { try? FileManager.default.removeItem(at: renamed) }
        XCTAssertEqual(renamed.path.withCString { canHandle(UnsafeMutablePointer(mutating: $0)) }, 1)
    }
}
