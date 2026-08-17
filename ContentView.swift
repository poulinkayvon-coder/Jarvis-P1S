import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: JarvisAppModel

    @State private var text = ""
    @State private var host = UserDefaults.standard.string(forKey: "p1s.host") ?? ""
    @State private var serial = UserDefaults.standard.string(forKey: "p1s.serial") ?? ""
    @State private var accessCode = Keychain.get("p1s.accessCode") ?? ""
    @State private var bambuAccount = UserDefaults.standard.string(forKey: "bambu.account") ?? ""
    @State private var bambuPassword = ""
    @State private var bambuVerificationCode = ""
    @State private var pulse = false
    @State private var rotation = 0.0

    private let cyan = Color(red: 0.32, green: 0.92, blue: 1.0)
    private let deepCyan = Color(red: 0.02, green: 0.42, blue: 0.55)

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    hudHeader
                        .frame(height: 320)

                    Rectangle()
                        .fill(cyan.opacity(0.35))
                        .frame(height: 1)
                        .shadow(color: cyan, radius: 5)

                    conversationPanel
                    confirmationControls
                    commandBar
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $app.showSetup) { setupSheet }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            pulse = true
            rotation = 360
            app.startVoiceLinkIfNeeded()
        }
    }

    private var hudHeader: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [Color.black, Color(red: 0.01, green: 0.05, blue: 0.07), Color.black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                circuitLines(size: geo.size)

                VStack {
                    HStack(alignment: .top) {
                        brandBlock
                        Spacer()
                        systemStatusPanel
                    }
                    Spacer()
                    bottomTelemetry
                }
                .padding(18)

                coreOrb
                    .position(x: geo.size.width * 0.52, y: geo.size.height * 0.49)

                Button {
                    loadSetupValues()
                    app.showSetup = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(cyan)
                        .padding(10)
                        .background(Color.black.opacity(0.72))
                        .overlay(Circle().stroke(cyan.opacity(0.5), lineWidth: 1))
                }
                .position(x: geo.size.width - 29, y: geo.size.height - 28)
            }
            .clipped()
        }
    }

    private var brandBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PERSONAL AI SYSTEM")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.65))

            Text("JARVIS")
                .font(.system(size: 34, weight: .light, design: .rounded))
                .tracking(7)
                .foregroundStyle(cyan)
                .shadow(color: cyan.opacity(0.7), radius: 8)

            Rectangle()
                .fill(cyan)
                .frame(width: 132, height: 1)
                .shadow(color: cyan, radius: 4)

            Text("VOICE ASSISTANT")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(2.2)
                .foregroundStyle(.white.opacity(0.55))

            HStack(spacing: 6) {
                Circle()
                    .fill(app.speech.isListening ? cyan : Color.orange)
                    .frame(width: 5, height: 5)
                    .shadow(color: app.speech.isListening ? cyan : .orange, radius: 4)
                Text(app.speech.statusText)
                    .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(app.speech.isListening ? cyan.opacity(0.9) : .orange)
                    .lineLimit(2)
                    .frame(width: 135, alignment: .leading)
            }
            .padding(.top, 5)
        }
    }

    private var systemStatusPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("SYSTEM STATUS")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(cyan)
                Spacer()
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
            }

            hudStatusRow("POWER CORE", "100%")
            hudStatusRow("AI CORE", app.brainStatus)
            hudStatusRow("MEMORY", "\(app.memoryCount) ITEMS")
            hudStatusRow("P1S LINK", app.configured ? "READY" : "SETUP")
            hudStatusRow("VOICE", app.speech.isSpeaking ? "SPEAKING" : (app.speech.isListening ? "ACTIVE" : "OFFLINE"))
        }
        .padding(9)
        .frame(width: 134)
        .background(Color.black.opacity(0.55))
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(cyan.opacity(0.35), lineWidth: 0.8)
        )
    }

    private func hudStatusRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 5.7, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text(value)
                .font(.system(size: 5.7, weight: .semibold, design: .monospaced))
                .foregroundStyle(cyan.opacity(0.9))
                .lineLimit(1)
        }
    }

    private var coreOrb: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { index in
                Circle()
                    .trim(from: Double(index) * 0.11, to: min(Double(index) * 0.11 + 0.46, 1))
                    .stroke(cyan.opacity(0.22 + Double(index) * 0.07), lineWidth: index == 0 ? 1.3 : 0.7)
                    .frame(width: 168 - CGFloat(index * 22), height: 168 - CGFloat(index * 22))
                    .rotationEffect(.degrees(rotation * (index.isMultiple(of: 2) ? 1 : -1) + Double(index * 23)))
            }

            Circle()
                .stroke(cyan.opacity(0.3), lineWidth: 1)
                .frame(width: 76, height: 76)
                .scaleEffect(pulse ? 1.13 : 0.94)
                .opacity(pulse ? 0.18 : 0.6)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white, cyan, deepCyan, .black],
                        center: .center,
                        startRadius: 1,
                        endRadius: 38
                    )
                )
                .frame(width: 57, height: 57)
                .shadow(color: cyan, radius: app.speech.isAwake || app.speech.isSpeaking ? 26 : 14)

            Circle()
                .fill(Color.white.opacity(0.96))
                .frame(width: 14, height: 14)
                .blur(radius: 1.3)
        }
        .animation(.linear(duration: 18).repeatForever(autoreverses: false), value: rotation)
        .animation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true), value: pulse)
        .accessibilityLabel("Jarvis voice core")
    }

    private var bottomTelemetry: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("P1S")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(cyan)
                Text("\(Int(app.status.progress))%  •  \(app.status.jobName ?? "NO ACTIVE JOB")")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer()

            waveform
                .frame(width: 105, height: 26)

            Spacer()

            HStack(spacing: 5) {
                Text(app.speech.isAwake ? "AWAKE" : "MONITORING")
                    .font(.system(size: 6.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(cyan)
                Image(systemName: "waveform")
                    .font(.system(size: 9))
                    .foregroundStyle(cyan.opacity(0.8))
            }
        }
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<23, id: \.self) { i in
                Capsule()
                    .fill(cyan.opacity(app.speech.isListening ? 0.9 : 0.3))
                    .frame(width: 2, height: CGFloat(4 + ((i * 7) % 18)))
                    .scaleEffect(y: app.speech.isAwake && pulse ? 1.45 : (app.speech.isListening ? 0.9 : 0.55))
            }
        }
        .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: pulse)
    }

    private func circuitLines(size: CGSize) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 12, y: 44))
            path.addLine(to: CGPoint(x: 12, y: size.height - 44))
            path.move(to: CGPoint(x: size.width - 12, y: 44))
            path.addLine(to: CGPoint(x: size.width - 12, y: size.height - 44))

            path.move(to: CGPoint(x: 22, y: size.height - 58))
            path.addLine(to: CGPoint(x: 86, y: size.height - 58))
            path.addLine(to: CGPoint(x: 101, y: size.height - 37))
            path.addLine(to: CGPoint(x: size.width * 0.42, y: size.height - 37))

            path.move(to: CGPoint(x: size.width * 0.62, y: size.height - 37))
            path.addLine(to: CGPoint(x: size.width - 104, y: size.height - 37))
            path.addLine(to: CGPoint(x: size.width - 86, y: size.height - 58))
            path.addLine(to: CGPoint(x: size.width - 22, y: size.height - 58))
        }
        .stroke(cyan.opacity(0.27), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
    }

    private var conversationPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(app.messages.enumerated()), id: \.offset) { index, message in
                        HStack {
                            if message.1 { Spacer(minLength: 35) }

                            Text(message.0)
                                .font(.system(size: 14, design: .rounded))
                                .foregroundStyle(message.1 ? .white : cyan.opacity(0.95))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 10)
                                .background(message.1 ? Color.white.opacity(0.08) : deepCyan.opacity(0.15))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(message.1 ? Color.white.opacity(0.12) : cyan.opacity(0.22), lineWidth: 0.7)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))

                            if !message.1 { Spacer(minLength: 35) }
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: app.messages.count) { _, count in
                if count > 0 {
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .background(Color.black)
    }

    @ViewBuilder
    private var confirmationControls: some View {
        if let name = app.pendingPrintName {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text("PRINT AUTHORIZATION REQUIRED")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(cyan)

                Text(name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)

                HStack {
                    Button("CANCEL") { app.cancelPendingPrint() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    Spacer()
                    Button("CONFIRM PRINT") {
                        Task { await app.confirmPendingPrint() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(cyan)
                    .foregroundStyle(.black)
                    .disabled(app.isBusy)
                }
            }
            .padding(12)
            .background(Color(red: 0.01, green: 0.08, blue: 0.10))
            .overlay(Rectangle().stroke(cyan.opacity(0.45), lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var commandBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(app.speech.isListening ? cyan : Color.orange)
                    .frame(width: 6, height: 6)
                Text(app.speech.isListening ? "ALWAYS LISTENING • SAY “HEY JARVIS”" : "VOICE LINK OFFLINE")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(app.speech.isListening ? cyan.opacity(0.8) : .orange)
                Spacer()

                if !app.speech.isListening && !app.speech.isSpeaking {
                    Button("RECONNECT") { app.startVoiceLinkIfNeeded() }
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(cyan)
                }
            }
            .padding(.horizontal, 14)

            if app.speech.isAwake && !app.speech.transcript.isEmpty {
                Text(app.speech.transcript)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(cyan.opacity(0.75))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 15)
            }

            HStack(spacing: 9) {
                TextField("Optional: type to Jarvis…", text: $text)
                    .textInputAutocapitalization(.sentences)
                    .foregroundStyle(.white)
                    .tint(cyan)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(cyan.opacity(0.25), lineWidth: 0.8))
                    .onSubmit { sendText() }

                Button { sendText() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(cyan)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(Color.black)
    }

    private func sendText() {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        text = ""
        app.handle(command)
    }

    private func loadSetupValues() {
        host = UserDefaults.standard.string(forKey: "p1s.host") ?? ""
        serial = UserDefaults.standard.string(forKey: "p1s.serial") ?? ""
        accessCode = Keychain.get("p1s.accessCode") ?? ""
        bambuAccount = UserDefaults.standard.string(forKey: "bambu.account") ?? ""
        bambuPassword = ""
        bambuVerificationCode = ""
    }

    private var setupSheet: some View {
        NavigationStack {
            Form {
                Section("Jarvis voice link") {
                    HStack {
                        Text("Wake phrase")
                        Spacer()
                        Text("Hey Jarvis")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(app.speech.isListening ? "Active" : "Offline")
                            .foregroundStyle(app.speech.isListening ? .green : .orange)
                    }
                    Text("Jarvis listens for the wake phrase while the app is running. The text box on the main screen is only a backup.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("P1S local connection") {
                    TextField("Printer IP address", text: $host)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Printer serial number", text: $serial)
                        .textInputAutocapitalization(.never)
                    SecureField("LAN access code", text: $accessCode)
                    Button("Save & Test P1S") {
                        app.configure(host: host, serial: serial, accessCode: accessCode)
                    }
                    .disabled(host.isEmpty || serial.isEmpty || accessCode.isEmpty || app.isBusy)
                }

                Section("MakerWorld") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(app.makerWorldSignedIn ? "Connected" : "Not connected")
                            .foregroundStyle(app.makerWorldSignedIn ? .green : .secondary)
                    }
                    TextField("Bambu / MakerWorld email", text: $bambuAccount)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                    SecureField("Password", text: $bambuPassword)
                    TextField("Verification code (only if Bambu sends one)", text: $bambuVerificationCode)
                        .keyboardType(.numberPad)

                    Button(app.makerWorldSignedIn ? "Sign In Again" : "Sign In to MakerWorld") {
                        Task {
                            await app.signInMakerWorld(
                                account: bambuAccount,
                                password: bambuPassword,
                                verificationCode: bambuVerificationCode
                            )
                            if app.makerWorldSignedIn {
                                bambuPassword = ""
                                bambuVerificationCode = ""
                            }
                        }
                    }
                    .disabled(bambuAccount.isEmpty || (bambuPassword.isEmpty && bambuVerificationCode.isEmpty) || app.isBusy)
                }

                Section("Intelligence") {
                    HStack {
                        Text("AI core")
                        Spacer()
                        Text(app.brainStatus)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Saved memories")
                        Spacer()
                        Text("\(app.memoryCount)")
                            .foregroundStyle(.secondary)
                    }
                    Text("On supported iPhones, Jarvis uses Apple's on-device Foundation Models when available, so normal conversation can stay on the phone without a paid AI API.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("Jarvis talks to the P1S over your local network. A MakerWorld profile is never sent to the printer until you explicitly confirm it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Jarvis Setup")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { app.showSetup = false }
                }
            }
        }
    }
}
