import Darwin
import Foundation
import Security

/// Local, one-way frame channel from Locked Gaze to its browser helper (LG-009).
/// Plain Mach messages: no sockets and no network. The helper sends only "subscribe" and
/// "unsubscribe" with a port for frames; Locked Gaze answers with JPEG frames. Each side
/// checks the other's code signature from the kernel's audit token, so no other process
/// can subscribe to the camera or pose as Locked Gaze.
enum BrowserContract {
    static let groupSuffix = "local.lockedgaze.app"
    static let appIdentifier = "local.lockedgaze.app"
    static let helperIdentifier = "local.lockedgaze.app.browser-host"
    static let safariIdentifier = "local.lockedgaze.app.safari"
    /// Message IDs.
    static let subscribe: Int32 = 1
    static let unsubscribe: Int32 = 2
    static let frame: Int32 = 3
    /// The helper renews its subscription every second; Locked Gaze forgets it after this.
    static let subscriptionLifetime: TimeInterval = 3
    static let renewInterval: TimeInterval = 1
    static let jpegQuality = 0.7
    /// Native Messaging host name and the Chrome extensions allowed to start the helper.
    static let chromeHostName = "local.lockedgaze.browser"
    /// The development extension's ID, fixed by the public key in its manifest. Add the
    /// Chrome Web Store ID once the extension is published.
    static let chromeExtensionIDs = ["nlbakekjhdidpffgiaencjgpaleoimpf"]
    /// Larger frames are dropped by the receiver.
    static let maxPayload = 2_000_000

    /// Sandboxed processes may only register and look up names inside their App Group.
    static func appPortName(group: String?) -> String { (group ?? groupSuffix) + ".browser" }

    /// The team-prefixed App Group this process is signed with, if any.
    static func signedGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil),
              let groups = value as? [String] else { return nil }
        return groups.first { $0.hasSuffix(groupSuffix) }
    }

    /// The Team ID this process is signed with; nil for ad-hoc and unsigned development builds.
    static func signedTeam() -> String? {
        var code: SecCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              let staticCode = { () -> SecStaticCode? in var s: SecStaticCode?; return SecCodeCopyStaticCode(code, [], &s) == errSecSuccess ? s : nil }(),
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// What a peer must be: Apple-signed code with one of the identifiers, from our team.
    /// App Store and TestFlight delivery re-sign with Apple certificates whose OU is not our
    /// Team ID (Mac App Store OID 1.2.840.113635.100.6.1.9, TestFlight 1.2.840.113635.100.6.1.25.1),
    /// so, as for the camera extension's producer check, the certificate may be either of
    /// those or ours, and the Team ID recorded in the signed CodeDirectory must be ours.
    struct PeerPolicy {
        let requirement: String
        let team: String
    }

    /// nil when this process is unsigned (development builds and tests): it then accepts any peer.
    static func policy(identifier: String, team: String?) -> PeerPolicy? { policy(identifiers: [identifier], team: team) }
    static func policy(identifiers: [String], team: String?) -> PeerPolicy? {
        guard let team, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        let any = identifiers.map { #"identifier "\#($0)""# }.joined(separator: " or ")
        let certificate = #"certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate leaf[field.1.2.840.113635.100.6.1.25.1] exists or certificate leaf[subject.OU] = "\#(team)""#
        return PeerPolicy(requirement: "anchor apple generic and (\(any)) and (\(certificate))", team: team)
    }

    /// Frame payload: seq (UInt64), capture time in ms since 1970 (Double), encode µs (UInt32), then JPEG bytes.
    static let headerSize = 20
    static func encodeFrame(seq: UInt64, captureMs: Double, encodeMicros: UInt32, jpeg: Data) -> Data {
        var data = Data(capacity: headerSize + jpeg.count)
        withUnsafeBytes(of: seq.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: captureMs.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: encodeMicros.littleEndian) { data.append(contentsOf: $0) }
        data.append(jpeg)
        return data
    }
    static func decodeFrame(_ data: Data) -> (seq: UInt64, captureMs: Double, encodeMicros: UInt32, jpeg: Data)? {
        guard data.count > headerSize else { return nil }
        return data.withUnsafeBytes { raw in
            let seq = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self))
            let ms = Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
            let micros = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
            return (seq, ms, micros, data.subdata(in: data.startIndex + headerSize ..< data.endIndex))
        }
    }
}

// Public functions of <servers/bootstrap.h>, which the Darwin module does not import. Only
// functions declared available there may be listed: App Review rejects private ones.
@_silgen_name("bootstrap_check_in")
private func bootstrapCheckIn(_ bootstrap: mach_port_t, _ name: UnsafePointer<CChar>, _ port: UnsafeMutablePointer<mach_port_t>) -> kern_return_t
@_silgen_name("bootstrap_look_up")
private func bootstrapLookUp(_ bootstrap: mach_port_t, _ name: UnsafePointer<CChar>, _ port: UnsafeMutablePointer<mach_port_t>) -> kern_return_t

/// Minimal Mach messaging: inline payloads and the kernel's audit trailer.
enum MachChannel {
    struct Received {
        let id: Int32
        let payload: Data
        /// A send right to the sender's port, or MACH_PORT_NULL. The receiver owns it.
        let replyPort: mach_port_t
        let audit: audit_token_t
        var pid: pid_t { pid_t(bitPattern: audit.val.5) }
    }

