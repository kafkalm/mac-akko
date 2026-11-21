import Foundation

// A provisional, full-reference-normalized lithium estimate. This is not a
// measured cell-specific SOC curve or a claim about the board divider ratio.
// Lithium conversion adapted from ZMK app/src/battery.c, af967667b0e139a963178e63028c7be341cade9e.
// Copyright (c) 2020 The ZMK Contributors, MIT; see THIRD-PARTY-NOTICES.txt.
struct PostFullDischargeEvidence: Codable {
    let windowStart: Date
    let windowEnd: Date
    let maximumMinuteMedianMicrovolts: Int
    let medianMicrovolts: Int
    let freshSamples: Int
    let indexRounds: Int
    let maximumSampleGapSeconds: Double
    let noSleepInValidationWindow: Bool
    let lightSettingsMatchAtEndpoints: Bool
    let terminationObservedThrough: Date
    let terminationReconfirmedAt: Date
    let unpluggedAt: Date
    let usbKeptConnectedDuringGap: Bool
    let rawLogSHA256: String
}

struct FullReference: Codable {
    let schema: Int
    let created: Date
    let calibrationKey: String
    let fullMicrovolts: Int
    let prechargeMicrovolts: Int
    let chargingSeconds: Double
    let terminationSeconds: Double
    let restingSeconds: Double
    let observedIndexRounds: Int
    let stableRangeMicrovolts: Int
    let method: String
    var postFullDischarge: PostFullDischargeEvidence? = nil

    func hasValidResponseEvidence(now: Date) -> Bool {
        if schema == 1 && method == "observed-charge-transition-normalized-zmk-lithium-v1" {
            return fullMicrovolts - prechargeMicrovolts >= 5000
        }
        guard schema == 2, method == "observed-full-then-sustained-discharge-normalized-zmk-lithium-v2",
              let e = postFullDischarge, e.windowEnd <= now,
              e.windowStart >= created, e.windowEnd.timeIntervalSince(e.windowStart) >= 300,
              e.freshSamples >= 50, e.indexRounds >= 3,
              e.maximumSampleGapSeconds > 0, e.maximumSampleGapSeconds <= 15,
              e.noSleepInValidationWindow, e.lightSettingsMatchAtEndpoints, e.usbKeptConnectedDuringGap,
              e.terminationReconfirmedAt >= e.terminationObservedThrough,
              e.unpluggedAt >= e.terminationReconfirmedAt,
              e.unpluggedAt.timeIntervalSince(e.terminationReconfirmedAt) <= 10,
              abs(created.timeIntervalSince(e.unpluggedAt) - restingSeconds) <= 1,
              e.rawLogSHA256.count == 64, e.rawLogSHA256.allSatisfy({ $0.isHexDigit }) else { return false }
        // Five one-minute medians must all fall beyond both a fixed floor and
        // twice the full candidate's observed peak-to-peak noise. The frozen
        // full reference never follows the later discharge reading downward.
        let requiredDrop = max(5000, stableRangeMicrovolts * 2)
        return (200...2000).contains(e.medianMicrovolts / 1000) &&
            (200...2000).contains(e.maximumMinuteMedianMicrovolts / 1000) &&
            e.medianMicrovolts <= e.maximumMinuteMedianMicrovolts &&
            fullMicrovolts - e.maximumMinuteMedianMicrovolts >= requiredDrop
    }
}

struct CalibrationPoint {
    let date: Date
    let microvolts: Int
}

struct BatteryCalibration {
    enum Phase: Equatable { case waiting, charging, termination, settling, ready }
    private(set) var phase: Phase = .waiting
    private(set) var reference: FullReference?
    private(set) var message = "待标定：保持蓝牙连接并插线充电"
    private var lastSeen: Date?
    private var startedCharging: Date?
    private var lastCharging: Date?
    private var startedTermination: Date?
    private var lastTermination: Date?
    private var startedSettling: Date?
    private var chargeDuration: Double = 0
    private var terminationDuration: Double = 0
    private var referenceKey: String?
    private var points: [CalibrationPoint] = []
    private var seenIndices: Set<Int> = []
    private var indexRounds = 0
    private var lastRaw: [Int] = []
    private var lastAccepted: Date?
    private var sawChargingOnThisPlug = false
    private var latestBatteryPoint: CalibrationPoint?
    private var prechargeMicrovolts: Int?
    var fileURL = AppStorage.file("full-reference.json")
    var needsFastPolling: Bool { phase == .settling }

