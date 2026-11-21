import AppKit
import SwiftUI
import IOKit.hid

final class BatteryState: ObservableObject {
    @Published var panelVisible = false
    @Published var percentage: Int?
    @Published var estimatedPercentage: Int?
    @Published var hasFullReference = false
    @Published var calibrationMessage = "等待满电标定"
    @Published var reported: Int?
    @Published var adcMillivolts: Int?
    @Published var samples: [VoltageSample] = []
    @Published var sampleConfirmed = false
    @Published var updated: Date?
    @Published var connected = false
    @Published var sleeping = false
    @Published var externalPower = false
    @Published var permissionRequired = false
    @Published var message = "等待 Alice 蓝牙连接"
    var fresh: Bool {
        connected && !sleeping && sampleConfirmed && adcMillivolts != nil && updated.map { Date().timeIntervalSince($0) < 150 } == true
    }
}

@MainActor
struct BatteryView: View {
    @ObservedObject var state: BatteryState
    @ObservedObject var lights: LightController
    var refresh: () -> Void
    var grantAccess: () -> Void
    var quit: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredEffect: Int?
    private let amber = Color(red: 0.79, green: 0.53, blue: 0.12)
    private var enabled: Bool { lights.isOn(0) }
    private var editable: Bool { lights.ready && !lights.busy }
    private var surface: Color { scheme == .dark ? Color.white.opacity(0.065) : Color.white.opacity(0.85) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 7) {
                    Image(systemName: "keyboard").foregroundStyle(.secondary)
                    Text("mac-akko").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Circle().fill(lights.connected ? Color.green : Color.secondary.opacity(0.45)).frame(width: 5, height: 5)
                    Text(lights.transportLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.fresh && state.estimatedPercentage != nil ? "≈\(state.estimatedPercentage!)%" : "—%")
                            .font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(batteryCaption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: state.externalPower ? "powerplug.fill" : "battery.75percent")
                        .font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
                }.frame(height: 67, alignment: .top)
                Divider().opacity(0.6)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("灯光").font(.system(size: 15, weight: .semibold))
                        Text(lights.busy ? "正在设置…" : (lights.ready ? (enabled ? "已开启" : "已关闭") : "等待连接"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { lights.setEnabled(!enabled, channel: 0) } label: {
                        Image(systemName: enabled ? "lightbulb.fill" : "lightbulb")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(enabled ? amber : Color.secondary)
                            .frame(width: 44, height: 44)
                            .background(enabled ? amber.opacity(0.14) : surface, in: Circle())
                            .overlay(Circle().strokeBorder(enabled ? amber.opacity(0.25) : Color.primary.opacity(0.07)))
                    }.buttonStyle(.plain).disabled(!editable)
                        .help(enabled ? "关闭灯光" : "开启灯光")
                        .accessibilityLabel("灯光").accessibilityValue(enabled ? "开启" : "关闭")
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("亮度").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(lights.ready ? "\(lights.brightness(0)) / 4" : "—")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "sun.min").font(.system(size: 13)).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            ForEach(1...4, id: \.self) { level in
                                Button { lights.setBrightness(level, channel: 0) } label: {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(enabled && level <= lights.brightness(0) ? amber.opacity(0.35 + Double(level) * 0.15) : Color.primary.opacity(0.08))
                                        .frame(height: 24).frame(maxWidth: .infinity)
                                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.04)))
                                }.buttonStyle(.plain).help("亮度 \(level) / 4")
                                    .accessibilityLabel("亮度 \(level) 档")
                                    .accessibilityValue(level == lights.brightness(0) ? "已选择" : "未选择")
                                    .disabled(!editable || !enabled)
                            }
                        }
                        Image(systemName: "sun.max").font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("灯效").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("动画示意").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || !state.panelVisible || !enabled)) { timeline in
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                            ForEach(LightProtocol.effects(0), id: \.id) { effect in
                                let selected = lights.ready && lights.effect(0) == effect.id
                                let playing = enabled && !reduceMotion && (hoveredEffect == effect.id || (hoveredEffect == nil && selected))
                                Button { lights.setEffect(effect.id, channel: 0) } label: {
                                    VStack(spacing: 8) {
                                        EffectKeys(effect: effect.id, time: playing ? timeline.date.timeIntervalSinceReferenceDate : 0.8)
                                            .frame(height: 28).opacity(enabled ? 1 : 0.4)
                                        Text(effect.name).font(.system(size: 11, weight: selected ? .semibold : .regular))
                                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                                    }.frame(maxWidth: .infinity).padding(.vertical, 11).padding(.horizontal, 5)
                                        .background(selected ? amber.opacity(0.09) : surface, in: RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? amber.opacity(0.65) : Color.primary.opacity(hoveredEffect == effect.id ? 0.18 : 0.05), lineWidth: selected ? 1.5 : 1))
                                }.buttonStyle(.plain).disabled(!editable || !enabled)
                                    .onHover { hoveredEffect = $0 ? effect.id : (hoveredEffect == effect.id ? nil : hoveredEffect) }
                                    .accessibilityLabel("\(effect.name)灯效").accessibilityValue(selected ? "已选择" : "未选择")
                            }
                        }
                    }
                    if lights.ready && !LightProtocol.effects(0).contains(where: { $0.id == lights.effect(0) }) {
                        Text("当前使用其他灯效").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if state.permissionRequired {
                        Button("允许读取键盘", action: grantAccess).font(.system(size: 11))
                    } else {
                        Text(feedback).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button(action: refresh) { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("刷新").accessibilityLabel("刷新")
                        .disabled(lights.busy)
                    Button(action: quit) { Image(systemName: "power").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("退出应用").accessibilityLabel("退出应用")
                }.frame(minHeight: 26)
            }.padding(20)
        }.scrollIndicators(.hidden)
            .background(scheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(red: 0.965, green: 0.965, blue: 0.975))
    }
    private var feedback: String {
        if lights.busy { return "正在应用到键盘…" }
        if lights.ready { return lights.message == "已保存" ? "已应用到键盘" : "选择灯效，即刻应用" }
        return lights.message
    }
    private var batteryCaption: String {
        if state.permissionRequired { return "需要键盘读取权限" }
        if state.fresh && state.estimatedPercentage != nil { return "估算剩余电量" }
        if state.externalPower { return "外接供电中，拔线后更新电量" }
        if !state.connected { return lights.isUSB ? "有线连接，切回蓝牙查看电量" : "等待蓝牙连接" }
        if state.sleeping { return "键盘休眠，按键后更新" }
        if !state.hasFullReference { return "等待电量标定" }
        return "正在读取电量…"
    }
}

