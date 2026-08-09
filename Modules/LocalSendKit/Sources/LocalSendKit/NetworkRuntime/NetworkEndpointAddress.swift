import Foundation

/// Address-text helpers shared by every `NWEndpoint` -> `String` conversion in the kit.
///
/// Both the discovery listener (`MulticastListenerRuntime.remoteHost(from:)`) and the HTTP
/// listener (`LocalSendServerRuntime.remoteAddress(from:)`) turn a peer endpoint into a plain
/// host string, and both have to deal with the same IPv6 quirk — hence one helper rather than
/// two copies that can drift.
enum NetworkEndpointAddress {
    /// Canonicalises a raw endpoint host string, **preserving** a well-formed IPv6 zone id.
    ///
    /// A link-local IPv6 endpoint arrives as `fe80::1%en0`. The zone id is not decoration: it names
    /// the interface the address is reachable on, and `fe80::1` on `en0` and `fe80::1` on `en1` are
    /// two different hosts. It is kept, for two reasons that were measured on macOS (Darwin 25.x),
    /// not assumed:
    ///
    ///  - `URLComponents` does **not** reject the `%`. Assigning `components.host = "[fe80::1%en0]"`
    ///    percent-encodes it to `[fe80::1%25en0]` (RFC 6874) and yields a non-nil `URL`.
    ///  - `URLSession` **honours** the zone. A live `NWListener` bound on a real link-local address
    ///    answers `http://[fe80::…%25en0]:PORT/` with a 200, and is unreachable via the same URL
    ///    with the zone removed (`NSURLErrorNotConnectedToInternet`, -1009). A wrong-but-existing
    ///    zone stalls until timeout; a nonexistent zone fails fast with -1009.
    ///
    /// The earlier doc comments here and at both call sites claimed the opposite ("`URLComponents`
    /// rejects the `%`"). That was factually wrong, and acting on it cost link-local routability and
    /// — on the server side — collapsed two peers reachable at the same link-local address on two
    /// interfaces into a single identity for the `snapshot.senderIP == senderIP` session-owner check.
    ///
    /// Retention policy, deliberately narrow:
    ///
    ///  - Only an **IPv6 literal** (the host text contains `:`) may keep a zone. IPv4 literals and
    ///    DNS names cannot legitimately carry one, so a `%` there is malformed input and the zone is
    ///    dropped. This is what keeps the equality classes clean: the kernel only populates
    ///    `sin6_scope_id` for scoped addresses, so a given peer either always presents a zone or
    ///    never does — it never alternates, which is what would break the owner check.
    ///  - Exactly one `%`, and the zone must be non-empty and match `[A-Za-z0-9._-]+` (interface
    ///    names such as `en0`/`utun3`, and numeric scope ids such as `11`, both qualify).
    ///  - Anything else (`fe80::1%`, `fe80::1%en0%weird`, `fe80::1%../x`) is malformed: the zone is
    ///    dropped rather than passed through. Emitting a host with a bogus zone buys an ~8-second
    ///    connect stall; dropping it fails or succeeds immediately.
    ///
    /// Input is expected to be **raw** endpoint text (`NWEndpoint` `debugDescription`, `getifaddrs`),
    /// never already RFC 6874 percent-encoded — the `%25` escaping belongs to URL construction
    /// (`LocalSendClient.makeURL`) and is applied there, once.
    ///
    /// Note also that a zoned host must never be persisted (favourites, peer stores). The zone is
    /// kernel- and boot-local and does not survive an interface renumbering.
    static func canonicalHost(from host: String) -> String {
        guard let separator = host.firstIndex(of: "%") else {
            return host
        }
        let address = String(host[host.startIndex..<separator])
        let zone = String(host[host.index(after: separator)...])

        guard address.contains(":"), isWellFormedZone(zone) else {
            return address
        }
        return address + "%" + zone
    }

    /// A zone id is well formed when it is non-empty, carries no second `%`, and is limited to the
    /// characters an interface name or a numeric scope id can contain. Everything outside that set
    /// (`/`, `.` runs used for traversal, whitespace, `@`) would either be percent-encoded into a
    /// nonsense zone or change how the URL parses.
    private static func isWellFormedZone(_ zone: String) -> Bool {
        guard zone.isEmpty == false else {
            return false
        }
        return zone.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "_" || character == "-")
        }
    }
}
