import ActivityKit
import SwiftUI
import WidgetKit

@main
struct YahLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        VoiceLiveActivityWidget()
    }
}

struct VoiceLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceStandbyAttributes.self) { context in
            HStack {
                microphone
                status(context.state)
                Spacer()
                actions(context)
            }
            .padding()
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { microphone }
                DynamicIslandExpandedRegion(.trailing) { status(context.state) }
                DynamicIslandExpandedRegion(.bottom) { actions(context) }
            } compactLeading: {
                microphone
            } compactTrailing: {
                timer(context.state)
            } minimal: {
                minimalActivity(context.state)
            }
        }
    }

    private var microphone: some View {
        Image(systemName: "mic.circle.fill")
            .foregroundStyle(.orange)
            .accessibilityLabel("Yah 语音")
    }

    private func minimalActivity(_ state: VoiceStandbyAttributes.ContentState) -> some View {
        ZStack {
            Circle().fill(.orange)
            Image(systemName: state.phase == .listening ? "waveform" : "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel("Yah 语音")
    }

    @ViewBuilder
    private func status(_ state: VoiceStandbyAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(state.phase.title)
                .font(.headline)
            timer(state)
                .font(.caption.monospacedDigit())
        }
    }

    @ViewBuilder
    private func timer(_ state: VoiceStandbyAttributes.ContentState) -> some View {
        if state.phase != .standby, let started = state.started {
            Text(started, style: .timer)
        } else {
            Text(timerInterval: min(Date(), state.expires)...state.expires, countsDown: true)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func actions(_ context: ActivityViewContext<VoiceStandbyAttributes>) -> some View {
        if #available(iOS 17.0, *) {
            HStack {
                if context.state.phase == .listening, let recording = context.state.recordingID {
                    Button(intent: StopVoiceDictationIntent(recordingID: recording)) {
                        Label("停止录音", systemImage: "stop.circle")
                    }
                }
                Button(intent: EndVoiceStandbyIntent(sessionID: context.attributes.sessionID)) {
                    Label("结束待机", systemImage: "power")
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

private extension VoiceStandbyAttributes.ContentState.Phase {
    var title: String {
        switch self {
        case .standby: "语音待机"
        case .listening: "正在录音"
        case .transcribing: "正在转写"
        }
    }
}