// Visual illustrations only. Timeline frames never send keyboard commands.
struct EffectKeys: View {
    let effect: Int
    let time: Double
    var body: some View {
        Canvas { context, size in
            let gap = 1.5
            let width = (size.width - gap * 7 - 3) / 8
            let height = (size.height - gap * 2) / 3
            for row in 0..<3 {
                for column in 0..<8 {
                    let x = Double(column), y = Double(row)
                    let t = time.truncatingRemainder(dividingBy: 12)
                    let offset = column >= 4 ? 3.0 : 0.0
                    let rect = CGRect(x: x * (width + gap) + offset, y: y * (height + gap), width: width, height: height)
                    var strength = 0.9
                    var hue = 0.105
                    switch effect {
                    case 2: strength = 0.2 + 0.8 * (sin(t * 2.5) + 1) / 2
                    case 3: hue = (t * 0.15).truncatingRemainder(dividingBy: 1)
                    case 4: hue = (x / 8 + t * 0.25).truncatingRemainder(dividingBy: 1)
                    case 5:
                        let distance = hypot(x - 3.5, (y - 1) * 1.5)
                        strength = max(0.12, 1 - abs(distance - (t * 2).truncatingRemainder(dividingBy: 5)) * 0.85)
                    case 6:
                        let drop = (t * 2.5 + x * 1.7).truncatingRemainder(dividingBy: 4)
                        strength = max(0.12, 1 - abs(y - drop)); hue = 0.55
                    case 7:
                        let position = row % 2 == 0 ? y * 8 + x : y * 8 + 7 - x
                        let head = (t * 7).truncatingRemainder(dividingBy: 24)
                        let trail = (head - position + 24).truncatingRemainder(dividingBy: 24)
                        strength = trail < 6 ? 1 - trail / 7 : 0.1
                    case 8:
                        let key = Int(t * 2) % 24
                        strength = row * 8 + column == key ? 1 : 0.12
                    default: break
                    }
                    let path = Path(roundedRect: rect, cornerRadius: 1.4)
                    context.fill(path, with: .color(Color(hue: hue, saturation: 0.67, brightness: 0.93).opacity(strength)))
                }
            }
        }.accessibilityHidden(true)
    }
}

