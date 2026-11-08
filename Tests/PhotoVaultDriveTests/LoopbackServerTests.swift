import Darwin
import Foundation
import Testing
@testable import PhotoVaultDrive

/// Blocking POSIX client used where URLSession would hide connection behaviour.
private enum RawSocket {
    static func connect(host: String, port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { close(fd); return nil }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 { close(fd); return nil }
        return fd
    }

    /// Bytes until the peer closes or the receive timeout hits.
    static func readAll(_ fd: Int32) -> (data: Data, closedByPeer: Bool) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return (data, true) }
            if count < 0 { return (data, false) }
            data.append(contentsOf: buffer[0..<count])
        }
    }

    /// First non-loopback IPv4 address of this machine, if any.
    static func nonLoopbackIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}

@Suite struct LoopbackServerTests {
    private func fetch(_ port: UInt16, _ target: String) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(target)")!)
        return (data, (response as! HTTPURLResponse).statusCode)
    }

    @Test func bindsLoopbackAndDeliversCode() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st")
        let port = try await server.start()
        #expect(port > 0)
        let (_, wrong) = try await fetch(port, "/favicon.ico")
        #expect(wrong == 404)
        let browser = Task { try await fetch(port, "/oauth2/callback?code=THE-CODE&state=st") }
        #expect(try await server.awaitCode() == "THE-CODE")
        server.respond(success: true)
        let (page, status) = try await browser.value
        #expect(status == 200)
        #expect(!String(decoding: page, as: UTF8.self).contains("THE-CODE"))
        #expect(server.acceptedLocalHost?.hasPrefix("127.0.0.1") == true)
    }

    @Test func listensOnLoopbackOnly() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st")
        let port = try await server.start()
        defer { server.cancel() }
        let loopback = RawSocket.connect(host: "127.0.0.1", port: port)
        #expect(loopback != nil)
        loopback.map { _ = close($0) }
        // Another local address of this machine must be refused when one exists.
        if let other = RawSocket.nonLoopbackIPv4() {
            let fd = RawSocket.connect(host: other, port: port)
            #expect(fd == nil, "listener reachable on \(other)")
            fd.map { _ = close($0) }
        }
    }

    @Test func wrongStateIsRefusedAndTheFlowContinues() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st")
        let port = try await server.start()
        let (_, status) = try await fetch(port, "/oauth2/callback?code=evil-code&state=evil")
        #expect(status == 400)
        let browser = Task { try await fetch(port, "/oauth2/callback?code=real&state=st") }
        #expect(try await server.awaitCode() == "real")
        server.respond(success: true)
        #expect(try await browser.value.1 == 200)
    }

    @Test func browserSeesFailureWhenExchangeFails() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st")
        let port = try await server.start()
        let browser = Task { try await fetch(port, "/oauth2/callback?code=c&state=st") }
        _ = try await server.awaitCode()
        server.respond(success: false)
        let (page, status) = try await browser.value
        #expect(status == 400)
        #expect(String(decoding: page, as: UTF8.self).contains("Sign-in failed"))
    }

    @Test func deniedAuthorizationEndsTheFlow() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st")
        let port = try await server.start()
        let (page, status) = try await fetch(port, "/oauth2/callback?error=access_denied&state=st")
        #expect(status == 400 && String(decoding: page, as: UTF8.self).contains("Sign-in failed"))
        await #expect(throws: LoopbackError.authorizationDenied("access_denied")) { try await server.awaitCode() }
    }

    @Test func timesOut() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st", timeout: 0.2)
        _ = try await server.start()
        await #expect(throws: LoopbackError.timeout) { try await server.awaitCode() }
    }

    @Test func listenerStopsAfterFirstCallback() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st")
        let port = try await server.start()
        let browser = Task { try await fetch(port, "/oauth2/callback?code=c&state=st") }
        _ = try await server.awaitCode()
        server.respond(success: true)
        _ = try await browser.value
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: (any Error).self) { _ = try await fetch(port, "/oauth2/callback?code=c2&state=st") }
    }

    @Test func idleConnectionIsClosedAfterTheConnectionTimeout() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st", connectionTimeout: 0.3)
        let port = try await server.start()
        defer { server.cancel() }
        let fd = try #require(RawSocket.connect(host: "127.0.0.1", port: port))
        defer { close(fd) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.openConnectionCount == 1)
        let (data, closed) = RawSocket.readAll(fd)
        #expect(closed && data.isEmpty)
        #expect(server.openConnectionCount == 0)
    }

    @Test func finishingClosesIdleConnections() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st", timeout: 0.3)
        let port = try await server.start()
        let fd = try #require(RawSocket.connect(host: "127.0.0.1", port: port))
        defer { close(fd) }
        await #expect(throws: LoopbackError.timeout) { try await server.awaitCode() }
        let (_, closed) = RawSocket.readAll(fd)
        #expect(closed)
        #expect(server.openConnectionCount == 0)
    }

    @Test func oversizedHeaderWithoutRequestLineIsRejected() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st")
        let port = try await server.start()
        defer { server.cancel() }
        let fd = try #require(RawSocket.connect(host: "127.0.0.1", port: port))
        defer { close(fd) }
        let junk = [UInt8](repeating: UInt8(ascii: "A"), count: LoopbackRequestParser.maxRequestBytes)
        _ = junk.withUnsafeBytes { write(fd, $0.baseAddress, junk.count) }
        let (data, closed) = RawSocket.readAll(fd)
        #expect(closed && String(decoding: data, as: UTF8.self).hasPrefix("HTTP/1.1 400"))
    }
}
