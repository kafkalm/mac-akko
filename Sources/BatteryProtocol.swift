import Foundation

enum BatteryEvent: Equatable {
    case sleeping
    case reported(Int)
    case telemetry(BatteryTelemetry)

    static func decode(_ bytes: [UInt8], reportID: UInt32) -> BatteryEvent? {
        guard reportID == 6, bytes.count >= 3, bytes[0] == 6 else { return nil }
        if bytes[1] == 0x88 { return .sleeping }
        guard bytes[1] == 0x77, bytes[2] <= 100 else { return nil }
        // The factory firmware has no ABT1 extension. Never treat its cached value as ADC data.
        guard bytes.count == 66, Array(bytes[5..<9]) == Array("ABT1".utf8) else {
            return .reported(Int(bytes[2]))
        }
        let p = Array(bytes.dropFirst())
        func u16(_ i: Int) -> Int { Int(p[i]) | (Int(p[i + 1]) << 8) }
        func u32(_ i: Int) -> UInt32 {
            UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
        }
        guard u32(48) == 0x10901, p[32] < 8, p[52] == p[32], [0, 4, 5].contains(p[33]) else { return nil }
        let samples = stride(from: 16, to: 32, by: 2).map(u16)
        let highRange = (u32(36) & (1 << 17)) != 0
        let slope = u16(highRange ? 44 : 40)
        let encodedOffset = u16(highRange ? 46 : 42)
        let offset = encodedOffset & 0x8000 != 0 ? -(encodedOffset & 0x7fff) : encodedOffset
        guard slope > 0, slope < 2000, samples.allSatisfy({ $0 > 0 && $0 <= 4095 }) else { return nil }
        let rawAverage = samples.reduce(0, +) / 8
        let millivolts = (slope * rawAverage + offset) / 1000
        guard (200...2000).contains(millivolts) else { return nil }
        return .telemetry(BatteryTelemetry(reported: Int(p[1]), adcMillivolts: millivolts,
            rawSamples: samples, supplyState: Int(p[33]), sampleIndex: Int(p[32]),
            adcMicrovolts: slope * rawAverage + offset,
            calibrationKey: "ABT1-10901-low\(!highRange)-k\(slope)-b\(offset)"))
    }
}

struct BatteryTelemetry: Equatable {
    let reported: Int
    let adcMillivolts: Int
    let rawSamples: [Int]
    let supplyState: Int
    let sampleIndex: Int
    var adcMicrovolts: Int? = nil
    var calibrationKey = "unknown"
    var measuredMicrovolts: Int { adcMicrovolts ?? adcMillivolts * 1000 }

    func hasNewBatterySample(comparedTo previous: BatteryTelemetry) -> Bool {
        supplyState != previous.supplyState || calibrationKey != previous.calibrationKey ||
            sampleIndex != previous.sampleIndex || rawSamples != previous.rawSamples
    }

    // Manufacturer's v109 voltage curve, applied to the actual sample ring.
    // This is a voltage-based estimate, not a charge-counter measurement.
    var estimatedPercentage: Int? {
        guard supplyState == 0 else { return nil } // Sampling pauses on external power.
        if adcMillivolts <= 685 { return 1 }
        if adcMillivolts <= 759 { return max(1, 20 - (15180 - 20 * adcMillivolts) / 74) }
        return min(100, 20 + (80 * adcMillivolts - 60720) / 201)
    }
}

func testBatteryProtocol() {
    precondition(BatteryEvent.decode([6, 119, 100], reportID: 6) == .reported(100))
    precondition(BatteryEvent.decode([6, 136, 0], reportID: 6) == .sleeping)
    precondition(BatteryEvent.decode([1, 119, 42], reportID: 1) == nil)
    precondition(BatteryEvent.decode([6, 119, 101], reportID: 6) == nil)
    precondition(BatteryEvent.decode([6, 119], reportID: 6) == nil)
    var bytes = [UInt8](repeating: 0, count: 66)
    bytes[0] = 6; bytes[1] = 0x77; bytes[2] = 100; bytes[4] = 3
    bytes.replaceSubrange(5..<9, with: "ABT1".utf8)
    func put16(_ payloadOffset: Int, _ value: Int) {
        bytes[payloadOffset + 1] = UInt8(value & 255)
        bytes[payloadOffset + 2] = UInt8(value >> 8)
    }
    for i in stride(from: 16, to: 32, by: 2) { put16(i, 2867) }
    put16(40, 300)
    bytes[49] = 1; bytes[50] = 9; bytes[51] = 1
    guard case .telemetry(let reading) = BatteryEvent.decode(bytes, reportID: 6) else {
        preconditionFailure("Telemetry not decoded")
    }
    precondition(reading.reported == 100 && reading.adcMillivolts == 860 && reading.estimatedPercentage == 60)
    precondition(!reading.hasNewBatterySample(comparedTo: reading))
    bytes[33] = 1; bytes[53] = 1
    guard case .telemetry(let advanced) = BatteryEvent.decode(bytes, reportID: 6) else { preconditionFailure() }
    precondition(advanced.hasNewBatterySample(comparedTo: reading))
    bytes[33] = 0; bytes[53] = 0
    put16(16, 2868)
    guard case .telemetry(let changedRing) = BatteryEvent.decode(bytes, reportID: 6) else { preconditionFailure() }
    precondition(changedRing.hasNewBatterySample(comparedTo: reading))
    put16(16, 2867)
    bytes[53] = 1
    precondition(BatteryEvent.decode(bytes, reportID: 6) == nil) // Ring changed during capture.
    bytes[53] = 0
    bytes[34] = 4
    guard case .telemetry(let charging) = BatteryEvent.decode(bytes, reportID: 6) else { preconditionFailure() }
    precondition(charging.estimatedPercentage == nil)
    bytes[34] = 0
    put16(16, 0)
    precondition(BatteryEvent.decode(bytes, reportID: 6) == nil)
    put16(16, 2867)
    bytes[39] = 2 // ADC high range selects a different calibration pair.
    put16(44, 310); put16(46, 0x8000 | 2000)
    guard case .telemetry(let highRange) = BatteryEvent.decode(bytes, reportID: 6) else { preconditionFailure() }
    precondition(highRange.adcMillivolts == 886)
    print("Battery protocol tests passed (synthetic fixtures, no hardware claim)")
}

func verifyMachineFixtures(_ path: String) throws {
    struct Fixture: Decodable {
        let report: [UInt8]
        let adcMillivolts: Int
        let percentage: Int
    }
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    precondition(!fixtures.isEmpty)
    for fixture in fixtures {
        guard case .telemetry(let reading) = BatteryEvent.decode(fixture.report, reportID: 6) else {
            preconditionFailure("Machine-generated report rejected")
        }
        precondition(reading.adcMillivolts == fixture.adcMillivolts)
        precondition(reading.estimatedPercentage == fixture.percentage)
    }
    print("Verified \(fixtures.count) machine-generated reports against original firmware conversion")
}