    private static let headerSize = MemoryLayout<mach_msg_header_t>.size
    private static let trailerSize = MemoryLayout<mach_msg_audit_trailer_t>.size
    // MACH_MSGH_BITS and the trailer request are C macros Swift does not import.
    private static let copySend = mach_msg_bits_t(MACH_MSG_TYPE_COPY_SEND)
    private static let makeSend = mach_msg_bits_t(MACH_MSG_TYPE_MAKE_SEND)
    private static let auditTrailer = mach_msg_option_t(MACH_RCV_TRAILER_AUDIT) << 24

    private static var bootstrap: mach_port_t {
        var port = mach_port_t(MACH_PORT_NULL)
        task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &port)
        return port
    }

    /// A new receive right with one send right of the same name.
    static func makeReceivePort() -> mach_port_t? {
        var port = mach_port_t(MACH_PORT_NULL)
        guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS else { return nil }
        guard mach_port_insert_right(mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS else {
            destroyReceivePort(port); return nil
        }
        return port
    }
    static func destroyReceivePort(_ port: mach_port_t) {
        mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
        mach_port_deallocate(mach_task_self_, port)
    }
    /// Claims `name` with the public bootstrap API and returns its receive right, with one send
    /// right of the same name as in `makeReceivePort`. Nil when another process holds the name.
    static func checkIn(_ name: String) -> mach_port_t? {
        var port = mach_port_t(MACH_PORT_NULL)
        guard name.withCString({ bootstrapCheckIn(bootstrap, $0, &port) }) == KERN_SUCCESS, port != MACH_PORT_NULL else { return nil }
        guard mach_port_insert_right(mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS else {
            mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1); return nil
        }
        return port
    }
    /// A send right to the named port; release it with `release`.
    static func lookUp(_ name: String) -> mach_port_t? {
        var port = mach_port_t(MACH_PORT_NULL)
        return name.withCString { bootstrapLookUp(bootstrap, $0, &port) } == KERN_SUCCESS && port != MACH_PORT_NULL ? port : nil
    }
    static func release(_ sendRight: mach_port_t) { mach_port_deallocate(mach_task_self_, sendRight) }

    /// Sends without blocking for longer than `timeout` ms. `reply`, when given, travels as a new send right.
    @discardableResult
    static func send(to port: mach_port_t, id: Int32, payload: Data = Data(), reply: mach_port_t? = nil, timeout: mach_msg_timeout_t = 0) -> kern_return_t {
        let body = (4 + payload.count + 3) & ~3
        let size = headerSize + body
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let header = buffer.assumingMemoryBound(to: mach_msg_header_t.self)
        header.pointee.msgh_bits = copySend | (reply == nil ? 0 : makeSend << 8)
        header.pointee.msgh_size = mach_msg_size_t(size)
        header.pointee.msgh_remote_port = port
        header.pointee.msgh_local_port = reply ?? mach_port_t(MACH_PORT_NULL)
        header.pointee.msgh_id = id
        buffer.storeBytes(of: UInt32(payload.count).littleEndian, toByteOffset: headerSize, as: UInt32.self)
        payload.withUnsafeBytes { if let base = $0.baseAddress { (buffer + headerSize + 4).copyMemory(from: base, byteCount: payload.count) } }
        return mach_msg(header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, mach_msg_size_t(size), 0, mach_port_t(MACH_PORT_NULL), timeout, mach_port_t(MACH_PORT_NULL))
    }

    /// Receives one waiting message, or nil when none is waiting. Oversized messages are dropped.
    static func receive(on port: mach_port_t, maxPayload: Int) -> Received? {
        let capacity = headerSize + ((4 + maxPayload + 3) & ~3) + trailerSize
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        let header = buffer.assumingMemoryBound(to: mach_msg_header_t.self)
        while true {
            let result = mach_msg(header, MACH_RCV_MSG | MACH_RCV_TIMEOUT | auditTrailer, 0, mach_msg_size_t(capacity), port, 0, mach_port_t(MACH_PORT_NULL))
            if result == MACH_RCV_TOO_LARGE { continue }
            guard result == MACH_MSG_SUCCESS else { return nil }
            let size = Int(header.pointee.msgh_size)
            let trailer = (buffer + ((size + 3) & ~3)).loadUnaligned(as: mach_msg_audit_trailer_t.self)
            let reply = header.pointee.msgh_remote_port
            // Complex messages (descriptors) are never part of this protocol.
            guard header.pointee.msgh_bits & mach_msg_bits_t(MACH_MSGH_BITS_COMPLEX) == 0, size >= headerSize + 4 else {
                if reply != MACH_PORT_NULL { release(reply) }
                continue
            }
            let length = Int(UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: headerSize, as: UInt32.self)))
            guard length <= size - headerSize - 4 else { if reply != MACH_PORT_NULL { release(reply) }; continue }
            return Received(id: header.pointee.msgh_id, payload: Data(bytes: buffer + headerSize + 4, count: length),
                            replyPort: reply, audit: trailer.msgh_audit)
        }
    }

    /// True when the sender's live code meets the policy (or there is none to meet).
    static func verify(_ audit: audit_token_t, policy: BrowserContract.PeerPolicy?) -> Bool {
        guard let policy else { return true }
        var token = audit
        let data = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        var parsed: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(policy.requirement as CFString, [], &parsed) == errSecSuccess, let parsed,
              SecCodeCheckValidity(code, [], parsed) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return false }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String == policy.team
    }
}
