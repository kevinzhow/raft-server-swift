import Crypto
import Foundation

/// Contains no key material or provider input in its associated values or description.
public enum ProviderCredentialError: Error, Sendable {
    case encryptionKeyUnavailable
    case credentialUnavailable
    case invalidPersistedCredentials
    case legacyCredentialsRequireReplacement
}

/// Only encrypted business data belongs to the Cards owner and its snapshot.
/// AES-GCM's combined representation includes the random nonce and authentication tag.
struct ProviderCredentialEnvelope: Codable, Sendable, Equatable {
    let version: Data
    let keyID: Data
    let sealedBox: Data

    var hasSupportedFormat: Bool {
        version == Data([1]) && keyID.count == 16 && sealedBox.count > 28
    }
}

/// Derives an AES-256 key from an independent external credential master.
/// This master never belongs to the OAuth or Cards persisted snapshots. Rotation
/// requires a credential migration/keyring; unknown key IDs are refused.
struct ProviderCredentialVault {
    private let key: SymmetricKey
    private let keyID: Data

    static func configuredMasterKey() throws -> Data {
        guard let encoded = ProcessInfo.processInfo.environment["CREDENTIAL_ENCRYPTION_KEY"],
              let bytes = Data(base64Encoded: encoded), bytes.count == 32,
              bytes.base64EncodedString() == encoded else {
            throw ProviderCredentialError.encryptionKeyUnavailable
        }
        return bytes
    }

    init(masterKey: Data) throws {
        guard masterKey.count == 32 else {
            throw ProviderCredentialError.encryptionKeyUnavailable
        }
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey),
            salt: Data("raft.provider-credentials.hkdf-sha256.v1".utf8),
            info: Data("raft.provider-credentials.aes-256-gcm.v1".utf8),
            outputByteCount: 32
        )
        key = derivedKey
        keyID = derivedKey.withUnsafeBytes { Data(SHA256.hash(data: Data($0)).prefix(16)) }
    }

    func seal(_ apiKey: String, serverId: String, connectionId: String) throws -> ProviderCredentialEnvelope {
        guard !apiKey.isEmpty else { throw ProviderCredentialError.credentialUnavailable }
        do {
            let sealed = try AES.GCM.seal(
                Data(apiKey.utf8), using: key, nonce: AES.GCM.Nonce(),
                authenticating: context(serverId: serverId, connectionId: connectionId)
            )
            guard let combined = sealed.combined else { throw ProviderCredentialError.credentialUnavailable }
            return ProviderCredentialEnvelope(version: Data([1]), keyID: keyID, sealedBox: combined)
        } catch {
            // Do not propagate a crypto implementation error or any provider input.
            throw ProviderCredentialError.credentialUnavailable
        }
    }

    func open(_ envelope: ProviderCredentialEnvelope, serverId: String, connectionId: String) throws -> String {
        guard envelope.hasSupportedFormat, envelope.keyID == keyID else {
            throw ProviderCredentialError.credentialUnavailable
        }
        do {
            let sealed = try AES.GCM.SealedBox(combined: envelope.sealedBox)
            let plaintext = try AES.GCM.open(
                sealed, using: key, authenticating: context(serverId: serverId, connectionId: connectionId)
            )
            guard let apiKey = String(data: plaintext, encoding: .utf8), !apiKey.isEmpty else {
                throw ProviderCredentialError.credentialUnavailable
            }
            return apiKey
        } catch {
            throw ProviderCredentialError.credentialUnavailable
        }
    }

    private func context(serverId: String, connectionId: String) -> Data {
        // Length prefixes avoid ambiguous scopes; version and key ID are authenticated.
        var context = Data("raft.provider-credentials.aad.v1\u{0}\(serverId.utf8.count):\(serverId)\(connectionId.utf8.count):\(connectionId)".utf8)
        context.append(Data([1]))
        context.append(keyID)
        return context
    }
}
