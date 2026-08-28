import CyclopMeetings
import SwiftUI

/// Recording controls above the list of past meetings.
struct MeetingsPane: View {
    @ObservedObject var meetings: MeetingsController

    var body: some View {
        VStack(spacing: 6) {
            control
            ScrollView(showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(meetings.meetings) { meeting in
                        row(meeting)
                    }
                }
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { meetings.refresh() }
    }

    @ViewBuilder
    private var control: some View {
        switch meetings.state {
        case .idle:
            button(title: localized("Record meeting"), symbol: "record.circle", tint: .red) {
                meetings.toggleRecording()
            }
        case .recording(let since):
            button(title: localized("Stop"), symbol: "stop.circle", tint: .red) {
                meetings.toggleRecording()
            }
            .overlay(alignment: .trailing) {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.clock(context.date.timeIntervalSince(since)))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                        .padding(.trailing, 10)
                }
            }
        case .processing(let step):
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("\(localized("Processing")) — \(step)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .frame(height: 30)
        }
    }

    private func button(
        title: String, symbol: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ meeting: MeetingsController.Meeting) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(for: meeting.state))
                .font(.system(size: 11))
                .foregroundStyle(meeting.state == .failed ? Color.orange : Theme.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.dateFormatter.string(from: meeting.folder.startedAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                Text(detail(for: meeting))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if meeting.state == .failed {
                Button(action: { meetings.retry(meeting) }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help(localized("Try again"))
            }
            Button(action: { meetings.reveal(meeting) }) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help(localized("Show in Finder"))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
        .contentShape(Rectangle())
        .onTapGesture {
            if meeting.state == .ready { meetings.openTranscript(meeting) }
        }
    }

    private func symbol(for state: MeetingState) -> String {
        switch state {
        case .recording: return "record.circle"
        case .processing: return "clock"
        case .ready: return "doc.text"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func detail(for meeting: MeetingsController.Meeting) -> String {
        if let failure = meeting.failure { return failure }
        switch meeting.state {
        case .ready: return Self.clock(meeting.duration)
        case .processing: return localized("Processing")
        case .recording: return localized("Recording")
        case .failed: return localized("Did not work out")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.dateFormat = "d MMMM, HH:mm"
        return formatter
    }()

    private static func clock(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
