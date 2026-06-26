import Foundation
import CryptoKit

/// Port of La Marzocco's customer-app authentication crypto from `pylamarzocco`
/// (util/_authentication.py). The cloud API requires every request to carry an
/// installation identity proven via a derived secret + an ECDSA (P-256) signature.
struct InstallationKey {
    let installationId: String
    let privateKey: P256.Signing.PrivateKey
    /// 32-byte secret deterministically derived from the installation id + public key.
    let secret: Data

    /// DER-encoded SubjectPublicKeyInfo of the public key.
    var publicKeyDER: Data { privateKey.publicKey.derRepresentation }

    var publicKeyB64: String { publicKeyDER.base64EncodedString() }

    /// "{installation_id}.{base64(sha256(public_key_der))}"
    var baseString: String {
        let hash = Data(SHA256.hash(data: publicKeyDER))
        return "\(installationId).\(hash.base64EncodedString())"
    }

    // MARK: - Construction

    /// Generate a brand-new installation identity (one per app install).
    static func generate() -> InstallationKey {
        let installationId = UUID().uuidString.lowercased()
        let privateKey = P256.Signing.PrivateKey()
        let secret = Self.deriveSecret(installationId: installationId,
                                       publicKeyDER: privateKey.publicKey.derRepresentation)
        return InstallationKey(installationId: installationId,
                               privateKey: privateKey,
                               secret: secret)
    }

    /// Reconstruct from persisted material.
    init?(installationId: String, privateKeyRaw: Data) {
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw) else {
            return nil
        }
        self.installationId = installationId
        self.privateKey = key
        self.secret = Self.deriveSecret(installationId: installationId,
                                        publicKeyDER: key.publicKey.derRepresentation)
    }

    private init(installationId: String, privateKey: P256.Signing.PrivateKey, secret: Data) {
        self.installationId = installationId
        self.privateKey = privateKey
        self.secret = secret
    }

    /// Raw 32-byte scalar for persistence.
    var privateKeyRaw: Data { privateKey.rawRepresentation }

    private static func deriveSecret(installationId: String, publicKeyDER: Data) -> Data {
        let pubB64 = publicKeyDER.base64EncodedString()
        let instHash = Data(SHA256.hash(data: Data(installationId.utf8)))
        let instHashB64 = instHash.base64EncodedString()
        let triple = "\(installationId).\(pubB64).\(instHashB64)"
        return Data(SHA256.hash(data: Data(triple.utf8)))
    }
}

enum LMProof {
    /// La Marzocco's bespoke "Y5.e" proof algorithm. Mutates a copy of the 32-byte
    /// secret byte-by-byte over the input string, then returns base64(sha256(work)).
    static func requestProof(baseString: String, secret: Data) -> String {
        precondition(secret.count == 32, "secret must be 32 bytes")
        var work = [UInt8](secret)
        for byteVal in Array(baseString.utf8) {
            let idx = Int(byteVal) % 32
            let shiftIdx = (idx + 1) % 32
            let shiftAmount = Int(work[shiftIdx] & 7) // 0...7
            let xor = Int(byteVal) ^ Int(work[idx])   // 0...255
            // XOR then rotate-left within a byte. (xor >> 8 == 0 when shiftAmount == 0.)
            let rotated = ((xor << shiftAmount) | (xor >> (8 - shiftAmount))) & 0xFF
            work[idx] = UInt8(rotated)
        }
        return Data(SHA256.hash(data: Data(work))).base64EncodedString()
    }

    /// Headers required on all authenticated requests (and the signin/refresh calls).
    static func requestHeaders(for key: InstallationKey) -> [String: String] {
        let nonce = UUID().uuidString.lowercased()
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000)) // ms
        let proofInput = "\(key.installationId).\(nonce).\(timestamp)"
        let proof = requestProof(baseString: proofInput, secret: key.secret)
        let signatureData = "\(proofInput).\(proof)"
        let signature = (try? key.privateKey.signature(for: Data(signatureData.utf8)))?
            .derRepresentation ?? Data()
        return [
            "X-App-Installation-Id": key.installationId,
            "X-Timestamp": timestamp,
            "X-Nonce": nonce,
            "X-Request-Signature": signature.base64EncodedString(),
        ]
    }
}
