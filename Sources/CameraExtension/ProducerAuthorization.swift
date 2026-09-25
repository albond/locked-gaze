import Foundation
import Security

/// Accepts only our publisher, with a valid Apple signature and our signing team.
struct ProducerAuthorization {
    private let teamIdentifier: String
    let requirement: SecRequirement

    init?(teamIdentifier: String) {
        guard teamIdentifier.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        // App Store delivery replaces the developer certificate with Apple's
        // Mac OS Application Signing certificate. Its OU is not our Team ID.
        // The signed CodeDirectory still contains the original Team ID, which
        // must be checked separately for BOTH distribution paths below.
        let rule = "anchor apple generic and identifier \"\(CameraContract.publisherID)\" and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate leaf[subject.OU] = \"\(teamIdentifier)\")"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        self.teamIdentifier = teamIdentifier
        self.requirement = requirement
    }

    static func teamIdentifier(of code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    func validate(_ guest: SecCode) -> OSStatus {
        // Keep validation tied to the live process, including its dynamic-code
        // signature. Never authorize from signingID, a path or Team ID alone.
        let status = SecCodeCheckValidity(guest, [], requirement)
        guard status == errSecSuccess else { return status }
        var code: SecStaticCode?
        let copied = SecCodeCopyStaticCode(guest, [], &code)
        guard copied == errSecSuccess, let code else { return copied == errSecSuccess ? errSecCSUnsigned : copied }
        return validateTeam(of: code)
    }

    /// Call only after successful signature validation against `requirement`.
    func validateTeam(of code: SecStaticCode) -> OSStatus {
        Self.teamIdentifier(of: code) == teamIdentifier ? errSecSuccess : errSecCSReqFailed
    }
}
