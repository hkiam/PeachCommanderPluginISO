// SPDX-License-Identifier: Apache-2.0
// ABI.swift - The PCX packer entry points (pcx.h). This file is the whole contract with the host.
//
// Everything above this file is an ISO reader and knows nothing about Peach Commander. This is the
// hundred-odd lines that make it a plugin, and it is worth reading as the template it is meant to
// be: six required exports, four optional ones, no state that outlives an open handle except the
// parse cache.
//
// Points that cost other people time:
//
//   * `PcHeaderDataEx.fileName` is a fixed `char[1024]`. Swift imports that as a tuple of 1024
//     CChars, which cannot be assigned to; `withUnsafeMutableBytes` on the tuple is the way in.
//     A name that does not fit is skipped rather than truncated — a truncated path is a path to a
//     different file, and the host would then extract the wrong thing under the right name.
//
//   * The handle is an `Unmanaged` box, not a Swift object passed as a pointer. The host holds it
//     across calls, so ARC has to be told to keep it alive explicitly.
//
//   * `OpenArchive` returns `PC_E_UNKNOWN_FMT` for a file that is not a disc image, and that is
//     load-bearing: the host reads it as "not mine" and gives the built-in readers their turn. Any
//     other error means "mine, and broken", and the file stops there.

import Foundation
import CPeachCommanderPlugin

/// State for one open image. The host gets this back as an opaque `PC_HANDLE`.
private final class OpenImage {
    let image: DiscImage
    /// Where `ReadHeaderEx` has got to. The header/ProcessFile pair is a cursor, not random access.
    var cursor = 0
    /// The entry the last `ReadHeaderEx` returned, which is the one `ProcessFile` acts on.
    var current: DiscEntry?

    init(image: DiscImage) { self.image = image }
}

/// Copy a UTF-8 string into a fixed-size C char array, or report that it does not fit.
private func setFixedName(_ value: String, into pointer: UnsafeMutableRawPointer, capacity: Int) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count < capacity else { return false }
    let target = pointer.assumingMemoryBound(to: CChar.self)
    memset(target, 0, capacity)
    _ = bytes.withUnsafeBufferPointer { source in
        memcpy(target, source.baseAddress!, source.count)
    }
    return true
}

// MARK: - Required exports

@_cdecl("OpenArchive")
public func OpenArchive(_ data: UnsafeMutablePointer<PcOpenArchiveData>?) -> UnsafeMutableRawPointer? {
    guard let data, let namePtr = data.pointee.arcName else {
        data?.pointee.openResult = PC_E_EOPEN
        return nil
    }
    let path = String(cString: namePtr)
    do {
        let image = try TreeCache.shared.image(for: path)
        data.pointee.openResult = PC_OK
        return Unmanaged.passRetained(OpenImage(image: image)).toOpaque()
    } catch ImageError.notThisFormat {
        // "Not a disc image" — the host tries its other readers.
        data.pointee.openResult = PC_E_UNKNOWN_FMT
        return nil
    } catch ImageError.cannotOpen {
        data.pointee.openResult = PC_E_EOPEN
        return nil
    } catch {
        // A disc image that is ours and damaged. Distinct from the case above on purpose: the host
        // stops here and says so, rather than handing a corrupt image to a reader that will make
        // less sense of it.
        data.pointee.openResult = PC_E_BAD_ARCHIVE
        return nil
    }
}

@_cdecl("ReadHeaderEx")
public func ReadHeaderEx(_ handle: UnsafeMutableRawPointer?,
                         _ header: UnsafeMutablePointer<PcHeaderDataEx>?) -> Int32 {
    guard let handle, let header else { return PC_E_BAD_DATA }
    let state = Unmanaged<OpenImage>.fromOpaque(handle).takeUnretainedValue()

    while state.cursor < state.image.entries.count {
        let entry = state.image.entries[state.cursor]
        state.cursor += 1

        header.pointee = PcHeaderDataEx()
        let fits = withUnsafeMutableBytes(of: &header.pointee.fileName) { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return setFixedName(entry.path, into: base, capacity: raw.count)
        }
        // A path longer than the ABI's field is skipped, not truncated. ISO 9660 cannot produce
        // one; a deeply nested UDF tree can.
        guard fits else { continue }

        header.pointee.unpSize = entry.size
        header.pointee.packSize = entry.size          // nothing on a disc image is compressed
        header.pointee.fileTime = Int64(entry.modified.timeIntervalSince1970)
        var attributes: UInt32 = 0
        if entry.isDirectory { attributes |= UInt32(PC_ATTR_DIR) }
        if entry.isSymlink { attributes |= UInt32(PC_ATTR_SYMLINK) }
        attributes |= UInt32(PC_ATTR_READONLY)        // a disc image is read-only by nature
        header.pointee.fileAttr = attributes
        state.current = entry
        return PC_OK
    }

    state.current = nil
    return PC_E_END_ARCHIVE
}

