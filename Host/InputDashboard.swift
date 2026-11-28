import SwiftUI
import UIKit
import Combine

private enum InputDashboardPalette {
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 21 / 255, green: 20 / 255, blue: 25 / 255, alpha: 1)
            : UIColor(red: 245 / 255, green: 245 / 255, blue: 248 / 255, alpha: 1)
    })
    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 38 / 255, green: 36 / 255, blue: 43 / 255, alpha: 1)
            : .white
    })
    static let accent = YahTheme.accent
    static let mutedAccent = YahTheme.mutedAccent
    static let accentBackground = YahTheme.accentBackground
    static let track = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 57 / 255, green: 55 / 255, blue: 62 / 255, alpha: 1)
            : UIColor(red: 233 / 255, green: 233 / 255, blue: 234 / 255, alpha: 1)
    })
    static let separator = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 71 / 255, green: 68 / 255, blue: 78 / 255, alpha: 1)
            : UIColor(red: 236 / 255, green: 236 / 255, blue: 236 / 255, alpha: 1)
    })
}

private enum InputDashboardRange: String, CaseIterable, Identifiable, Equatable {
    case day = "日"
    case week = "周"
    case month = "月"

    var id: String { rawValue }
}

private struct InputDashboardBucket: Identifiable {
    let start: Int
    let end: Int
    let label: String

    var id: Int { start }
}

struct InputDashboardView: View {
    @Environment(\.scenePhase) private var scenePhase
    let keyboardActivated: Bool
    let onOpenSettings: () -> Void

    @State private var snapshot = InputStatisticsSnapshot.empty
    @State private var loadError: String?
    @State private var range: InputDashboardRange = .day
    @State private var anchorDay = InputStatisticsStore.dayKey()
    @State private var followsToday = true
    @State private var selectedBucket: Int?
    @State private var showLevel = false
    @State private var showDatePicker = false

    private var buckets: [InputDashboardBucket] {
        Self.buckets(range: range, anchorDay: anchorDay)
    }

    private var chartValues: [Int] {
        buckets.map { bucket in
            snapshot.days.values.reduce(0) { total, day in
                total + ((day.key >= bucket.start && day.key <= bucket.end) ? day.total : 0)
            }
        }
    }

    private var selectedIndex: Int {
        if let selectedBucket, let index = buckets.firstIndex(where: { $0.start == selectedBucket }) {
            return index
        }
        return buckets.count - 1
    }

    private var selectedValue: Int {
        chartValues.indices.contains(selectedIndex) ? chartValues[selectedIndex] : 0
    }

