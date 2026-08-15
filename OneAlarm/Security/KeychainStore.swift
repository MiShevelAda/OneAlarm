import Foundation
import Security

enum KeychainError: Error, CustomStringConvertible, Equatable {
    case notFound
    /// The device is locked and the item's data is unavailable. **Not** the same as missing, and
    /// the difference matters: see the delete warning on `delete(_:)`.
    case interactionNotAllowed
    case dataCorrupted
    case unhandled(OSStatus)

    var description: String {
        switch self {
        case .notFound: return "keychain: item not found"
        case .interactionNotAllowed: return "keychain: data unavailable, device locked"
        case .dataCorrupted: return "keychain: stored value was not valid UTF-8"
        case .unhandled(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "keychain: OSStatus \(status) (\(message))"
        }
    }
}

/// The only place a credential is stored. No `UserDefaults`, no file, no log.
///
/// Deliberately hand rolled rather than taking a dependency. Apple's own guidance is to write a
/// small project specific wrapper that surfaces the real `OSStatus`, because a general purpose
/// wrapper hides the status codes and tends to model the keychain differently from how it behaves.
///
/// Two decisions worth not undoing:
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is set on add. The default when the attribute
/// is omitted is `WhenUnlocked`, which fails every read on a locked device, and a token refresh runs
/// on a locked device routinely. `ThisDeviceOnly` keeps the item out of backups and off any restored
/// phone.
///
/// There is no `SecAccessControl` on these items on purpose. A biometry gated item cannot be read
/// from a background task at all, because there is no UI to present the prompt from. Biometrics
/// belong on the screen that reveals a credential, not on the item, and that is where they are.
struct KeychainStore: Sendable {

    let service: String

    init(service: String = "de.trucora.OneAlarm.credentials") {
        self.service = service
    }

    enum Account: String, CaseIterable, Sendable {
        /// Eight Sleep issues no refresh token, so re-auth is a full password POST and the password
        /// has to be retained for the life of the app. Forced by their API, not a choice.
        case eightSleepEmail = "eightsleep.email"
        case eightSleepPassword = "eightsleep.password"
        case whoopEmail = "whoop.email"
        case whoopPassword = "whoop.password"
        case whoopRefreshToken = "whoop.refresh"
    }

    // A fresh dictionary per call. Reusing or mutating one across SecItem calls is a documented
    // way to get surprising results.
    private func baseQuery(_ account: Account) -> NSMutableDictionary {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.rawValue,
            // Stated on every query as well as every add, so a future accidental
            // `kSecAttrSynchronizableAny` cannot silently widen the match to iCloud items.
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    // MARK: Save

    func save(_ value: String, for account: Account) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.dataCorrupted }
        try save(data, for: account)
    }

    /// Shared so both update paths map `errSecInteractionNotAllowed` the same way. Mapping it in
    /// one place and forgetting it in the other is how a caller's `catch` starts behaving
    /// differently depending on which branch it arrived through.
    private func mapUpdate(_ status: OSStatus) throws -> Bool {
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        case errSecInteractionNotAllowed: throw KeychainError.interactionNotAllowed
        default: throw KeychainError.unhandled(status)
        }
    }

    func save(_ data: Data, for account: Account) throws {
        // Update first, then add. Delete then add would drop any persistent reference and, worse,
        // a delete on a locked device succeeds while returning nothing useful.
        if try mapUpdate(SecItemUpdate(baseQuery(account), [kSecValueData: data] as NSDictionary)) {
            return
        }

        let addQuery = baseQuery(account)
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Only service plus account form the uniqueness constraint for a generic password, so
            // a lookup can miss and the very next add can still collide. Update is valid now.
            let retry = SecItemUpdate(baseQuery(account), [kSecValueData: data] as NSDictionary)
            guard try mapUpdate(retry) else {
                throw KeychainError.unhandled(retry)
            }
        default:
            throw KeychainError.unhandled(addStatus)
        }
    }

    // MARK: Read

    func readData(_ account: Account) throws -> Data {
        let query = baseQuery(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        // Skip anything that would need to prompt, rather than failing noisily, so this is safe to
        // call from a background refresh.
        query[kSecUseAuthenticationUI] = kSecUseAuthenticationUISkip

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.dataCorrupted }
            return data
        case errSecItemNotFound:
            throw KeychainError.notFound
        case errSecInteractionNotAllowed:
            throw KeychainError.interactionNotAllowed
        default:
            throw KeychainError.unhandled(status)
        }
    }

    func readString(_ account: Account) throws -> String {
        guard let string = String(data: try readData(account), encoding: .utf8) else {
            throw KeychainError.dataCorrupted
        }
        return string
    }

    enum Presence: Equatable {
        case present
        case absent
        /// The item may or may not exist. The device is locked and its data is unreadable.
        case unknownDeviceLocked
    }

    /// Presence as a three way answer, not a `Bool`.
    ///
    /// A `Bool` here is the same mistake as conflating `errSecItemNotFound` with
    /// `errSecInteractionNotAllowed`, one layer up. Collapsing "locked" into "absent" makes the UI
    /// tell someone to re-enter a password they never lost, and invites any future cleanup code to
    /// delete a credential that is merely unreadable right now.
    func presence(_ account: Account) -> Presence {
        do {
            _ = try readData(account)
            return .present
        } catch KeychainError.notFound {
            return .absent
        } catch {
            return .unknownDeviceLocked
        }
    }

    // MARK: Delete

    /// Idempotent.
    ///
    /// Call this only from an explicit user disconnect, or after the server has confirmed the
    /// credential is invalid. **Never call it because a read failed.** `SecItemDelete` succeeds even
    /// when the item is merely inaccessible on a locked device, so `if read fails { delete }`
    /// quietly destroys a working credential during a background run. That is why
    /// `interactionNotAllowed` is a separate case from `notFound` throughout this file.
    func delete(_ account: Account) throws {
        let status = SecItemDelete(baseQuery(account))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    func deleteAll() {
        for account in Account.allCases {
            try? delete(account)
        }
    }
}