@_cdecl("ProcessFile")
public func ProcessFile(_ handle: UnsafeMutableRawPointer?, _ operation: Int32,
                        _ destPath: UnsafeMutablePointer<CChar>?,
                        _ destName: UnsafeMutablePointer<CChar>?) -> Int32 {
    guard let handle else { return PC_E_BAD_DATA }
    let state = Unmanaged<OpenImage>.fromOpaque(handle).takeUnretainedValue()
    guard let entry = state.current else { return PC_OK }

    switch operation {
    case PC_SKIP:
        return PC_OK

    case PC_TEST:
        // "Can this be read at all": pull the bytes and throw them away, so a truncated image or a
        // bad extent is reported by Test Archive rather than at the moment someone copies a file.
        guard !entry.isDirectory else { return PC_OK }
        var remaining = entry.size
        var offset: Int64 = 0
        while remaining > 0 {
            let want = min(remaining, 1 << 20)
            guard let chunk = state.image.read(path: entry.path, offset: offset, length: want),
                  !chunk.isEmpty else {
                return PC_E_BAD_DATA
            }
            offset += Int64(chunk.count)
            remaining -= Int64(chunk.count)
        }
        return PC_OK

    case PC_EXTRACT:
        guard !entry.isDirectory else { return PC_OK }
        var target = ""
        if let destPath { target = String(cString: destPath) }
        if let destName {
            let name = String(cString: destName)
            target = target.isEmpty ? name : (target.hasSuffix("/") ? target + name : target + "/" + name)
        }
        guard !target.isEmpty else { return PC_E_ECREATE }
        return extract(entry, of: state, to: target)

    default:
        return PC_E_NOT_SUPPORTED
    }
}

/// Write one entry to `target`, a megabyte at a time.
///
/// Streamed rather than assembled in memory because a single file on a Blu-ray image can be tens
/// of gigabytes, and "extract this one file" must not need that much RAM to do it.
private func extract(_ entry: DiscEntry, of state: OpenImage, to target: String) -> Int32 {
    let url = URL(fileURLWithPath: target)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: target, contents: nil) else { return PC_E_ECREATE }
    guard let handle = try? FileHandle(forWritingTo: url) else { return PC_E_ECREATE }
    defer { try? handle.close() }

    var offset: Int64 = 0
    var remaining = entry.size
    while remaining > 0 {
        let want = min(remaining, 1 << 20)
        guard let chunk = state.image.read(path: entry.path, offset: offset, length: want),
              !chunk.isEmpty else {
            return PC_E_EREAD
        }
        do { try handle.write(contentsOf: chunk) } catch { return PC_E_EWRITE }
        offset += Int64(chunk.count)
        remaining -= Int64(chunk.count)

        // Tell the host how far along we are, and stop if it says to. `size` is negative here:
        // the ABI reads a value in -1000...0 as a permille of the whole operation, which is what a
        // single large file needs — a positive value would be added to a per-file counter the host
        // sets from the header, and this file is the whole job.
        if let progress = ProgressCallback.current {
            let permille = entry.size > 0 ? Int64(-1000 * Double(offset) / Double(entry.size)) : 0
            let keepGoing = entry.path.withCString { name in
                progress(UnsafeMutablePointer(mutating: name), permille)
            }
            if keepGoing == PC_ABORT { return PC_E_EABORTED }
        }
    }
    return PC_OK
}

@_cdecl("CloseArchive")
public func CloseArchive(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let handle else { return PC_E_BAD_DATA }
    Unmanaged<OpenImage>.fromOpaque(handle).release()
    return PC_OK
}

/// The progress callback the host hands us. Process-wide because the C prototype carries no
/// context pointer — the host serialises calls per open archive, which is what makes that safe.
enum ProgressCallback {
    nonisolated(unsafe) static var current: PcProcessDataProc?
}

@_cdecl("SetProcessDataProc")
public func SetProcessDataProc(_ handle: UnsafeMutableRawPointer?, _ proc: PcProcessDataProc?) {
    ProgressCallback.current = proc
}

@_cdecl("SetChangeVolProc")
public func SetChangeVolProc(_ handle: UnsafeMutableRawPointer?, _ proc: PcChangeVolProc?) {
    // A disc image is one file. There is no next volume to ask for.
}

// MARK: - Optional exports

@_cdecl("GetPackerCaps")
public func GetPackerCaps() -> Int32 {
    // MULTIPLE: an image holds many files.
    // BY_CONTENT: `.img`, `.udf` and extensionless dumps are exactly the files somebody installs a
    //   disc-image reader for, and no extension list can catch them.
    // RANDOM_ACCESS: honest only because ReadEntryData below exists — the host checks for both.
    PC_CAP_MULTIPLE | PC_CAP_BY_CONTENT | PC_CAP_RANDOM_ACCESS
}

@_cdecl("CanYouHandleThisFile")
public func CanYouHandleThisFile(_ fileName: UnsafeMutablePointer<CChar>?) -> Int32 {
    guard let fileName else { return 0 }
    return DiscImage.canRead(path: String(cString: fileName)) ? 1 : 0
}

@_cdecl("ReadEntryData")
public func ReadEntryData(_ handle: UnsafeMutableRawPointer?, _ entryPath: UnsafePointer<CChar>?,
                          _ offset: Int64, _ length: Int64,
                          _ buffer: UnsafeMutableRawPointer?,
                          _ outRead: UnsafeMutablePointer<Int64>?) -> Int32 {
    guard let handle, let entryPath, let buffer, let outRead else { return PC_E_BAD_DATA }
    outRead.pointee = 0
    guard offset >= 0, length > 0 else { return PC_E_BAD_DATA }

    let state = Unmanaged<OpenImage>.fromOpaque(handle).takeUnretainedValue()
    let path = String(cString: entryPath)
    guard let chunk = state.image.read(path: path, offset: offset, length: length) else {
        return PC_E_END_ARCHIVE          // no such entry
    }
    guard !chunk.isEmpty else { return PC_OK }   // at or past the end: zero bytes, not an error
    _ = chunk.withUnsafeBytes { raw in
        memcpy(buffer, raw.baseAddress!, raw.count)
    }
    outRead.pointee = Int64(chunk.count)
    return PC_OK
}

@_cdecl("PcGetApiVersion")
public func PcGetApiVersion() -> Int32 { PC_API_VERSION }
