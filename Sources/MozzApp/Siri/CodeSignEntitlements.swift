#if os(iOS)
import Foundation
import MachO

/// Reads this app's own code-signing entitlements.
///
/// Needed because parts of SiriKit — `INVocabulary`, `INPreferences` — raise an
/// Objective-C exception rather than returning an error when the app lacks the
/// Siri entitlement, and a raised `NSException` cannot be caught from Swift. The
/// app simply dies. So the question has to be answered *before* touching any of
/// those classes, and it can't be answered by asking them.
///
/// Two tempting shortcuts don't work. The embedded provisioning profile lists the
/// capabilities the profile *permits*, which still says Siri even when the signed
/// entitlements omit it — that's exactly the case here, since per-branch builds
/// are signed with a team wildcard profile and have their entitlements stripped.
/// And `SecTaskCopyValueForEntitlement`, which would answer this directly, is
/// macOS-only.
///
/// What's left is the truth on disk: the entitlements plist that `codesign`
/// embedded in the executable. Any parsing failure reports "not entitled", which
/// costs a feature and never costs a launch.
enum CodeSignEntitlements {
    static func hasEntitlement(_ key: String) -> Bool {
        (entitlements?[key] as? Bool) ?? false
    }

    /// Parsed once — the binary can't change under a running process.
    private static let entitlements: [String: Any]? = {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let range = entitlementsRange(in: data)
        else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: data.subdata(in: range), format: nil) as? [String: Any]
    }()

    /// Locate the entitlements plist inside the Mach-O's code-signature blob.
    private static func entitlementsRange(in data: Data) -> Range<Int>? {
        data.withUnsafeBytes { raw -> Range<Int>? in
            guard let base = raw.baseAddress, raw.count > MemoryLayout<mach_header_64>.size
            else { return nil }

            func value<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T? {
                guard offset >= 0, offset + MemoryLayout<T>.size <= raw.count else { return nil }
                // Unaligned: neither the mapped file's base address nor the
                // offsets inside a Mach-O are guaranteed to be word-aligned, and
                // an aligned load on ARM traps.
                return base.loadUnaligned(fromByteOffset: offset, as: T.self)
            }

            guard let magic = value(UInt32.self, at: 0),
                  magic == MH_MAGIC_64 || magic == MH_CIGAM_64 else { return nil }
            guard let commandCount = value(UInt32.self, at: 16) else { return nil }

            // Walk the load commands for the code-signature pointer.
            var cursor = MemoryLayout<mach_header_64>.size
            var signatureOffset: Int?
            for _ in 0..<commandCount {
                guard let command = value(UInt32.self, at: cursor),
                      let size = value(UInt32.self, at: cursor + 4), size > 0 else { return nil }
                if command == LC_CODE_SIGNATURE, let offset = value(UInt32.self, at: cursor + 8) {
                    signatureOffset = Int(offset)
                    break
                }
                cursor += Int(size)
            }
            guard let superBlob = signatureOffset else { return nil }

            // The signature is a SuperBlob of (type, offset) indices, all
            // big-endian regardless of the architecture's own byte order.
            guard let count = value(UInt32.self, at: superBlob + 8)?.bigEndian else { return nil }
            let csSlotEntitlements: UInt32 = 5
            let csMagicEntitlement: UInt32 = 0xfade_7171
            for index in 0..<Int(count) {
                let entry = superBlob + 12 + index * 8
                guard let slot = value(UInt32.self, at: entry)?.bigEndian,
                      let offset = value(UInt32.self, at: entry + 4)?.bigEndian,
                      slot == csSlotEntitlements else { continue }
                let blob = superBlob + Int(offset)
                guard let blobMagic = value(UInt32.self, at: blob)?.bigEndian,
                      blobMagic == csMagicEntitlement,
                      let length = value(UInt32.self, at: blob + 4)?.bigEndian,
                      length > 8
                else { return nil }
                // The plist follows the 8-byte blob header.
                let start = blob + 8
                let end = blob + Int(length)
                guard end <= raw.count else { return nil }
                return start..<end
            }
            return nil
        }
    }
}
#endif