    private var selectedBucketData: InputStatisticsDay {
        guard buckets.indices.contains(selectedIndex) else {
            return InputStatisticsDay(key: anchorDay, typed: 0, voice: 0)
        }
        let bucket = buckets[selectedIndex]
        return snapshot.days.values.reduce(
            into: InputStatisticsDay(key: bucket.start, typed: 0, voice: 0)
        ) { result, day in
            guard day.key >= bucket.start && day.key <= bucket.end else { return }
            result = InputStatisticsDay(
                key: bucket.start,
                typed: result.typed + day.typed,
                voice: result.voice + day.voice
            )
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Yah")
                        .font(.system(.largeTitle, design: .default).weight(.bold))
                        .foregroundStyle(.primary)
                        .padding(.top, 8)

                    keyboardStatus

                    HStack {
                        Text("我的输入")
                            .font(.system(.subheadline, design: .default).weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            showLevel = true
                        } label: {
                            HStack(spacing: 5) {
                                Text("等级 \(InputStatisticsStore.level(for: snapshot.total))")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .font(.system(.subheadline, design: .default).weight(.semibold))
                            .foregroundStyle(InputDashboardPalette.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(InputDashboardPalette.accentBackground, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .accessibilityLabel("输入等级 \(InputStatisticsStore.level(for: snapshot.total))")
                    }
                    .padding(.top, -4)
                    .padding(.bottom, -14)

                    statisticsCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(InputDashboardPalette.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showLevel) {
                InputLevelView(snapshot: snapshot)
            }
            .sheet(isPresented: $showDatePicker) {
                datePicker
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .onAppear(perform: reload)
            .onChange(of: scenePhase) { phase in
                if phase == .active { reload() }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                reload()
            }
            .onChange(of: range) { _ in
                selectedBucket = nil
            }
        }
    }

    private var keyboardStatus: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(keyboardActivated ? Color.green.opacity(0.12) : InputDashboardPalette.accentBackground)
                        .frame(width: 40, height: 40)
                    Image(systemName: keyboardActivated ? "checkmark" : "keyboard")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(keyboardActivated ? Color.green : InputDashboardPalette.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(keyboardActivated ? "Yah 键盘已启用" : "尚未检测到 Yah 键盘")
                        .font(.system(.headline, design: .default).weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(keyboardActivated ? "可以开始记录你的输入" : "请先在系统键盘设置中启用")
                        .font(.system(.subheadline))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(InputDashboardPalette.separator)
                .frame(height: 1 / UIScreen.main.scale)

            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(InputDashboardPalette.accent)
                    .frame(width: 32, height: 32)
                    .background(InputDashboardPalette.accentBackground, in: RoundedRectangle(cornerRadius: 10))
                Text("输入设置")
                    .font(.system(.body))
                    .foregroundStyle(.primary)
                Spacer()
                Button(action: onOpenSettings) {
                    HStack(spacing: 6) {
                        Text("语音与方案")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(.subheadline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开语音和输入方案设置")
            }
        }
        .padding(18)
        .background(InputDashboardPalette.card, in: RoundedRectangle(cornerRadius: 24))
    }

    private var statisticsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("累计输入")
                        .font(.system(.caption))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(snapshot.total.formatted())
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text("字")
                            .font(.system(.subheadline))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("今日")
                        .font(.system(.caption))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(snapshot.day(for: InputStatisticsStore.dayKey()).total.formatted())
                            .font(.system(.title3, design: .default).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Text("字")
                            .font(.system(.footnote))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Picker("统计范围", selection: $range) {
                ForEach(InputDashboardRange.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(height: 32)
            .padding(.top, 18)
            .accessibilityLabel("日、周、月统计范围")

            HStack {
                Button {
                    showDatePicker = true
                } label: {
                    Label("选择日期", systemImage: "calendar")
                        .font(.system(.caption, design: .default).weight(.medium))
                        .foregroundStyle(InputDashboardPalette.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                if let loadError {
                    Text(loadError)
                        .font(.system(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                } else if !snapshot.sharedStorageAvailable {
                    Text("请开启键盘完全访问以同步统计")
                        .font(.system(.caption2))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.top, 9)

            barChart
                .padding(.top, 8)

            Rectangle()
                .fill(InputDashboardPalette.separator)
                .frame(height: 1 / UIScreen.main.scale)
                .padding(.top, 16)

            HStack(spacing: 8) {
                Text(bucketDescription)
                    .font(.system(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                metric(title: "手打", value: selectedBucketData.typed)
                metric(title: "语音", value: selectedBucketData.voice)
                metric(title: "合计", value: selectedValue)
            }
            .padding(.top, 13)

            Text(snapshot.sharedStorageAvailable
                 ? "本机仅保存每日字数"
                 : "共享不可用；键盘输入可能暂存于键盘本机。请开启完全访问后同步。本机仅保存每日字数。")
                .font(.system(.footnote))
                .foregroundStyle(.tertiary)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(InputDashboardPalette.card, in: RoundedRectangle(cornerRadius: 24))
    }

    private var barChart: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { index, bucket in
                    let value = chartValues.indices.contains(index) ? chartValues[index] : 0
                    Button {
                        selectedBucket = bucket.start
                    } label: {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            if value == 0 {
                                Rectangle()
                                    .fill(index == selectedIndex ? InputDashboardPalette.accent : InputDashboardPalette.mutedAccent)
                                    .frame(height: 1)
                            } else {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(index == selectedIndex ? InputDashboardPalette.accent : InputDashboardPalette.mutedAccent)
                                    .frame(height: max(2, 80 * CGFloat(value) / CGFloat(max(chartValues.max() ?? 0, 1))))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 80)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(bucketDescription(for: bucket))，语音 \(valueFor(bucket, voice: true)) 字，手打 \(valueFor(bucket, voice: false)) 字，合计 \(value) 字")
                }
            }
            HStack(spacing: 12) {
                ForEach(buckets) { bucket in
                    Text(bucket.label)
                        .font(.system(.caption))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }

    private var datePicker: some View {
        let today = InputStatisticsStore.dayKey()
        let first = min(snapshot.days.keys.min() ?? today, today)
        return NavigationStack {
            DatePicker(
                "日期",
                selection: Binding(
                    get: { InputStatisticsStore.date(forDayKey: min(anchorDay, today)) ?? Date() },
                    set: { date in
                        anchorDay = InputStatisticsStore.dayKey(for: date)
                        followsToday = anchorDay == today
                        selectedBucket = nil
                    }
                ),
                in: (InputStatisticsStore.date(forDayKey: first) ?? Date())...(InputStatisticsStore.date(forDayKey: today) ?? Date()),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding(.horizontal)
            .navigationTitle("选择日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showDatePicker = false }
                }
            }
        }
    }

    private var bucketDescription: String {
        guard buckets.indices.contains(selectedIndex) else { return "—" }
        return Self.description(for: buckets[selectedIndex], range: range)
    }

    private func metric(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(.caption))
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.system(.headline, design: .default).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(minWidth: 38, alignment: .leading)
    }

    private func reload() {
        let today = InputStatisticsStore.dayKey()
        if anchorDay > today || (followsToday && anchorDay != today) {
            anchorDay = today
            followsToday = true
            selectedBucket = nil
        }
        loadError = nil
        InputStatisticsStore.load { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let value):
                    snapshot = value
                    loadError = nil
                case .failure(let error):
                    loadError = "统计暂不可用：\(error.localizedDescription)"
                }
            }
        }
    }

    private func valueFor(_ bucket: InputDashboardBucket, voice: Bool) -> Int {
        snapshot.days.values.reduce(0) { value, day in
            guard day.key >= bucket.start && day.key <= bucket.end else { return value }
            return value + (voice ? day.voice : day.typed)
        }
    }

    private func bucketDescription(for bucket: InputDashboardBucket) -> String {
        Self.description(for: bucket, range: range)
    }

    private static func buckets(range: InputDashboardRange, anchorDay: Int) -> [InputDashboardBucket] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        guard let date = InputStatisticsStore.date(forDayKey: anchorDay) else { return [] }

        let starts: [Date]
        switch range {
        case .day:
            starts = (-6...0).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: date)) }
        case .week:
            let current = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
            starts = (-6...0).compactMap { calendar.date(byAdding: .weekOfYear, value: $0, to: current) }
        case .month:
            let current = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
            starts = (-6...0).compactMap { calendar.date(byAdding: .month, value: $0, to: current) }
        }

        return starts.map { start in
            let startKey = InputStatisticsStore.dayKey(for: start)
            let endDate: Date
            switch range {
            case .day: endDate = start
            case .week: endDate = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            case .month:
                let nextMonth = calendar.date(byAdding: .month, value: 1, to: start) ?? start
                endDate = calendar.date(byAdding: .day, value: -1, to: nextMonth) ?? start
            }
            let parts = calendar.dateComponents([.month, .day], from: start)
            let label = range == .day ? "\(parts.day ?? 0)" : range == .week
                ? "\(parts.month ?? 0).\(parts.day ?? 0)"
                : "\(parts.month ?? 0)月"
            return InputDashboardBucket(start: startKey, end: InputStatisticsStore.dayKey(for: endDate), label: label)
        }
    }

    private static func description(for bucket: InputDashboardBucket, range: InputDashboardRange) -> String {
        guard let start = InputStatisticsStore.date(forDayKey: bucket.start),
              let end = InputStatisticsStore.date(forDayKey: bucket.end) else { return "—" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "zh_CN")
        switch range {
        case .day:
            formatter.dateFormat = "yyyy年M月d日"
            return formatter.string(from: start)
        case .week:
            formatter.dateFormat = "yyyy.M.d"
            return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
        case .month:
            formatter.dateFormat = "yyyy年M月"
            return formatter.string(from: start)
        }
    }
}

struct InputLevelView: View {
    let snapshot: InputStatisticsSnapshot
    @State private var expandedRanges: Set<Int> = []

    private var level: Int { InputStatisticsStore.level(for: snapshot.total) }
    private var currentThreshold: Int { InputStatisticsStore.threshold(for: level) }
    private var nextThreshold: Int { InputStatisticsStore.threshold(for: level + 1) }
    private var progress: Double {
        guard nextThreshold > currentThreshold else { return 0 }
        return min(1, max(0, Double(snapshot.total - currentThreshold) / Double(nextThreshold - currentThreshold)))
    }
    private var maxLevel: Int { ((level - 1) / 10 + 2) * 10 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("等级 \(level)")
                        .font(.system(.largeTitle, design: .default).weight(.bold))
                        .foregroundStyle(.primary)

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(InputDashboardPalette.track)
                            Capsule().fill(InputDashboardPalette.accent)
                                .frame(width: geometry.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                    .accessibilityLabel("本级进度 \(progress.formatted(.percent.precision(.fractionLength(1))))")

                    HStack {
                        Text("本级进度")
                        Spacer()
                        Text(progress.formatted(.percent.precision(.fractionLength(1))))
                            .monospacedDigit()
                    }
                    .font(.system(.subheadline))
                    .foregroundStyle(.secondary)

                    Rectangle().fill(InputDashboardPalette.separator).frame(height: 1 / UIScreen.main.scale)

                    levelMetric("累计输入", value: snapshot.total)
                    Rectangle().fill(InputDashboardPalette.separator).frame(height: 1 / UIScreen.main.scale)
                    levelMetric("距下一级", value: max(0, nextThreshold - snapshot.total))
                }
                .padding(20)
                .background(InputDashboardPalette.card, in: RoundedRectangle(cornerRadius: 26))

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("输入构成")
                    VStack(spacing: 0) {
                        breakdownRow("累计手打", value: snapshot.typed)
                        Rectangle().fill(InputDashboardPalette.separator).frame(height: 1 / UIScreen.main.scale)
                        breakdownRow("累计语音", value: snapshot.voice)
                    }
                    .padding(.horizontal, 18)
                    .background(InputDashboardPalette.card, in: RoundedRectangle(cornerRadius: 24))
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("全部等级")
                    VStack(spacing: 0) {
                        ForEach(Array(stride(from: 1, through: maxLevel, by: 10)), id: \.self) { lower in
                            levelRangeRow(lower: lower, upper: lower + 9)
                            if expandedRanges.contains(lower) {
                                ForEach(lower...(lower + 9), id: \.self) { item in
                                    levelRow(item)
                                }
                            }
                            if lower + 9 < maxLevel {
                                Rectangle()
                                    .fill(InputDashboardPalette.separator)
                                    .frame(height: 1 / UIScreen.main.scale)
                                    .padding(.leading, 58)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(InputDashboardPalette.card, in: RoundedRectangle(cornerRadius: 24))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(InputDashboardPalette.background.ignoresSafeArea())
        .navigationTitle("输入等级")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            let currentRange = ((level - 1) / 10) * 10 + 1
            expandedRanges.insert(currentRange)
        }
    }

    private func levelMetric(_ title: String, value: Int) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            Text("\(value.formatted()) 字")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.system(.body))
        .frame(minHeight: 34)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.headline, design: .default).weight(.semibold))
            .foregroundStyle(.primary)
    }

    private func breakdownRow(_ title: String, value: Int) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            Text("\(value.formatted()) 字")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.system(.body))
        .frame(minHeight: 54)
    }

    private func levelRangeRow(lower: Int, upper: Int) -> some View {
        let reached = min(upper, level) - lower + 1
        let capped = max(0, reached)
        let completed = snapshot.total >= InputStatisticsStore.threshold(for: upper + 1)
        return Button {
            if expandedRanges.contains(lower) { expandedRanges.remove(lower) }
            else { expandedRanges.insert(lower) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(completed ? InputDashboardPalette.accent : InputDashboardPalette.track, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: completed ? 1 : CGFloat(capped) / 10)
                        .stroke(InputDashboardPalette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if completed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(InputDashboardPalette.accent)
                    }
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text("等级 \(lower)–\(upper)")
                        .font(.system(.body, design: .default).weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(InputStatisticsStore.threshold(for: lower).formatted())–\(InputStatisticsStore.threshold(for: upper + 1).formatted()) 字")
                        .font(.system(.footnote))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(completed ? "已完成" : "\(capped)/10")
                    .font(.system(.subheadline, design: .default).weight(.medium))
                    .foregroundStyle(completed ? .secondary : InputDashboardPalette.accent)
                Image(systemName: expandedRanges.contains(lower) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("等级 \(lower) 到 \(upper)，\(capped) 级已达成，\(expandedRanges.contains(lower) ? "收起" : "展开")")
    }

    private func levelRow(_ item: Int) -> some View {
        let isCurrent = item == level
        let reached = snapshot.total >= InputStatisticsStore.threshold(for: item)
        return HStack(spacing: 10) {
            Image(systemName: reached ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(reached ? InputDashboardPalette.accent : Color.secondary.opacity(0.45))
                .frame(width: 26)
            Text("等级 \(item)")
                .font(.system(.body, design: .default).weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? InputDashboardPalette.accent : .primary)
            if isCurrent {
                Text("当前")
                    .font(.system(.caption, design: .default).weight(.semibold))
                    .foregroundStyle(InputDashboardPalette.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(InputDashboardPalette.accentBackground, in: Capsule())
            }
            Spacer(minLength: 4)
            Text("累计 \(InputStatisticsStore.threshold(for: item).formatted()) 字")
                .font(.system(.footnote))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.leading, 36)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) {
            Rectangle().fill(InputDashboardPalette.separator).frame(height: 1 / UIScreen.main.scale).padding(.leading, 62)
        }
        .accessibilityElement(children: .combine)
    }
}
