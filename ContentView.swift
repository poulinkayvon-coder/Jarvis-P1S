import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: JarvisAppModel
    @State private var text = ""
    @State private var host = UserDefaults.standard.string(forKey: "p1s.host") ?? ""
    @State private var serial = UserDefaults.standard.string(forKey: "p1s.serial") ?? ""
    @State private var accessCode = Keychain.get("p1s.accessCode") ?? ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 14) {
                    header
                    statusCard
                    messageList
                    confirmationControls
                    controls
                }
                .padding()
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $app.showSetup) { setupSheet }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("JARVIS").font(.largeTitle.bold())
                Text("P1S • AMS").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                host = UserDefaults.standard.string(forKey: "p1s.host") ?? ""
                serial = UserDefaults.standard.string(forKey: "p1s.serial") ?? ""
                accessCode = Keychain.get("p1s.accessCode") ?? ""
                app.showSetup = true
            } label: {
                Image(systemName: "gearshape.fill").foregroundStyle(.white)
            }
            Circle().fill(app.configured ? .green : .orange).frame(width: 10, height: 10)
        }
        .foregroundStyle(.white)
    }

    private var statusCard: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(app.configured ? app.status.state.rawValue.capitalized : "Not configured")
                    .font(.headline)
                if app.configured {
                    Text("\(Int(app.status.progress))% • \(app.status.jobName ?? "No active job")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap ⚙ to connect your P1S")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Status") { app.handle("status") }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(app.isBusy)
        }
        .padding()
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.white)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(app.messages.enumerated()), id: \.offset) { index, message in
                        HStack {
                            if message.1 { Spacer() }
                            Text(message.0)
                                .padding(12)
                                .background(message.1 ? .white.opacity(0.14) : .blue.opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .foregroundStyle(.white)
                            if !message.1 { Spacer() }
                        }
                        .id(index)
                    }
                }
            }
            .onChange(of: app.messages.count) { _, count in
                if count > 0 {
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private var confirmationControls: some View {
        if let name = app.pendingPrintName {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ready to print")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)

                HStack {
                    Button("Cancel") { app.cancelPendingPrint() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    Button("Confirm Print") {
                        Task { await app.confirmPendingPrint() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(app.isBusy)
                }
            }
            .padding()
            .background(.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Search online • confirm before printing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        if app.speech.isListening {
                            let spoken = app.speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                            app.speech.stop()
                            if !spoken.isEmpty {
                                app.speech.transcript = ""
                                app.handle(spoken)
                            }
                        } else {
                            app.speech.transcript = ""
                            try? await app.speech.start()
                        }
                    }
                } label: {
                    Image(systemName: app.speech.isListening ? "mic.fill" : "mic")
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 36)
                }
                .buttonStyle(.borderedProminent)
            }

            HStack {
                TextField("Tell Jarvis what to print…", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendText() }
                Button("Send") { sendText() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func sendText() {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        text = ""
        app.handle(command)
    }

    private var setupSheet: some View {
        NavigationStack {
            Form {
                Section("P1S connection") {
                    TextField("Printer IP address", text: $host)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Printer serial number", text: $serial)
                        .textInputAutocapitalization(.never)
                    SecureField("LAN access code", text: $accessCode)
                }

                Section {
                    Text("Jarvis talks directly to the P1S over your local network. The access code is stored in the iPhone Keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("P1S Setup")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        app.configure(host: host, serial: serial, accessCode: accessCode)
                        app.showSetup = false
                    }
                    .disabled(host.isEmpty || serial.isEmpty || accessCode.isEmpty)
                }
            }
        }
    }
}