    mutating func load(now: Date = Date()) {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(FullReference.self, from: data),
              saved.hasValidResponseEvidence(now: now),
              saved.created <= now, now.timeIntervalSince(saved.created) < 30 * 86400,
              (700_000...1_200_000).contains(saved.fullMicrovolts),
              saved.chargingSeconds >= 60, saved.terminationSeconds >= 600,
              saved.restingSeconds >= 300, saved.observedIndexRounds >= 3,
              (0...saved.fullMicrovolts / 200).contains(saved.stableRangeMicrovolts) else { return }
        reference = saved; phase = .ready
        message = "满电基准已保存 · 通用锂电模型估算"
    }

    mutating func invalidatePending() {
        startedCharging = nil; lastCharging = nil; startedTermination = nil; lastTermination = nil; startedSettling = nil
        latestBatteryPoint = nil; prechargeMicrovolts = nil
        sawChargingOnThisPlug = false; points = []; seenIndices = []; indexRounds = 0
        lastRaw = []; lastAccepted = nil; referenceKey = nil
        phase = reference == nil ? .waiting : .ready
        if reference == nil { message = "标定暂停：需要连续的充电及拔线采样" }
    }

    mutating func suspend() {
        if phase == .settling {
            points = []; seenIndices = []; indexRounds = 0; lastRaw = []; lastAccepted = nil; lastSeen = nil
            message = "静置中 · 唤醒键盘后继续采集稳定读数"
        } else { invalidatePending() }
    }

    mutating func observe(_ reading: BatteryTelemetry, at now: Date = Date(), persist: Bool = true) {
        guard reading.calibrationKey != "unknown" else { invalidatePending(); return }
        if let saved = reference, saved.calibrationKey != reading.calibrationKey || now.timeIntervalSince(saved.created) >= 30 * 86400 {
            reference = nil; invalidatePending()
        }
        if let last = lastSeen {
            guard now > last else { return }
            if now.timeIntervalSince(last) > 90 { invalidatePending() }
        }
        lastSeen = now
        if let start = startedSettling, phase == .settling, now.timeIntervalSince(start) > 1800 {
            invalidatePending(); message = "拔线已超过 30 分钟 · 本次满电基准作废"
        }
        if let key = referenceKey, key != reading.calibrationKey { invalidatePending() }
        referenceKey = reading.calibrationKey
        switch reading.supplyState {
        case 4:
            if phase != .charging {
                startedCharging = now; startedTermination = nil; lastTermination = nil; startedSettling = nil
                prechargeMicrovolts = latestBatteryPoint.flatMap { now.timeIntervalSince($0.date) <= 600 ? $0.microvolts : nil }
                points = []; seenIndices = []; indexRounds = 0
            }
            phase = .charging; sawChargingOnThisPlug = true
            lastCharging = now
            message = "正在记录充电 · 先保持蓝牙和充电线连接"
        case 5:
            if phase == .charging {
                guard let start = startedCharging, let last = lastCharging, last.timeIntervalSince(start) >= 60 else {
                    invalidatePending(); message = "充电记录不足一分钟 · 暂不设为满电"; return
                }
                chargeDuration = last.timeIntervalSince(start)
                startedTermination = now; phase = .termination
            }
            guard phase == .termination, sawChargingOnThisPlug, let start = startedTermination else {
                message = "未记录到完整充电过程 · 暂不设为满电"
                return
            }
            let elapsed = now.timeIntervalSince(start)
            lastTermination = now
            message = elapsed >= 600 ? "充电结束信号已稳定 · 请拔线并保持键盘唤醒" : "正在确认充电结束（需连续 10 分钟）"
        case 0:
            latestBatteryPoint = CalibrationPoint(date: now, microvolts: reading.measuredMicrovolts)
            if phase == .termination, let start = startedTermination, let last = lastTermination, last.timeIntervalSince(start) >= 600 {
                terminationDuration = last.timeIntervalSince(start)
                startedSettling = now; phase = .settling
                points = []; seenIndices = []; indexRounds = 0; lastAccepted = nil; lastRaw = []
            }
            if phase == .charging || phase == .termination {
                invalidatePending(); message = "拔线过早，尚未取得满电基准"; return
            }
            guard phase == .settling, let start = startedSettling else {
                if reference != nil { phase = .ready; message = "满电标定＋通用锂电估算 · 非电芯实测曲线" }
                return
            }
            if let accepted = lastAccepted, now.timeIntervalSince(accepted) < 4 { return }
            guard reading.rawSamples != lastRaw else { return }
            lastAccepted = now; lastRaw = reading.rawSamples
            seenIndices.insert(reading.sampleIndex)
            if seenIndices.count == 8 { indexRounds += 1; seenIndices = [] }
            points.append(CalibrationPoint(date: now, microvolts: reading.measuredMicrovolts))
            points.removeAll { now.timeIntervalSince($0.date) > 120 }
            message = "正在采集拔线后的稳定电压（至少 5 分钟）"
            guard now.timeIntervalSince(start) >= 300, indexRounds >= 3 else { return }
            let window = points.filter { now.timeIntervalSince($0.date) <= 65 }
            guard window.count >= 10, let oldest = window.first, now.timeIntervalSince(oldest.date) >= 55 else { return }
            let values = window.map(\.microvolts).sorted()
            let full = values[values.count / 2]
            let spread = values.last! - values.first!
            let early = Array(window.prefix(window.count / 2)).map(\.microvolts).sorted()
            let late = Array(window.suffix(window.count / 2)).map(\.microvolts).sorted()
            guard (700_000...1_200_000).contains(full), spread <= full / 200,
                  abs(early[early.count / 2] - late[late.count / 2]) <= full / 1000 else {
                message = "采样仍有漂移 · 继续等待稳定"; return
            }
            guard let before = prechargeMicrovolts, full - before >= 5000 else {
                message = "充电前后变化不足 · 尚不能确认这条采样可用于电量估算"
                return
            }
            let saved = FullReference(schema: 1, created: now, calibrationKey: reading.calibrationKey,
                fullMicrovolts: full, prechargeMicrovolts: before, chargingSeconds: chargeDuration, terminationSeconds: terminationDuration,
                restingSeconds: now.timeIntervalSince(start), observedIndexRounds: indexRounds,
                stableRangeMicrovolts: spread, method: "observed-charge-transition-normalized-zmk-lithium-v1")
            if persist {
                do {
                    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(saved).write(to: fileURL, options: .atomic)
                } catch { message = "标定保存失败 · 尚未启用百分比"; return }
            }
            reference = saved; phase = .ready
            message = "满电标定＋通用锂电估算 · 非电芯实测曲线"
        default: invalidatePending()
        }
    }

