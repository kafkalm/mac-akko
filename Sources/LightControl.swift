import Foundation
import SwiftUI
import IOKit.hid

enum LightFailure: Error, LocalizedError {
    case unavailable, timeout, invalid, changed, writeFailed, verification
    var errorDescription: String? {
        switch self {
        case .unavailable: return "键盘未连接"
        case .timeout: return "键盘暂未回应，按键唤醒后重试"
        case .invalid: return "暂不支持这台键盘的灯光设置"
        case .changed: return "连接已切换，请重试"
        case .writeFailed: return "发送失败，请重试"
        case .verification: return "未确认修改成功，请刷新后重试"
        }
    }
}

enum LightProtocol {
    struct Effect { let id: Int; let name: String }
    static func effects(_ channel: Int) -> [Effect] {
        let names = channel == 0 ? ["常亮", "呼吸", "霓虹", "波浪", "涟漪", "雨滴", "贪吃蛇", "按键亮起"]
            : ["常亮", "呼吸", "霓虹", "波浪", "贪吃蛇"]
        return names.enumerated().map { Effect(id: $0.offset + 1, name: $0.element) }
    }
    static func packet(_ command: UInt8, fields: [UInt8] = []) -> [UInt8] {
        precondition([0x8f,0x85,0x87,0x88,0x05,0x07,0x08].contains(command))
        precondition(fields.count <= 7)
        var p = [UInt8](repeating: 0, count: 64)
        p[0] = command
        p.replaceSubrange(1..<(fields.count + 1), with: fields)
        let checksumIndex = command == 7 || command == 8 ? 8 : 7
        p[checksumIndex] = UInt8(255 - p.prefix(checksumIndex).reduce(0, { $0 + Int($1) }) % 256)
        return p
    }
    static func identityValid(_ p: [UInt8]) -> Bool {
        p.count == 64 && p[0] == 0x8f && Array(p[1..<5]) == [0x5f,0x0a,0,0]
            && p[7] == 9 && p[8] == 1 && p[9] == 0
    }
    static func settingsValid(_ p: [UInt8], channel: Int) -> Bool {
        p.count == 64 && p[0] == (channel == 0 ? 0x87 : 0x88)
            && p[1] <= (channel == 0 ? 25 : 6) && p[2] <= 4 && p[3] <= 4
    }
    static func toggle(_ original: [UInt8], channel: Int, enabled: Bool) -> [UInt8] {
        precondition(original.count == 64 && original[0] == 0x85 && (0...1).contains(channel))
        var flags = Array(original[1...2]); flags[channel] = enabled ? 0 : 1
        return packet(5, fields: flags)
    }
}

