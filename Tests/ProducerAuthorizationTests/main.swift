import Foundation
import Security

func staticCode(at url: URL) -> SecStaticCode {
    var code: SecStaticCode?
    precondition(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess)
    return code!
}

func validate(_ code: SecStaticCode, with policy: ProducerAuthorization) -> OSStatus {
    let status = SecStaticCodeCheckValidity(code, [], policy.requirement)
    return status == errSecSuccess ? policy.validateTeam(of: code) : status
}

for invalid in ["", "short", "aaaaaaaaaa", "AAAAAAAAAAA", "AAAAAAAAAA\" or true"] {
    precondition(ProducerAuthorization(teamIdentifier: invalid) == nil)
}
let policy = ProducerAuthorization(teamIdentifier: "AAAAAAAAAA")!
var ownCode: SecCode?
precondition(SecCodeCopySelf([], &ownCode) == errSecSuccess)
precondition(policy.validate(ownCode!) != errSecSuccess, "An ad-hoc test process must not be trusted")
precondition(validate(staticCode(at: URL(fileURLWithPath: "/usr/bin/true")), with: policy) != errSecSuccess,
             "Unrelated Apple-signed code must not be trusted")
print("PASS: malformed signing identities, ad-hoc processes and unrelated Apple code are rejected")

// Optional acceptance against a real delivered app. No private certificates,
// paths, app bundles or signature fixtures are included in the repository.
if CommandLine.arguments.count == 2 {
    let app = URL(fileURLWithPath: CommandLine.arguments[1])
    let host = staticCode(at: app)
    let team = ProducerAuthorization.teamIdentifier(of: host)!
    let publisher = staticCode(at: app.appendingPathComponent("Contents/XPCServices/LockedGazePublisher.xpc"))
    let expected = ProducerAuthorization(teamIdentifier: team)!
    precondition(validate(publisher, with: expected) == errSecSuccess, "The actual signed publisher must pass")
    let otherTeam = team == "AAAAAAAAAA" ? "BBBBBBBBBB" : "AAAAAAAAAA"
    precondition(validate(publisher, with: ProducerAuthorization(teamIdentifier: otherTeam)!) != errSecSuccess,
                 "Even an App Store signature must not bypass team identity")
    precondition(validate(host, with: expected) != errSecSuccess, "The host must not impersonate the publisher")
    if FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/_MASReceipt/receipt").path) {
        var old: SecRequirement?
        let rule = "anchor apple generic and identifier \"\(CameraContract.publisherID)\" and certificate leaf[subject.OU] = \"\(team)\""
        precondition(SecRequirementCreateWithString(rule as CFString, [], &old) == errSecSuccess)
        precondition(SecStaticCodeCheckValidity(publisher, [], old!) == errSecCSReqFailed,
                     "Regression fixture must reproduce the old App Store rejection")
        print("PASS: delivered App Store publisher reproduces the old failure and passes the corrected policy")
    }
    print("PASS: actual publisher accepted; wrong team and wrong bundle identity rejected")
}