    func estimate(_ reading: BatteryTelemetry) -> Int? {
        guard reading.supplyState == 0, let saved = reference, saved.calibrationKey == reading.calibrationKey,
              reading.measuredMicrovolts <= saved.fullMicrovolts * 103 / 100 else { return nil }
        // Normalization assumes a fixed linear divider and lithium-like voltage
        // curve. 4200 is a model coordinate, not a measured battery voltage.
        let equivalentMV = reading.measuredMicrovolts * 4200 / saved.fullMicrovolts
        let percent: Int
        if equivalentMV >= 4200 { percent = 100 }
        else if equivalentMV <= 3450 { percent = 0 }
        else { percent = min(100, max(0, equivalentMV * 2 / 15 - 459)) }
        return min(100, max(0, Int((Double(percent) / 5).rounded()) * 5))
    }
}

func testBatteryCalibration() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func reading(_ uv: Int = 1_050_000, power: Int = 0, tick: Int = 0, key: String = "test-k293") -> BatteryTelemetry {
        BatteryTelemetry(reported: 100, adcMillivolts: uv / 1000,
            rawSamples: Array(repeating: 3583 + tick % 3, count: 8), supplyState: power,
            sampleIndex: tick % 8, adcMicrovolts: uv, calibrationKey: key)
    }
    func finishCharging(_ c: inout BatteryCalibration) {
        c.observe(reading(985_000), at: start.addingTimeInterval(-30), persist: false)
        for t in stride(from: 0, through: 120, by: 30) { c.observe(reading(power: 4), at: start.addingTimeInterval(Double(t)), persist: false) }
        for t in stride(from: 150, through: 750, by: 30) { c.observe(reading(power: 5), at: start.addingTimeInterval(Double(t)), persist: false) }
    }
    var uncalibrated = BatteryCalibration()
    uncalibrated.observe(reading(985_000), at: start, persist: false)
    precondition(uncalibrated.reference == nil && uncalibrated.estimate(reading(985_000)) == nil)
    for t in stride(from: 30, through: 900, by: 30) { uncalibrated.observe(reading(power: 5), at: start.addingTimeInterval(Double(t)), persist: false) }
    uncalibrated.observe(reading(), at: start.addingTimeInterval(930), persist: false)
    precondition(uncalibrated.reference == nil) // Cached100/state5 alone never becomes a full reference.
    var valid = BatteryCalibration(); finishCharging(&valid)
    for tick in 0...60 { valid.observe(reading(tick: tick), at: start.addingTimeInterval(Double(780 + tick * 5)), persist: false) }
    precondition(valid.phase == .ready && valid.reference?.fullMicrovolts == 1_050_000)
    precondition(valid.estimate(reading(985_000)) == 65) // Synthetic calibrated scenario, not a live battery claim.
    precondition(valid.estimate(reading(950_000))! < valid.estimate(reading(985_000))!)
    precondition(valid.estimate(reading(1_090_000)) == nil) // Suspiciously exceeds reference, do not silently cap100.
    precondition(valid.estimate(reading(power: 4)) == nil)
    precondition(valid.estimate(reading(key: "other-chip")) == nil)
    var insensitive = BatteryCalibration(); finishCharging(&insensitive)
    for tick in 0...90 { insensitive.observe(reading(987_000, tick: tick), at: start.addingTimeInterval(Double(780 + tick * 5)), persist: false) }
    precondition(insensitive.reference == nil) // A flat regulated rail cannot be accepted as a responsive battery signal.
    var repeated = BatteryCalibration(); finishCharging(&repeated)
    for tick in 0...90 { repeated.observe(reading(tick: 0), at: start.addingTimeInterval(Double(780 + tick * 5)), persist: false) }
    precondition(repeated.reference == nil) // Stale ring cannot accumulate calibration samples.
    var incomplete = BatteryCalibration(); finishCharging(&incomplete)
    for tick in 0...90 { incomplete.observe(reading(tick: tick * 2), at: start.addingTimeInterval(Double(780 + tick * 5)), persist: false) }
    precondition(incomplete.reference == nil) // Only4 index positions observed, not a verified full sweep.
    var gap = BatteryCalibration(); finishCharging(&gap)
    gap.observe(reading(tick: 0), at: start.addingTimeInterval(780), persist: false)
    gap.observe(reading(tick: 1), at: start.addingTimeInterval(980), persist: false)
    precondition(gap.reference == nil && gap.phase == .waiting)
    var drift = BatteryCalibration(); finishCharging(&drift)
    for tick in 0...90 { drift.observe(reading(1_000_000 + tick * 700, tick: tick), at: start.addingTimeInterval(Double(780 + tick * 5)), persist: false) }
    precondition(drift.reference == nil) // Wait beyond5min if the voltage is still drifting.
    var suspended = BatteryCalibration(); finishCharging(&suspended)
    suspended.observe(reading(tick: 0), at: start.addingTimeInterval(780), persist: false)
    suspended.suspend()
    for tick in 0...24 { suspended.observe(reading(tick: tick), at: start.addingTimeInterval(Double(1080 + tick * 5)), persist: false) }
    precondition(suspended.reference != nil) // Rest may include sleep, but new ring sweeps are required after waking.
    var expired = BatteryCalibration(); finishCharging(&expired)
    expired.observe(reading(tick: 0), at: start.addingTimeInterval(780), persist: false)
    expired.suspend()
    expired.observe(reading(tick: 1), at: start.addingTimeInterval(2700), persist: false)
    precondition(expired.reference == nil && expired.phase == .waiting)
    var early = BatteryCalibration()
    early.observe(reading(power: 4), at: start, persist: false)
    early.observe(reading(), at: start.addingTimeInterval(30), persist: false)
    precondition(early.reference == nil)
    var shortCharge = BatteryCalibration()
    shortCharge.observe(reading(985_000), at: start.addingTimeInterval(-30), persist: false)
    shortCharge.observe(reading(power: 4), at: start, persist: false)
    for t in stride(from: 30, through: 750, by: 30) { shortCharge.observe(reading(power: 5), at: start.addingTimeInterval(Double(t)), persist: false) }
    for tick in 0...60 { shortCharge.observe(reading(tick: tick), at: start.addingTimeInterval(Double(780 + tick * 5)), persist: false) }
    precondition(shortCharge.reference == nil) // Time in state5 never counts as charging.
    var shortTermination = BatteryCalibration()
    shortTermination.observe(reading(985_000), at: start.addingTimeInterval(-30), persist: false)
    for t in stride(from: 0, through: 120, by: 60) { shortTermination.observe(reading(power: 4), at: start.addingTimeInterval(Double(t)), persist: false) }
    for t in stride(from: 180, through: 720, by: 60) { shortTermination.observe(reading(power: 5), at: start.addingTimeInterval(Double(t)), persist: false) }
    for tick in 0...60 { shortTermination.observe(reading(tick: tick), at: start.addingTimeInterval(Double(780 + tick * 5)), persist: false) }
    precondition(shortTermination.reference == nil) // The unknown interval before unplug must not count as state5.
    var changedIdentity = BatteryCalibration()
    changedIdentity.observe(reading(985_000, key: "chip-A"), at: start.addingTimeInterval(-30), persist: false)
    for t in stride(from: 0, through: 120, by: 30) { changedIdentity.observe(reading(power: 4), at: start.addingTimeInterval(Double(t)), persist: false) }
    for t in stride(from: 150, through: 750, by: 30) { changedIdentity.observe(reading(power: 5), at: start.addingTimeInterval(Double(t)), persist: false) }
    for tick in 0...60 { changedIdentity.observe(reading(tick: tick), at: start.addingTimeInterval(Double(780 + tick * 5)), persist: false) }
    precondition(changedIdentity.reference == nil) // Never borrow another calibration identity's baseline.
    let original = valid.reference!
    func dischargeReference(drop: Int = 6000, seconds: Double = 300, sameLights: Bool = true,
                            maximumMinuteDrop: Int? = nil, noise: Int? = nil, noSleep: Bool = true) -> FullReference {
        let evidence = PostFullDischargeEvidence(windowStart: start.addingTimeInterval(1200),
            windowEnd: start.addingTimeInterval(1200 + seconds),
            maximumMinuteMedianMicrovolts: original.fullMicrovolts - (maximumMinuteDrop ?? drop),
            medianMicrovolts: original.fullMicrovolts - drop,
            freshSamples: 60, indexRounds: 6, maximumSampleGapSeconds: 5,
            noSleepInValidationWindow: noSleep,
            lightSettingsMatchAtEndpoints: sameLights,
            terminationObservedThrough: start.addingTimeInterval(750),
            terminationReconfirmedAt: start.addingTimeInterval(775),
            unpluggedAt: start.addingTimeInterval(780), usbKeptConnectedDuringGap: true,
            rawLogSHA256: String(repeating: "a", count: 64))
        return FullReference(schema: 2, created: original.created, calibrationKey: original.calibrationKey,
            fullMicrovolts: original.fullMicrovolts, prechargeMicrovolts: original.fullMicrovolts,
            chargingSeconds: original.chargingSeconds, terminationSeconds: original.terminationSeconds,
            restingSeconds: original.restingSeconds, observedIndexRounds: original.observedIndexRounds,
            stableRangeMicrovolts: noise ?? original.stableRangeMicrovolts,
            method: "observed-full-then-sustained-discharge-normalized-zmk-lithium-v2",
            postFullDischarge: evidence)
    }
    let checkTime = start.addingTimeInterval(2000)
    precondition(dischargeReference().hasValidResponseEvidence(now: checkTime))
    precondition(!dischargeReference(drop: 2000).hasValidResponseEvidence(now: checkTime))
    precondition(!dischargeReference(seconds: 299).hasValidResponseEvidence(now: checkTime))
    precondition(!dischargeReference(sameLights: false).hasValidResponseEvidence(now: checkTime))
    precondition(!dischargeReference(maximumMinuteDrop: 1000).hasValidResponseEvidence(now: checkTime))
    precondition(!dischargeReference(drop: 5200, noise: 2637).hasValidResponseEvidence(now: checkTime))
    precondition(!dischargeReference(noSleep: false).hasValidResponseEvidence(now: checkTime))
    precondition(!dischargeReference(drop: 1_000_000).hasValidResponseEvidence(now: checkTime))
    let decodedDischarge = try! JSONDecoder().decode(FullReference.self, from: JSONEncoder().encode(dischargeReference()))
    precondition(decodedDischarge.hasValidResponseEvidence(now: checkTime))
    precondition(decodedDischarge.prechargeMicrovolts == decodedDischarge.fullMicrovolts)
    var missingDischarge = dischargeReference(); missingDischarge.postFullDischarge = nil
    precondition(!missingDischarge.hasValidResponseEvidence(now: checkTime))
    print("Battery calibration tests passed (untrusted100, complete/stale rings, drift, gaps, model and identity)")
}
