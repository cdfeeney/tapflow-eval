import SwiftUI

// Independent oracle: every real interaction lands here, so a flow's "pass" can be checked against
// what the app itself saw.
func logEvent(_ event: String) {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = dir.appendingPathComponent("events.log")
    let line = Data("\(Date().timeIntervalSince1970) \(event)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line)
        try? handle.close()
    } else {
        try? line.write(to: url)
    }
}

@main struct ProbeApp: App {
    init() { logEvent("launch") }
    var body: some Scene { WindowGroup { RootView() } }
}

struct RootView: View {
    @State private var saves = 0
    @State private var isOn = false
    @State private var weight = ""
    @State private var loaded = false
    @State private var isSheetOpen = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Form buttons") {
                    // The exact shape AXe taps lied about on ConorHealth.
                    Button("Form Save") { saves += 1; logEvent("form-save") }
                        .accessibilityIdentifier("form-save")
                    Text("saves: \(saves)")
                    Toggle("Reminders", isOn: $isOn)
                        .accessibilityIdentifier("reminders")
                        .onChange(of: isOn) { _, value in logEvent("toggle \(value)") }
                    Text(isOn ? "reminders on" : "reminders off")
                }
                Section("Typing") {
                    TextField("Set 1 weight", text: $weight)
                        .accessibilityIdentifier("weight")
                    Text("typed: \(weight)")
                }
                Section("Timing and navigation") {
                    Button("Load slow") {
                        logEvent("load-start")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { loaded = true }
                    }
                    .accessibilityIdentifier("load")
                    if loaded { Text("Loaded") }
                    Button("Open sheet") { isSheetOpen = true; logEvent("sheet-open") }
                        .accessibilityIdentifier("open-sheet")
                    NavigationLink("Long list") { LongList() }
                        .accessibilityIdentifier("long-list")
                }
            }
            .navigationTitle("Probe")
            .sheet(isPresented: $isSheetOpen) {
                VStack(spacing: 24) {
                    Text("Sheet body")
                    Button("Close sheet") { isSheetOpen = false; logEvent("sheet-close") }
                        .accessibilityIdentifier("close-sheet")
                }
            }
        }
    }
}

// A bottom bar over a list: the shape behind the tour's mistap on the Finish bar.
struct LongList: View {
    @State private var finished = 0

    var body: some View {
        List(1...200, id: \.self) { row in
            NavigationLink("Row \(row)") {
                Text("Detail \(row)").onAppear { logEvent("detail \(row)") }
            }
            .accessibilityIdentifier("row-\(row)")
        }
        .safeAreaInset(edge: .bottom) {
            Button("Finish") { finished += 1; logEvent("finish-MISTAP") }
                .accessibilityIdentifier("finish")
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(.thinMaterial)
        }
        .navigationTitle("Long list")
    }
}
