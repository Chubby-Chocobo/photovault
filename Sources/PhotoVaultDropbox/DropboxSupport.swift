import Foundation

enum DropboxEndpoint {
    static let authorize = URL(string: "https://www.dropbox.com/oauth2/authorize")!
    static let token = URL(string: "https://api.dropboxapi.com/oauth2/token")!
    static let rpcBase = "https://api.dropboxapi.com/2/"
    static let download = URL(string: "https://content.dropboxapi.com/2/files/download")!

    static func rpc(_ name: String) -> URL { URL(string: rpcBase + name)! }
}

enum DropboxForm {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    static func encode(_ fields: [(String, String)]) -> String {
        fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }
}

enum DropboxArg {
    /// JSON for the `Dropbox-API-Arg` header. HTTP headers are ASCII: every non-ASCII character and
    /// DEL become `\uXXXX` (UTF-16 units, so astral characters become surrogate pairs).
    static func header(path: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["path": path], options: [.withoutEscapingSlashes])) ?? Data()
        var out = ""
        for unit in String(decoding: data, as: UTF8.self).utf16 {
            if unit < 0x7F { out.unicodeScalars.append(Unicode.Scalar(unit)!) } else { out += String(format: "\\u%04x", unit) }
        }
        return out
    }
}

enum DropboxHTTP {
    /// `Retry-After` in seconds (Dropbox sends delta-seconds); never negative.
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }.map { max(0, $0) }
    }

    /// Dropbox error summaries look like `path/not_found/..` or `expired_access_token/`.
    static func errorSummary(_ body: Data) -> String? {
        struct Body: Decodable { var error_summary: String? }
        return (try? JSONDecoder().decode(Body.self, from: body))?.error_summary
    }

    static func errorTag(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] { return error[".tag"] as? String }
        return object["error"] as? String
    }
}
