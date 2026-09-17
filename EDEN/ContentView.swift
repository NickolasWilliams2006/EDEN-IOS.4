import SwiftUI
import CoreBluetooth

private let bg = Color(red: 0.031, green: 0.035, blue: 0.043)     // #08090b
private let accent = Color(red: 0.302, green: 0.714, blue: 1.0)   // #4db6ff
private let dim = Color.white.opacity(0.45)
private let line = Color.white.opacity(0.09)

struct ContentView: View {
    @StateObject private var bt = BluetoothManager()
    @StateObject private var eden = EdenClient()
    @State private var tab = 0

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Picker("", selection: $tab) {
                    Text("Talk").tag(0)
                    Text("Bluetooth").tag(1)
                    Text("Setup").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                switch tab {
                case 0: TalkView(eden: eden)
                case 1: BluetoothView(bt: bt, eden: eden)
                default: SetupView(eden: eden, bt: bt)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(accent)
        // The web page, opened once in Safari on this phone, offers an
        // eden://… link: the same pairing link with the scheme swapped, so
        // nobody types a token and a fingerprint by hand.
        .onOpenURL { url in
            eden.saveHost(url.absoluteString)
            tab = 2
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(accent).frame(width: 6, height: 6)
            Text("EDEN").font(.system(size: 12, design: .monospaced)).kerning(3)
            Spacer()
            if let note = eden.connectionNote {
                Text(note).font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.8)).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

// MARK: - Talk

struct TalkView: View {
    @ObservedObject var eden: EdenClient
    @State private var draft = ""
    @State private var recording = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(eden.turns) { turn in
                            turnRow(turn).id(turn.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: eden.turns.count) { _, _ in
                    if let last = eden.turns.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("Ask", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Capsule().stroke(line))
                    .onSubmit(send)

                Button {
                    recording ? stopRecording() : startRecording()
                } label: {
                    Image(systemName: recording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(recording ? .red : accent)
                }
                .disabled(eden.busy)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func turnRow(_ turn: EdenClient.Turn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !turn.tools.isEmpty {
                HStack(spacing: 4) {
                    ForEach(turn.tools, id: \.self) { t in
                        Text(t.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 8, design: .monospaced)).kerning(1)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(accent.opacity(0.12)))
                            .foregroundStyle(accent)
                    }
                }
            }
            Text(turn.text)
                .font(.system(size: turn.mine ? 13 : 15, design: .monospaced))
                .foregroundStyle(turn.mine ? dim : .white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await eden.ask(text) }
    }

    private func startRecording() {
        do { try eden.startRecording(); recording = true }
        catch { eden.connectionNote = "Mic unavailable: \(error.localizedDescription)" }
    }

    private func stopRecording() {
        recording = false
        Task { await eden.stopRecordingAndSend() }
    }
}

// MARK: - Bluetooth

struct BluetoothView: View {
    @ObservedObject var bt: BluetoothManager
    @ObservedObject var eden: EdenClient
    @State private var writeTarget: BluetoothManager.Characteristic?
    @State private var writeHex = ""
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let reason = bt.unavailableReason {
                Text(reason)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(16)
            }

            HStack {
                Button(bt.scanning ? "Stop" : "Scan") {
                    bt.scanning ? bt.stopScan() : bt.startScan()
                }
                .buttonStyle(.bordered)
                if bt.connected != nil {
                    Button("Disconnect") { bt.disconnect() }.buttonStyle(.bordered)
                }
                Spacer()
                Text(bt.status)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(dim)
            }
            .padding(.horizontal, 16)

            List {
                if bt.connected == nil {
                    Section("Nearby") {
                        ForEach(bt.devices) { d in
                            Button { bt.connect(d) } label: {
                                HStack {
                                    Text(d.name).foregroundStyle(.white)
                                    Spacer()
                                    Text("\(d.rssi) dBm").foregroundStyle(dim)
                                }
                                .font(.system(size: 13, design: .monospaced))
                            }
                        }
                    }
                } else {
                    Section(bt.connected?.name ?? "") {
                        ForEach(bt.characteristics) { c in
                            characteristicRow(c)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .alert("Write to device?", isPresented: $confirming) {
            TextField("hex, e.g. 01ff", text: $writeHex)
            Button("Cancel", role: .cancel) {}
            Button("Write", role: .destructive) {
                if let t = writeTarget { bt.write(t, hex: writeHex) }
            }
        } message: {
            Text("This changes something on the device. It cannot be undone from here.")
        }
    }

    @ViewBuilder
    private func characteristicRow(_ c: BluetoothManager.Characteristic) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(c.uuid.uuidString)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
            if let v = c.value {
                Text(v).font(.system(size: 11, design: .monospaced)).foregroundStyle(accent)
            }
            HStack(spacing: 8) {
                if c.readable {
                    Button("Read") { bt.read(c) }.buttonStyle(.bordered).controlSize(.mini)
                }
                if c.notifying {
                    Button("Notify") { bt.setNotify(c, on: true) }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
                if c.writable {
                    // Writes need an explicit confirmation, same rule the
                    // Python side enforces for anything with a real effect.
                    Button("Write") { writeTarget = c; writeHex = ""; confirming = true }
                        .buttonStyle(.bordered).controlSize(.mini).tint(.orange)
                }
                if c.value != nil {
                    Button("Ask EDEN") {
                        Task {
                            await eden.reportReading(
                                device: bt.connected?.name ?? "device",
                                characteristic: c.uuid.uuidString,
                                value: c.value ?? "")
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                }
            }
        }
        .padding(.vertical, 3)
        .listRowBackground(Color.clear)
    }
}

// MARK: - Setup

struct SetupView: View {
    @ObservedObject var eden: EdenClient
    @ObservedObject var bt: BluetoothManager
    @State private var draft = ""
    @State private var reveal = false

    var body: some View {
        Form {
            Section("EDEN server") {
                HStack {
                    Group {
                        if reveal {
                            TextField("HTTPS pairing link from EDEN", text: $draft)
                        } else {
                            SecureField("HTTPS pairing link from EDEN", text: $draft)
                        }
                    }
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    Button(reveal ? "Hide" : "Show") { reveal.toggle() }
                        .buttonStyle(.borderless).controlSize(.mini)
                }
                Button("Pair") { eden.saveHost(draft); if eden.pairingNote == nil { draft = "" } }
                if let why = eden.pairingNote {
                    Text(why).font(.system(size: 12, design: .monospaced)).foregroundStyle(.red)
                }
                Text(eden.readiness)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(eden.readiness.hasPrefix("Ready") ? accent : .red)
                Text(eden.host.isEmpty ? "no server saved" : eden.host)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(dim)
                row("Certificate", eden.pinned ? "Pinned from pairing link" : "Not pinned")
            }
            Section("Status") {
                row("Bluetooth", bt.unavailableReason ?? "Ready")
                row("Devices seen", "\(bt.devices.count)")
            }
            Section {
                Text("Easiest: open EDEN's web page in Safari on this phone and tap "
                     + "\"Pair it with one tap\". Or run `EDEN.bat --lan` and paste the "
                     + "full link it prints here, including ?t= and f=. The f= part pins "
                     + "EDEN's certificate so nothing needs installing on the phone. If "
                     + "EDEN regenerates its certificate (new Wi-Fi address), re-pair.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(dim)
            }
        }
        .scrollContentBackground(.hidden)
        .onAppear { draft = eden.host }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(dim)
            Spacer()
            Text(v).foregroundStyle(.white)
        }
        .font(.system(size: 12, design: .monospaced))
    }
}