@MainActor
final class LightController: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var isUSB = false
    @Published private(set) var connected = false
    @Published private(set) var message = "连接键盘后可调节灯光"
    @Published private(set) var settings: [[UInt8]] = []
    private var flags: [UInt8] = []
    private var device: IOHIDDevice?
    private var generation = 0
    private var pending: (command: UInt8, continuation: CheckedContinuation<[UInt8], Error>)?
    private var deadline: DispatchWorkItem?
    private var job: Task<Void, Never>?
    var transportLabel: String { connected ? (isUSB ? "有线" : "蓝牙") : "未连接" }
    func isOn(_ channel: Int) -> Bool {
        ready && settings.count == 2 && flags.count == 64 && flags[channel + 1] == 0
            && settings[channel][1] != 0 && settings[channel][3] > 0
    }
    func brightness(_ channel: Int) -> Int { settings.count == 2 ? Int(settings[channel][3]) : 0 }
    func effect(_ channel: Int) -> Int { settings.count == 2 ? Int(settings[channel][1]) : 1 }

    func bind(_ new: IOHIDDevice?, usb: Bool) {
        if let old = device, let new, CFEqual(old, new), isUSB == usb { return }
        generation += 1; job?.cancel(); deadline?.cancel()
        let oldPending = pending; pending = nil
        oldPending?.continuation.resume(throwing: LightFailure.changed)
        device = new; isUSB = usb; connected = new != nil
        ready = false; busy = false; settings = []; flags = []
        message = new == nil ? "连接键盘后可调节灯光" : "正在读取灯光…"
        if new != nil { refresh() }
    }
    func receive(_ payload: [UInt8]) {
        guard payload.count == 64, let current = pending, payload[0] == current.command else { return }
        deadline?.cancel(); pending = nil
        current.continuation.resume(returning: payload)
    }
    private func check(_ token: Int) throws {
        guard !Task.isCancelled, token == generation, device != nil else { throw LightFailure.changed }
    }
    private func send(_ payload: [UInt8], token: Int) throws {
        try check(token)
        guard let device else { throw LightFailure.unavailable }
        let report = isUSB ? payload : [UInt8(6),0x55] + payload
        let result = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, isUSB ? kIOHIDReportTypeFeature : kIOHIDReportTypeOutput,
                                 isUSB ? 0 : 6, $0.baseAddress!, $0.count)
        }
        guard result == kIOReturnSuccess else { throw LightFailure.writeFailed }
    }
    private func read(_ command: UInt8, token: Int) async throws -> [UInt8] {
        try check(token)
        let packet = LightProtocol.packet(command)
        if isUSB {
            try send(packet, token: token)
            try await Task.sleep(nanoseconds: 60_000_000)
            try check(token)
            guard let device else { throw LightFailure.unavailable }
            var bytes = [UInt8](repeating: 0, count: 64); var count = 64
            let result = bytes.withUnsafeMutableBufferPointer {
                IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, &count)
            }
            guard result == 0, count == 64, bytes[0] == command else { throw LightFailure.timeout }
            return bytes
        }
        return try await withCheckedThrowingContinuation { continuation in
            precondition(pending == nil)
            pending = (command, continuation)
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.generation == token, let current = self.pending else { return }
                self.pending = nil
                current.continuation.resume(throwing: LightFailure.timeout)
            }
            deadline = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: timeout)
            do { try send(packet, token: token) }
            catch { deadline?.cancel(); pending = nil; continuation.resume(throwing: error) }
        }
    }
    private func snapshot(_ token: Int) async throws -> ([UInt8], [[UInt8]]) {
        guard LightProtocol.identityValid(try await read(0x8f, token: token)) else { throw LightFailure.invalid }
        let off = try await read(0x85, token: token)
        let main = try await read(0x87, token: token)
        let side = try await read(0x88, token: token)
        guard off[1] <= 1, off[2] <= 1,
              LightProtocol.settingsValid(main, channel: 0), LightProtocol.settingsValid(side, channel: 1)
        else { throw LightFailure.invalid }
        return (off,[main,side])
    }
    private func operation(_ body: @escaping @MainActor (Int) async throws -> Void) {
        guard !busy, device != nil else { return }
        let token = generation; busy = true
        job = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await body(token) }
            catch {
                if token == self.generation {
                    self.ready = false
                    self.message = error.localizedDescription
                }
            }
            if token == self.generation { self.busy = false }
        }
    }
    func refresh() {
        operation { [self] token in
            let (off, values) = try await snapshot(token)
            try check(token); flags = off; settings = values; ready = true
            message = "直接控制键盘 · 修改后自动保存"
        }
    }
    enum Change { case enabled(Bool), brightness(Int), effect(Int) }
    func setEnabled(_ enabled: Bool, channel: Int) { change(.enabled(enabled), channel: channel) }
    func setBrightness(_ value: Int, channel: Int) { change(.brightness(value), channel: channel) }
    func setEffect(_ value: Int, channel: Int) { change(.effect(value), channel: channel) }
    private func change(_ change: Change, channel: Int) {
        guard ready, (0...1).contains(channel) else { return }
        operation { [self] token in
            message = "正在应用…"
            // Re-read before each write so another channel's state or a hardware
            // shortcut is not overwritten by this UI's cached settings.
            let (off, values) = try await snapshot(token)
            var fields = Array(values[channel][1...7])
            var expectedOff = Array(off[1...2])
            switch change {
            case .enabled(let enabled):
                expectedOff[channel] = enabled ? 0 : 1
                if enabled {
                    if fields[0] == 0 { fields[0] = 1 }
                    if fields[2] == 0 { fields[2] = 3 }
                }
            case .brightness(let level):
                guard (1...4).contains(level) else { throw LightFailure.invalid }
                fields[2] = UInt8(level)
            case .effect(let effect):
                guard LightProtocol.effects(channel).contains(where: { $0.id == effect }) else { throw LightFailure.invalid }
                fields[0] = UInt8(effect); fields[1] = 2
                // Start with option0; retain the color and the supported color selector.
                fields[3] &= 15
                if fields[3] > 8 { fields[3] = 7 }
                if channel == 1 && effect == 3 { fields[3] = 8 }
            }
            if fields != Array(values[channel][1...7]) {
                try send(LightProtocol.packet(channel == 0 ? 7 : 8, fields: fields), token: token)
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if expectedOff != Array(off[1...2]) {
                try send(LightProtocol.packet(5, fields: expectedOff), token: token)
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            for _ in 0..<2 {
                let got = try await read(channel == 0 ? 0x87 : 0x88, token: token)
                let gotOff = try await read(0x85, token: token)
                guard Array(got[1...7]) == fields, Array(gotOff[1...2]) == expectedOff else { throw LightFailure.verification }
            }
            let (verifiedOff, verifiedValues) = try await snapshot(token)
            try check(token); flags = verifiedOff; settings = verifiedValues; ready = true
            message = "已保存"
        }
    }
}

func testLightProtocol() {
    var current = [UInt8](repeating: 0, count: 64); current[0] = 0x85
    for mainOff: UInt8 in 0...1 { for sideOff: UInt8 in 0...1 {
        current[1] = mainOff; current[2] = sideOff
        for channel in 0...1 { for enabled in [true,false] {
            let p = LightProtocol.toggle(current, channel: channel, enabled: enabled)
            precondition(p[channel+1] == (enabled ? 0 : 1))
            precondition(p[2-channel] == current[2-channel])
            precondition(p.count == 64 && p.prefix(8).reduce(0, { $0 + Int($1) }) % 256 == 255)
        }}
    }}
    for command: UInt8 in [7,8] { for brightness: UInt8 in 0...4 {
        let fields: [UInt8] = [1,2,brightness,7,250,255,250]
        let p = LightProtocol.packet(command, fields: fields)
        precondition(Array(p[1...7]) == fields)
        precondition(p.prefix(9).reduce(0, { $0 + Int($1) }) % 256 == 255)
        precondition(([UInt8(6),0x55] + p).count == 66)
    }}
    var id = [UInt8](repeating: 0, count: 64)
    id[0] = 0x8f; id[1] = 0x5f; id[2] = 0x0a; id[7] = 9; id[8] = 1
    precondition(LightProtocol.identityValid(id)); id[7] = 6
    precondition(!LightProtocol.identityValid(id))
    print("PASS: lighting framing, color preservation, checksums, channel isolation and identity guards")
}
