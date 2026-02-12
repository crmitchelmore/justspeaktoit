import SpeakHotKeys
import SwiftUI

@main
struct SpeakHotKeysDemoApp: App {
  var body: some Scene {
    WindowGroup {
      DemoView()
        .frame(minWidth: 500, minHeight: 600)
    }
  }
}

struct DemoView: View {
  @StateObject private var engine = HotKeyEngine()
  @StateObject private var store = HotKeyStore(defaultsKey: "demo.selectedHotKey")
  @State private var eventLog: [LogEntry] = []
  @State private var holdThreshold: Double = 0.35
  @State private var doubleTapWindow: Double = 0.4

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(spacing: 20) {
          recorderSection
          statusSection
          timingSection
          eventLogSection
        }
        .padding()
      }
    }
    .onAppear { startEngine() }
    .onChange(of: store.hotKey) { restartEngine() }
    .onChange(of: holdThreshold) { updateTiming() }
    .onChange(of: doubleTapWindow) { updateTiming() }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Image(systemName: "keyboard")
        .font(.title2)
      Text("SpeakHotKeys Demo")
        .font(.title2.bold())
      Spacer()
      keyStateIndicator
    }
    .padding()
    .background(.bar)
  }

  private var keyStateIndicator: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(engine.isKeyDown ? Color.green : Color.gray.opacity(0.3))
        .frame(width: 12, height: 12)
      Text(engine.isKeyDown ? "Key Down" : "Key Up")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Recorder

  private var recorderSection: some View {
    GroupBox("Hotkey Configuration") {
      HotKeyRecorder("Recording Hotkey", hotKey: $store.hotKey)
        .padding(8)
    }
  }

  // MARK: - Status

  private var statusSection: some View {
    GroupBox("Status") {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Active Key:")
          Spacer()
          Text(engine.activeHotKey?.displayString ?? "None")
            .fontWeight(.medium)
        }
        HStack {
          Text("Monitoring:")
          Spacer()
          Image(systemName: engine.isMonitoring ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(engine.isMonitoring ? .green : .red)
        }
      }
      .padding(8)
    }
  }

  // MARK: - Timing

  private var timingSection: some View {
    GroupBox("Timing") {
      VStack(spacing: 12) {
        HStack {
          Text("Hold Threshold")
          Spacer()
          Text(holdThreshold, format: .number.precision(.fractionLength(2)))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        Slider(value: $holdThreshold, in: 0.1...1.5, step: 0.05)

        HStack {
          Text("Double Tap Window")
          Spacer()
          Text(doubleTapWindow, format: .number.precision(.fractionLength(2)))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        Slider(value: $doubleTapWindow, in: 0.1...1.0, step: 0.05)
      }
      .padding(8)
    }
  }

  // MARK: - Event Log

  private var eventLogSection: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("Event Log")
            .font(.headline)
          Spacer()
          Button("Clear") { eventLog.removeAll() }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)

        if eventLog.isEmpty {
          Text("Press your configured hotkey to see events here…")
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
        } else {
          ForEach(eventLog) { entry in
            HStack {
              Image(systemName: entry.gesture.iconName)
                .foregroundStyle(entry.gesture.color)
                .frame(width: 20)
              Text(entry.gesture.displayName)
                .fontWeight(.medium)
              Text("via \(entry.source)")
                .font(.caption)
                .foregroundStyle(.secondary)
              Spacer()
              Text(entry.time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            Divider()
          }
        }
      }
      .padding(8)
    }
  }

  // MARK: - Engine Management

  private func startEngine() {
    for gesture in HotKeyGesture.allCases {
      engine.register(gesture: gesture) { event in
        let entry = LogEntry(gesture: event.gesture, source: event.source)
        eventLog.insert(entry, at: 0)
        if eventLog.count > 50 { eventLog.removeLast() }
      }
    }
    engine.start(for: store.hotKey)
  }

  private func restartEngine() {
    engine.start(for: store.hotKey)
  }

  private func updateTiming() {
    engine.updateConfiguration(
      HotKeyConfiguration(holdThreshold: holdThreshold, doubleTapWindow: doubleTapWindow)
    )
  }
}

// MARK: - Log Entry

struct LogEntry: Identifiable {
  let id = UUID()
  let gesture: HotKeyGesture
  let source: String
  let time: String

  init(gesture: HotKeyGesture, source: String) {
    self.gesture = gesture
    self.source = source
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    self.time = formatter.string(from: Date())
  }
}

extension HotKeyGesture {
  var iconName: String {
    switch self {
    case .holdStart: return "hand.raised.fill"
    case .holdEnd: return "hand.raised"
    case .singleTap: return "hand.point.up"
    case .doubleTap: return "hand.point.up.fill"
    }
  }

  var color: Color {
    switch self {
    case .holdStart: return .orange
    case .holdEnd: return .blue
    case .singleTap: return .green
    case .doubleTap: return .purple
    }
  }
}
