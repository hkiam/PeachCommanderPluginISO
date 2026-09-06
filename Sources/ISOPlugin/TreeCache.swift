// SPDX-License-Identifier: Apache-2.0
// TreeCache.swift - Parse a disc once, not once per question.
//
// The host opens an archive to list it, and opens it again to read from it. Without a cache that
// is two full walks of the directory tree, and on a dual-layer DVD with tens of thousands of
// entries the second one is pure waste — the answer cannot have changed, because the file has not.
//
// Keyed on the path *and* the file's identity, not the path alone: a `.iso` that is rebuilt in
// place keeps its name, and a cache that only looked at names would go on serving the old tree
// until the app was restarted. Size and modification time are what change when the file does.

import Foundation

public final class TreeCache {
    public static let shared = TreeCache()

    private struct Key: Hashable {
        let path: String
        let size: Int64
        let modified: Int64
    }

    private let lock = NSLock()
    private var cache: [Key: DiscImage] = [:]
    private var order: [Key] = []
    /// Small on purpose: each entry holds an open file descriptor and the whole entry list, and
    /// nobody has more than a couple of images open at a time.
    private let limit = 4

    private func key(for path: String) -> Key? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Key(path: path, size: Int64(st.st_size), modified: Int64(st.st_mtimespec.tv_sec))
    }

    /// The parsed image for `path`, parsing it if this is the first ask.
    public func image(for path: String) throws -> DiscImage {
        guard let key = key(for: path) else { throw ImageError.cannotOpen(path) }
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        // Parsed outside the lock: a large image takes a while and holding the lock would make a
        // second, unrelated image wait for it.
        let image = try DiscImage(path: path)

        lock.lock()
        defer { lock.unlock() }
        if let raced = cache[key] { return raced }
        cache[key] = image
        order.append(key)
        while order.count > limit {
            let oldest = order.removeFirst()
            cache[oldest] = nil
        }
        return image
    }

    /// Drop everything. Used by the tests, and by nothing else.
    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
        order.removeAll()
    }
}
