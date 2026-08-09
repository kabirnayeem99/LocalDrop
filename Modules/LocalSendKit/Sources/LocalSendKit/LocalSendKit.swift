public enum LocalSendKit {
    /// Matches the reference's `common/lib/constants.dart` (`protocolVersion = '2.1'`).
    ///
    /// 2.1 carries no wire-format delta over 2.0: `wiki/LocalSend-Protocol.md` is titled v2.1 but
    /// every route, field, enum and error table in it is unchanged, the reference CHANGELOG records
    /// no schema change against the bump, and the next real protocol change (token auth,
    /// `hasWebInterface`, mandatory client-cert TLS) is v3 and unbuilt even in the reference. So
    /// there is no 2.1-exclusive behaviour left to implement before claiming it.
    ///
    /// Nothing branches on 2.x anywhere — routing only tests `== "1.0"` for legacy peers (see
    /// `fallbackProtocolVersion`), so this is a string-only change.
    public static let protocolVersion = "2.1"

    /// LocalSend's `fallbackProtocolVersion` (`common/lib/constants.dart:18`). A peer that omits
    /// `version` on the wire is a v1-era peer and must resolve to this, *not* to our own
    /// `protocolVersion` — otherwise legacy peers get mislabeled as v2.
    public static let fallbackProtocolVersion = "1.0"

    public static let apiPrefix = "/api/localsend/v2"
    public static let apiPrefixV1 = "/api/localsend/v1"

    public enum APIVersion: String, Sendable, Equatable, CaseIterable {
        case v1
        case v2

        public var prefix: String {
            switch self {
            case .v1:
                return LocalSendKit.apiPrefixV1
            case .v2:
                return LocalSendKit.apiPrefix
            }
        }
    }

    /// Single source of truth for the LocalSend route table. Both `LocalSendServer.handle` and
    /// `LocalSendServerRuntime` (which needs to know whether a request is an upload *before* the
    /// body is read) must go through this — a second, hand-rolled copy of the prefix comparison
    /// is how the two drift apart.
    public static func resolveRoute(path: String) -> (version: APIVersion, route: String)? {
        for version in APIVersion.allCases {
            let prefix = version.prefix + "/"
            guard path.hasPrefix(prefix) else { continue }
            let route = String(path.dropFirst(prefix.count))
            guard route.isEmpty == false, route.contains("/") == false else {
                return nil
            }
            return (version, route)
        }
        return nil
    }

    /// Collapses a version's legacy route spelling onto the canonical (v2) name, so handlers switch
    /// on one vocabulary instead of branching per version.
    ///
    /// v1 renamed two routes and only two (`common/lib/api_route_builder.dart`, where the enum's
    /// optional second argument is the v1 spelling):
    ///
    ///     prepareUpload('prepare-upload', 'send-request')  ->  v1 = /api/localsend/v1/send-request
    ///     upload('upload', 'send')                         ->  v1 = /api/localsend/v1/send
    ///
    /// Every other route (`info`, `register`, `cancel`, `show`, `prepare-download`, `download`)
    /// keeps its name in both versions.
    /// Returns `nil` when the spelling does not exist in that version at all. In particular the v2
    /// names `prepare-upload` and `upload` are NOT routes under `/v1` — the reference installs only
    /// the legacy spellings there — so `/api/localsend/v1/upload` stays a 404 rather than becoming
    /// a second, undocumented alias for the upload route.
    public static func canonicalRoute(version: APIVersion, route: String) -> String? {
        guard version == .v1 else {
            return route
        }
        switch route {
        case "send-request":
            return "prepare-upload"
        case "send":
            return "upload"
        case "prepare-upload", "upload":
            return nil
        default:
            return route
        }
    }

    /// Resolves a path to its version plus its CANONICAL route name.
    public static func resolveCanonicalRoute(path: String) -> (version: APIVersion, route: String)? {
        guard let resolved = resolveRoute(path: path),
              let canonical = canonicalRoute(version: resolved.version, route: resolved.route) else {
            return nil
        }
        return (resolved.version, canonical)
    }

    /// The one route whose body is streamed to disk rather than buffered in memory, and the one
    /// route exempt from `maximumJSONBodyBytes`.
    ///
    /// This MUST cover `v1/send` as well as `v2/upload`. They are the same route under two names;
    /// missing the v1 spelling would buffer a whole v1 upload in memory and reject anything over
    /// `maximumJSONBodyBytes` — which is every real file transfer from a v1 peer.
    public static func isUploadRoute(path: String) -> Bool {
        guard let resolved = resolveCanonicalRoute(path: path) else {
            return false
        }
        return resolved.route == "upload"
    }
}