final class DeviceSession {
    let device: IOHIDDevice
    var isUSB: Bool { (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue == 0x5025 }
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
    init(_ device: IOHIDDevice) { self.device = device }
    deinit { buffer.deallocate() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let state = BatteryState()
    let lights = LightController()
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    var sessions: [DeviceSession] = []
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var pollTimer: Timer?
    var displayTimer: Timer?
    var timeout: Timer?
    var previousTelemetry: BatteryTelemetry?
    var voltageHistory = VoltageHistory()
    var calibration = BatteryCalibration()
    var calibrationTimer: Timer?
    let diagnosticURL = AppStorage.file("status.json")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A single menu-bar instance avoids duplicate polling.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "mac-akko 键盘电量")
        statusItem.button?.imagePosition = .imageLeading
        popover.behavior = .transient
        popover.delegate = self
        let panelHeight = min(CGFloat(510), (NSScreen.main?.visibleFrame.height ?? 800) - 48)
        let host = NSHostingController(rootView: BatteryView(state: state, lights: lights,
            refresh: { [weak self] in self?.query(); self?.lights.refresh() },
            grantAccess: { [weak self] in self?.requestAccess() }, quit: { NSApp.terminate(nil) })
            .frame(width: 344, height: panelHeight))
        host.sizingOptions = []
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 344, height: panelHeight)
        AppStorage.migrateLegacy()
        calibration.load()
        state.calibrationMessage = calibration.message
        voltageHistory.load()
        state.samples = voltageHistory.recent()
        updateDisplay()
        // Match only the user's Alice Bluetooth product.
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDVendorIDKey: 0x3151, kIOHIDProductIDKey: 0x5027],
            [kIOHIDVendorIDKey: 0x3151, kIOHIDProductIDKey: 0x5025,
             kIOHIDPrimaryUsagePageKey: 0xffff, kIOHIDPrimaryUsageKey: 2]
        ] as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, 0)
        if result != kIOReturnSuccess || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            state.permissionRequired = true
            state.message = "需要允许输入监控，才能读取电量"
            updateDisplay()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.query() } }
        displayTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateDisplay() } }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp),
            name: NSWorkspace.didWakeNotification, object: nil)
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.async { [weak self] in self?.togglePopover() }
        }
        if CommandLine.arguments.contains("--request-access") {
            DispatchQueue.main.async { [weak self] in self?.requestAccess() }
        }
    }

    func attach(_ device: IOHIDDevice) {
        guard !sessions.contains(where: { CFEqual($0.device, device) }) else { return }
        let result = IOHIDDeviceOpen(device, 0)
        guard result == kIOReturnSuccess else {
            state.permissionRequired = true
            state.message = "需要允许输入监控，才能读取电量"
            updateDisplay()
            return
        }
        let session = DeviceSession(device)
        sessions.append(session)
        if !session.isUSB {
            IOHIDDeviceRegisterInputReportCallback(device, session.buffer, 512, { context, result, _, _, reportID, data, count in
                guard result == kIOReturnSuccess, reportID == 6, count >= 3, let context else { return }
                let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: data, count: min(count, 66)))
                if bytes.count == 66 && bytes[0] == 6 && bytes[1] == 0x55 {
                    app.lights.receive(Array(bytes.dropFirst(2)))
                } else if let event = BatteryEvent.decode(bytes, reportID: reportID) { app.received(event) }
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        updateLightDevice()
        state.connected = sessions.contains { !$0.isUSB }
        state.permissionRequired = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted
        state.message = "正在读取键盘电量…"
        query()
    }

    func detach(_ device: IOHIDDevice) {
        if let session = sessions.first(where: { CFEqual($0.device, device) }) {
            IOHIDDeviceRegisterInputReportCallback(device, session.buffer, 512, nil, nil)
        }
        IOHIDDeviceClose(device, 0)
        sessions.removeAll { CFEqual($0.device, device) }
        updateLightDevice()
        state.connected = sessions.contains { !$0.isUSB }
        if !state.connected {
            timeout?.invalidate()
            previousTelemetry = nil
            calibration.invalidatePending()
            calibrationTimer?.invalidate()
            state.estimatedPercentage = nil
            state.externalPower = false
            state.updated = nil
            state.sampleConfirmed = false
            voltageHistory.breakSegment()
            state.percentage = nil
            state.message = "蓝牙未连接 · 等待自动重连"
        }
        updateDisplay()
    }

    func updateLightDevice() {
        let selected = sessions.first(where: { $0.isUSB }) ?? sessions.first
        lights.bind(selected?.device, usb: selected?.isUSB ?? false)
    }

    func query() {
        guard sessions.contains(where: { !$0.isUSB }) else { updateDisplay(); return }
        timeout?.invalidate()
        // Official driver: vendor report 6, 65-byte payload beginning with 0x77.
        var packet = [UInt8](repeating: 0, count: 66)
        packet[0] = 6
        packet[1] = 0x77
        var success = false
        for session in sessions where !session.isUSB {
            let result = packet.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(session.device, kIOHIDReportTypeOutput, 6, $0.baseAddress!, $0.count)
            }
            success = success || result == kIOReturnSuccess
        }
        if !success {
            state.message = "电量查询失败 · 将自动重试"
            state.updated = nil
            updateDisplay()
            return
        }
        timeout = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
            guard let self else { return }
            self.state.message = "键盘暂未回应 · 将自动重试"
            self.state.updated = nil
            self.updateDisplay()
            }
        }
    }

    func received(_ event: BatteryEvent) {
        timeout?.invalidate()
        calibrationTimer?.invalidate()
        switch event {
        case .sleeping:
            state.externalPower = false
            calibration.suspend()
            state.estimatedPercentage = nil
            state.sampleConfirmed = false
            voltageHistory.breakSegment()
            state.sleeping = true
            state.message = "键盘休眠 · 唤醒后自动读取"
            previousTelemetry = nil
        case .reported(let percentage):
            state.externalPower = false
            calibration.invalidatePending()
            state.estimatedPercentage = nil
            state.sampleConfirmed = false
            voltageHistory.breakSegment()
            state.sleeping = false
            state.reported = percentage
            state.percentage = nil
            state.adcMillivolts = nil
            state.updated = Date()
            state.message = "当前固件未提供原始电池采样"
            previousTelemetry = nil
        case .telemetry(let reading):
            state.externalPower = reading.supplyState != 0
            let repeated = reading.supplyState == 0 && (previousTelemetry.map { !reading.hasNewBatterySample(comparedTo: $0) } ?? false)
            calibration.observe(reading)
            state.estimatedPercentage = calibration.estimate(reading)
            state.sleeping = false
            state.reported = reading.reported
            state.adcMillivolts = reading.adcMillivolts
            if !repeated { state.updated = Date() }
            if reading.supplyState != 0 {
                state.sampleConfirmed = false
                voltageHistory.breakSegment()
                state.percentage = nil
                state.message = "外接供电中 · 电池采样暂停"
            } else if repeated {
                state.message = "等待新的电池采样…"
            } else if let previous = previousTelemetry, previous.supplyState == 0,
                      abs(previous.adcMillivolts - reading.adcMillivolts) <= 50 {
                state.percentage = reading.estimatedPercentage
                state.sampleConfirmed = true
                voltageHistory.record(reading)
                state.samples = voltageHistory.recent()
                state.message = state.estimatedPercentage == nil ? (calibration.reference == nil ? "标定完成后启用百分比" : "采样超出标定范围 · 暂停估算") : "通用锂电估算 · 精度未经本电芯验证"
            } else {
                state.sampleConfirmed = false
                state.percentage = nil
                state.message = "正在核对电池采样…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in MainActor.assumeIsolated { self?.query() } }
            }
            previousTelemetry = reading
        }
        state.calibrationMessage = calibration.message
        if calibration.needsFastPolling && !state.sleeping {
            calibrationTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.query() } }
        }
        updateDisplay()
    }

    func requestAccess() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        state.message = "允许 Alice 电量后，退出并重新打开应用"
        updateDisplay()
    }

    func updateDisplay() {
        state.hasFullReference = calibration.reference != nil
        let title = state.fresh && state.estimatedPercentage != nil ? " ≈\(state.estimatedPercentage!)%" : (calibration.reference == nil ? " 待标定" : " —")
        statusItem?.button?.title = title
        statusItem?.button?.toolTip = "Alice 电量 · \(state.message)"
        let record: [String: Any] = [
            "connected": state.connected,
            "inputMonitoringPermissionRequired": state.permissionRequired,
            "percentage": (state.fresh ? state.estimatedPercentage : nil) as Any? ?? NSNull(),
            "calibrationPhase": String(describing: calibration.phase),
            "calibrationMessage": calibration.message,
            "fullReferenceMicrovolts": calibration.reference?.fullMicrovolts as Any? ?? NSNull(),
            "model": "full-reference-normalized generic lithium; not cell-specific capacity",
            "factoryCurvePercentage": state.percentage as Any? ?? NSNull(),
            "fullReferenceCalibrated": calibration.reference != nil,
            "remainingCapacityAccuracyVerified": false,
            "reported": state.reported as Any? ?? NSNull(),
            "adcInputMillivolts": state.adcMillivolts as Any? ?? NSNull(),
            "source": state.fresh && state.estimatedPercentage != nil ? "ADC normalized by observed full reference + generic lithium model" : "unavailable",
            "sampleHistoryCount": state.samples.count,
            "fresh": state.fresh,
            "updated": state.updated?.ISO8601Format() as Any? ?? NSNull(),
            "message": state.message,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "inputAccessGranted": IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
            "lightTransport": lights.transportLabel,
            "lightReady": lights.ready,
            "lightMessage": lights.message,
            "mainLightOn": lights.isOn(0),
            "sideLightOn": lights.isOn(1)
        ]
        do {
            try FileManager.default.createDirectory(at: diagnosticURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                .write(to: diagnosticURL, options: .atomic)
        } catch { NSLog("Status write failed: %@", error.localizedDescription) }
    }

    @objc func wokeUp() {
        calibration.suspend()
        calibrationTimer?.invalidate()
        state.sampleConfirmed = false
        voltageHistory.breakSegment()
        state.updated = nil
        previousTelemetry = nil
        updateDisplay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in MainActor.assumeIsolated { self?.query() } }
    }

    func popoverDidShow(_ notification: Notification) { state.panelVisible = true }
    func popoverDidClose(_ notification: Notification) { state.panelVisible = false }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            lights.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        calibrationTimer?.invalidate()
        displayTimer?.invalidate()
        timeout?.invalidate()
        for session in sessions {
            IOHIDDeviceRegisterInputReportCallback(session.device, session.buffer, 512, nil, nil)
            IOHIDDeviceClose(session.device, 0)
        }
        IOHIDManagerClose(manager, 0)
    }
}

if CommandLine.arguments.contains("--self-test") {
    testBatteryProtocol()
    testLightProtocol()
    testVoltageHistory()
    testBatteryCalibration()
} else if let flag = CommandLine.arguments.firstIndex(of: "--verify-fixtures"), CommandLine.arguments.count > flag + 1 {
    try verifyMachineFixtures(CommandLine.arguments[flag + 1])
} else {
    MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    }
}
