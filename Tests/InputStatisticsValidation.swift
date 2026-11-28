import Foundation

@main
enum InputStatisticsValidation {
    static func main() throws {
        let formatter = ISO8601DateFormatter()
        let beforeMidnight = formatter.date(from: "2026-11-28T07:59:59Z")!
        let afterMidnight = formatter.date(from: "2026-11-28T08:00:00Z")!
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        expect(InputStatisticsStore.dayKey(for: beforeMidnight, timeZone: losAngeles) == 20261127)
        expect(InputStatisticsStore.dayKey(for: afterMidnight, timeZone: losAngeles) == 20261128)
        expect(InputStatisticsStore.dayKey(for: afterMidnight, timeZone: TimeZone(identifier: "Asia/Tokyo")!) == 20261128)

        let decoded = InputStatisticsStore.date(forDayKey: 20261128)!
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        let dateParts = gregorian.dateComponents([.year, .month, .day], from: decoded)
        expect(dateParts.year == 2026 && dateParts.month == 11 && dateParts.day == 28)
        expect(InputStatisticsStore.characterCount(in: "Hi 你好👩‍💻！") == 6)
        expect(InputStatisticsStore.characterCount(in: " \n\t") == 0)
        expect(InputStatisticsStore.level(for: 99) == 1)
        expect(InputStatisticsStore.level(for: 100) == 2)
        expect(InputStatisticsStore.level(for: 250) == 2)
        expect(InputStatisticsStore.threshold(for: 3) == 300)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("yah-input-statistics-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = try StatisticsDatabase(url: folder.appendingPathComponent("local.sqlite"), isShared: false)
        let shared = try StatisticsDatabase(url: folder.appendingPathComponent("shared.sqlite"), isShared: true)
        let sourceID = try local.sourceID()

        try local.recordSource(day: 20261128, typed: 2, voice: 0)
        var batch = try local.pendingRecords()
        var merged = try shared.merge(batch, sourceID: sourceID)
        try local.clearPending(merged)
        var storedDays = try shared.days()
        expect(storedDays[20261128]?.total == 2)

        try local.recordSource(day: 20261128, typed: 3, voice: 0)
        batch = try local.pendingRecords()
        _ = try shared.merge(batch, sourceID: sourceID)
        _ = try shared.merge(batch, sourceID: sourceID)
        try local.clearPending(batch)
        storedDays = try shared.days()
        expect(storedDays[20261128]?.typed == 5)
        expect(storedDays[20261128]?.total == 5)

        try local.recordSource(day: 20261128, typed: 0, voice: 3)
        batch = try local.pendingRecords()
        merged = try shared.merge(batch, sourceID: sourceID)
        _ = try shared.merge(batch, sourceID: sourceID)
        try local.clearPending(merged)
        storedDays = try shared.days()
        expect(storedDays[20261128]?.typed == 5)
        expect(storedDays[20261128]?.voice == 3)
        expect(storedDays[20261128]?.total == 8)

        try local.recordSource(day: 20261129, typed: 1, voice: 0)
        batch = try local.pendingRecords()
        merged = try shared.merge(batch, sourceID: sourceID)
        try local.clearPending(merged)
        storedDays = try shared.days()
        expect(storedDays[20261129]?.total == 1)
        expect(storedDays[20261128]?.total == 8)

        try local.recordSource(day: 20261130, typed: 2, voice: 0)
        let earlierBatch = try local.pendingRecords()
        try local.recordSource(day: 20261130, typed: 3, voice: 0)
        let committedEarlierBatch = try shared.merge(earlierBatch, sourceID: sourceID)
        try local.clearPending(committedEarlierBatch)
        batch = try local.pendingRecords()
        expect(batch.contains(where: { $0.day == 20261130 && $0.typed == 5 }))
        merged = try shared.merge(batch, sourceID: sourceID)
        try local.clearPending(merged)
        storedDays = try shared.days()
        expect(storedDays[20261130]?.total == 5)

        print("Input statistics boundary validation passed.")
    }

    private static func expect(_ condition: @autoclosure () -> Bool) {
        guard condition() else { fatalError("Input statistics boundary validation failed.") }
    }
}
