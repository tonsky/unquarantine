import Darwin
import Foundation

struct FileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
}

struct DownloadTarget: Equatable {
    let url: URL
    let isApp: Bool
    let identity: FileIdentity
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64
}

/// Resolves individual event paths. Never enumerates Downloads or app contents.
struct DownloadInspector {
    static let supportedExtensions: Set<String> = ["dmg", "zip", "app"]
    static let partialExtensions: Set<String> = [
        "crdownload", "download", "part", "partial", "tmp", "opdownload",
    ]
    let folder: URL
    private let rootAliases: [[String]]

    init(folder: URL) {
        let original = folder.standardized
        // Foundation canonicalizes /private/var differently for existing and
        // deleted files. Keep both spellings so removal events still match.
        if let path = realpath(original.path, nil) {
            self.folder = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            free(path)
        } else {
            self.folder = original
        }
        rootAliases = [self.folder.pathComponents, original.pathComponents]
    }

    func checkFolderAccess() throws {
        guard let directory = opendir(folder.path) else { throw posixError(folder) }
        closedir(directory)
    }

    /// A removed/renamed partial sibling may be the only completion event.
    /// Events inside a bundle always refer to its outermost .app directory.
    func candidate(forEventAt url: URL, partialRemoved: Bool = false) -> URL? {
        guard let parts = relativeComponents(url), !parts.isEmpty else { return nil }
        var candidate = folder
        for (index, part) in parts.enumerated() {
            guard !part.hasPrefix(".") else { return nil }
            candidate.appendPathComponent(part)
            let ext = candidate.pathExtension.lowercased()
            if ext == "app" { return candidate }
            if Self.partialExtensions.contains(ext) {
                guard partialRemoved else { return nil }
                let final = candidate.deletingPathExtension()
                return Self.supportedExtensions.contains(final.pathExtension.lowercased())
                    ? self.candidate(forEventAt: final) : nil
            }
            if index == parts.count - 1, Self.supportedExtensions.contains(ext) {
                return candidate
            }
        }
        return nil
    }

    /// FSEvents may deliver already-buffered events after a stream starts. Check
    /// the event item's metadata, not the whole tree, to leave old files alone.
    func changed(_ url: URL, since start: TimeInterval) throws -> Bool {
        guard let info = try fileInfo(url) else { return true } // Removed/renamed path.
        let changed = Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return max(changed, modified) >= start
    }

    /// Returns only eligible, quarantined targets; missing or unfinished files
    /// wait for another event. lstat on each ancestor prevents following symlinks.
    func inspect(_ url: URL) throws -> DownloadTarget? {
        guard candidate(forEventAt: url)?.standardized.path == url.standardized.path,
              let parts = relativeComponents(url), !parts.isEmpty else { return nil }
        guard let rootInfo = try fileInfo(folder), rootInfo.st_mode & S_IFMT == S_IFDIR else { return nil }
        var current = folder
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(part)
            guard let info = try fileInfo(current) else { return nil }
            if info.st_mode & S_IFMT == S_IFLNK { return nil }
            if index < parts.count - 1, info.st_mode & S_IFMT != S_IFDIR { return nil }
        }
        guard let info = try fileInfo(url) else { return nil }
        let isApp = url.pathExtension.lowercased() == "app" && info.st_mode & S_IFMT == S_IFDIR
        guard isApp || (url.pathExtension.lowercased() != "app" && info.st_mode & S_IFMT == S_IFREG),
              try hasQuarantine(url) else { return nil }
        if !isApp {
            guard info.st_size > 0 else { return nil }
            for ext in Self.partialExtensions {
                if try fileInfo(URL(fileURLWithPath: url.path + "." + ext)) != nil { return nil }
            }
        }
        return DownloadTarget(
            url: url, isApp: isApp,
            identity: FileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino)),
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private func relativeComponents(_ url: URL) -> [String]? {
        let path = url.standardized.pathComponents
        for root in rootAliases where path.starts(with: root) {
            return Array(path.dropFirst(root.count))
        }
        return nil
    }
}

func hasQuarantine(_ url: URL) throws -> Bool {
    if getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 { return true }
    if errno == ENOATTR || errno == ENOTSUP || errno == ENOENT || errno == ENOTDIR { return false }
    throw posixError(url)
}

private func fileInfo(_ url: URL) throws -> stat? {
    var info = stat()
    if lstat(url.path, &info) == 0 { return info }
    if errno == ENOENT || errno == ENOTDIR { return nil }
    throw posixError(url)
}

private func posixError(_ url: URL) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
}
