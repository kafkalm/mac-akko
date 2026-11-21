import Foundation

struct VoltageSample: Codable, Identifiable {
    var id: Date { date }
    let date: Date
    let millivolts: Int
    let segment: String
}

struct VoltageHistory {
    var samples: [VoltageSample] = []
    private var segment = UUID().uuidString
    var fileURL: URL = AppStorage.file("voltage-history.json")

    mutating func load(now: Date = Date()) {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([VoltageSample].self, from: data) {
            samples = saved.filter { (200...2000).contains($0.millivolts) && $0.date <= now && now.timeIntervalSince($0.date) < 14 * 86400 }
                .sorted { $0.date < $1.date }
        }
        // Starting a new process never implies uninterrupted measurement.
        breakSegment()
    }

    mutating func breakSegment() { segment = UUID().uuidString }

    mutating func record(_ reading: BatteryTelemetry, at date: Date = Date(), persist: Bool = true) {
        guard reading.supplyState == 0, (200...2000).contains(reading.adcMillivolts) else { breakSegment(); return }
        if let last = samples.last {
            guard date > last.date else { return }
            if last.segment == segment && date.timeIntervalSince(last.date) < 30 { return }
            if date.timeIntervalSince(last.date) > 150 { breakSegment() }
        }
        samples.append(VoltageSample(date: date, millivolts: reading.adcMillivolts, segment: segment))
        samples.removeAll { date.timeIntervalSince($0.date) > 14 * 86400 }
        if persist {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(samples).write(to: fileURL, options: .atomic)
            } catch { NSLog("Voltage history save failed: %@", error.localizedDescription) }
        }
    }

    func recent(now: Date = Date()) -> [VoltageSample] {
        samples.filter { now.timeIntervalSince($0.date) >= 0 && now.timeIntervalSince($0.date) <= 6 * 3600 }
    }
}

func voltageChangeText(_ samples: [VoltageSample]) -> String {
    guard let last = samples.last else { return "等待连续采样" }
    let run = samples.filter { $0.segment == last.segment && last.date.timeIntervalSince($0.date) <= 3600 }
    guard let first = run.first, last.date.timeIntervalSince(first.date) >= 300 else {
        return "正在积累趋势 · 短时波动不代表电量变化"
    }
    let early = run.filter { $0.date.timeIntervalSince(first.date) <= 60 }.map(\.millivolts).sorted()
    let late = run.filter { last.date.timeIntervalSince($0.date) <= 60 }.map(\.millivolts).sorted()
    guard early.count >= 2, late.count >= 2 else { return "等待更多连续采样" }
    let delta = late[late.count / 2] - early[early.count / 2]
    let minutes = Int(last.date.timeIntervalSince(first.date) / 60)
    return "约 \(minutes) 分钟采样变化 \(delta > 0 ? "+" : "")\(delta) mV · 非容量变化"
}

func testVoltageHistory() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var history = VoltageHistory()
    func reading(_ mv: Int, _ power: Int = 0) -> BatteryTelemetry {
        BatteryTelemetry(reported: 100, adcMillivolts: mv, rawSamples: Array(repeating: 3300, count: 8), supplyState: power, sampleIndex: 0)
    }
    // Both values saturate the factory percentage. The actual measured change must survive.
    precondition(reading(989).estimatedPercentage == 100 && reading(983).estimatedPercentage == 100)
    for minute in 0...6 { history.record(reading(989 - minute), at: start.addingTimeInterval(Double(minute * 60)), persist: false) }
    precondition(history.samples.count == 7 && history.samples.first!.millivolts == 989 && history.samples.last!.millivolts == 983)
    precondition(voltageChangeText(history.samples).contains("-5 mV"))
    history.record(reading(500), at: start.addingTimeInterval(361), persist: false)
    precondition(history.samples.count == 7) // Duplicate/extra polling cannot bias the history.
    history.record(reading(1000, 4), at: start.addingTimeInterval(420), persist: false)
    precondition(history.samples.count == 7) // Charging snapshots do not become discharge data.
    history.record(reading(987), at: start.addingTimeInterval(480), persist: false)
    precondition(history.samples[6].segment != history.samples[7].segment)
    history.record(reading(982), at: start.addingTimeInterval(900), persist: false)
    precondition(history.samples[7].segment != history.samples[8].segment)
    precondition(!voltageChangeText(history.samples).contains("-5 mV")) // Do not bridge sleep/charge gaps.
    print("Voltage history tests passed (plateau changes, duplicate reads, charging and gaps)")
}
