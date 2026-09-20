import Darwin
import Foundation
import PlinkCore
import Testing

private func testPort() throws -> UInt16 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    defer { Darwin.close(fd) }
    var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
        sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0,0,0,0,0,0,0,0))
    let rc = withUnsafeMutablePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard rc == 0 else { throw FoundationPlinkServerError.bindFailed }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    return UInt16(bigEndian: addr.sin_port)
}
private func connectForTest(_ port: UInt16) throws -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian,
        sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0,0,0,0,0,0,0,0))
    let rc = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard rc == 0 else { Darwin.close(fd); throw FoundationPlinkServerError.socketSetupFailed }
    return fd
}

@Test func partialSocketDeadlineAllowsNextCompleteFrame() throws {
    let port = try testPort()
    let server = FoundationLengthPrefixedMessageServer(port: port, readTimeout: 0.15)
    let delivered = DispatchSemaphore(value: 0)
    try server.start { if case .success = $0 { delivered.signal() } }
    defer { server.stop() }
    let stalled = try connectForTest(port)
    defer { Darwin.close(stalled) }
    var byte: UInt8 = 0
    _ = Darwin.write(stalled, &byte, 1)
    let good = try connectForTest(port)
    defer { Darwin.close(good) }
    let data = try LengthPrefixedFrameCodec.encode(Data("synthetic".utf8))
    _ = data.withUnsafeBytes { Darwin.write(good, $0.baseAddress!, data.count) }
    #expect(delivered.wait(timeout: .now() + 2) == .success)
}

@Test func stopClosesAcceptedClientAndAllowsRebind() throws {
    let port = try testPort()
    let server = FoundationLengthPrefixedMessageServer(port: port)
    let delivered = DispatchSemaphore(value: 0)
    try server.start { if case .success = $0 { delivered.signal() } }
    let stalled = try connectForTest(port)
    defer { Darwin.close(stalled) }
    usleep(30_000)
    server.stop()
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(stalled, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var byte: UInt8 = 0
    #expect(Darwin.read(stalled, &byte, 1) == 0)
    #expect(delivered.wait(timeout: .now()) == .timedOut)
    let replacement = FoundationLengthPrefixedMessageServer(port: port)
    try replacement.start { _ in }
    replacement.stop()
    server.stop() // Idempotent; must not close replacement/unrelated descriptors.
}

@Test func startReportsBindFailureSynchronously() throws {
    let port = try testPort()
    let first = FoundationLengthPrefixedMessageServer(port: port)
    try first.start { _ in }
    defer { first.stop() }
    let second = FoundationLengthPrefixedMessageServer(port: port)
    #expect(throws: FoundationPlinkServerError.bindFailed) { try second.start { _ in } }
}
