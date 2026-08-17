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
    @State private var spinA = 0.0
    @State private var spinB = 0.0
    @State private var pulse = false

    private let cyan = Color(red: 0.22, green: 0.88, blue: 1.0)
    private let amber = Color(red: 1.0, green: 0.52, blue: 0.12)
    private let panelFill = Color(red: 0.01, green: 0.07, blue: 0.09)

    var body: some View {
        GeometryReader { geo in
            NavigationStack {
                ZStack {
                    LinearGradient(
                        colors: [Color.black, Color(red: 0.005, green: 0.03, blue: 0.045), Color.black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()

                    VStack(spacing: 0) {
                        jarvisStage(width: geo.size.width)
                            .frame(height: min(440, max(380, geo.size.height * 0.53)))

                        conversationPanel
                            .frame(maxHeight: .infinity)

                        confirmationControls
                        commandBar
                    }
                    .padding(.top, 4)
                }
                .navigationBarHidden(true)
                .sheet(isPresented: $app.showSetup) { setupSheet }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.linear(duration: 22).repeatForever(autoreverses: false)) { spinA = 360 }
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { spinB = -360 }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
            app.startVoiceLinkIfNeeded()
        }
    }

    private func jarvisStage(width: CGFloat) -> some View {
        GeometryReader { geo in
            let compact = width < 400
            ZStack {
                hudGrid(size: geo.size).opacity(0.5)

                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        topIdentity
                        Spacer(minLength: 10)
                        voiceIndicator
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                    Spacer()
                }

                reactorCore
                    .scaleEffect(compact ? 0.90 : 1.0)
                    .position(x: geo.size.width * 0.5, y: geo.size.height * 0.51)

                HStack(alignment: .bottom, spacing: 0) {
                    leftContextPanel
                    Spacer(minLength: compact ? 84 : 110)
                    rightContextPanel
                }
                .padding(.horizontal, 18)
                .position(x: geo.size.width * 0.5, y: geo.size.height * 0.66)

                lowerTelemetry
                    .position(x: geo.size.width * 0.5, y: geo.size.height - 34)

                Button {
                    loadSetupValues()
                    app.showSetup = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(cyan)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.7))
                        .overlay(Circle().stroke(cyan.opacity(0.5), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .position(x: geo.size.width - 30, y: geo.size.height - 30)
            }
            .clipped()
        }
    }

    private var topIdentity: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("J.A.R.V.I.S.")
                .font(.system(size: 20, weight: .light, design: .monospaced))
                .tracking(2.4)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(cyan)
                .shadow(color: cyan.opacity(0.55), radius: 6)

            HStack(spacing: 5) {
                Rectangle().fill(cyan.opacity(0.8)).frame(width: 34, height: 1)
                Text("PERSONAL AI CORE")
                    .font(.system(size: 6.2, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 180, alignment: .leading)
    }

    private var voiceIndicator: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 5) {
                Text(app.speech.isAwake ? "CONVERSATION" : "VOICE LINK")
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(app.speech.isAwake ? amber : cyan)
                    .lineLimit(1)

                Circle()
                    .fill(voiceDotColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: voiceDotColor, radius: 4)
            }

            Text(voiceDisplayStatus)
                .font(.system(size: 6.0, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .frame(width: 138, alignment: .trailing)
        }
    }

    private var voiceDotColor: Color {
        if app.speech.isSpeaking { return amber }
        if app.speech.isListening { return app.speech.isAwake ? amber : cyan }
        return .red
    }

    private var voiceDisplayStatus: String {
        if app.speech.isSpeaking { return app.speech.statusText }
        if app.speech.isListening { return app.speech.statusText }
        if app.speech.statusText.contains("PREPARING") || app.speech.statusText.contains("DOWNLOADING") || app.speech.statusText.contains("LOADING") {
            return app.speech.statusText
        }
        return "VOICE LINK OFFLINE"
    }

    private var reactorCore: some View {
        ZStack {
            ForEach(0..<36, id: \.self) { index in
                Capsule()
                    .fill(index.isMultiple(of: 6) ? amber.opacity(0.75) : cyan.opacity(0.42))
                    .frame(width: index.isMultiple(of: 6) ? 1.6 : 0.8, height: index.isMultiple(of: 6) ? 9 : 5)
                    .offset(y: -111)
                    .rotationEffect(.degrees(Double(index) * 10 + spinA * 0.18))
            }

            Circle().trim(from: 0.03, to: 0.79)
                .stroke(cyan.opacity(0.26), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                .frame(width: 202, height: 202)
                .rotationEffect(.degrees(spinB))

            Circle().trim(from: 0.10, to: 0.52)
                .stroke(amber.opacity(0.68), lineWidth: 1.3)
                .frame(width: 182, height: 182)
                .rotationEffect(.degrees(spinA))

            Circle().trim(from: 0.00, to: 0.31)
                .stroke(cyan.opacity(0.9), lineWidth: 2)
                .frame(width: 162, height: 162)
                .rotationEffect(.degrees(spinB * 0.72))

            Circle().trim(from: 0.44, to: 0.86)
                .stroke(cyan.opacity(0.42), lineWidth: 0.8)
                .frame(width: 142, height: 142)
                .rotationEffect(.degrees(spinA * 1.2))

            ForEach(0..<8, id: \.self) { index in
                Circle()
                    .fill(index.isMultiple(of: 3) ? amber : cyan)
                    .frame(width: index.isMultiple(of: 3) ? 4 : 2.5, height: index.isMultiple(of: 3) ? 4 : 2.5)
                    .offset(y: -64)
                    .rotationEffect(.degrees(Double(index) * 45 - spinB * 0.4))
            }

            Circle().stroke(cyan.opacity(0.55), lineWidth: 1).frame(width: 104, height: 104)
            Circle()
                .stroke(amber.opacity(app.speech.isAwake ? 0.9 : 0.22), lineWidth: app.speech.isAwake ? 2 : 0.7)
                .frame(width: 82, height: 82)
                .scaleEffect(pulse ? 1.035 : 0.97)

            Circle()
                .fill(RadialGradient(colors: [.white, cyan.opacity(0.98), cyan.opacity(0.36), .black.opacity(0.25)], center: .center, startRadius: 0, endRadius: 46))
                .frame(width: 74, height: 74)
                .shadow(color: app.speech.isSpeaking ? amber.opacity(0.75) : cyan.opacity(0.75), radius: app.speech.isSpeaking ? 24 : 16)

            VStack(spacing: 1) {
                Text(coreStateText)
                    .font(.system(size: 6.4, weight: .bold, design: .monospaced))
                    .tracking(0.9)
                    .foregroundStyle(app.speech.isAwake || app.speech.isSpeaking ? amber : .white.opacity(0.8))
                Text("JARVIS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 235, height: 235)
    }

    private var coreStateText: String {
        if app.speech.isSpeaking { return "SPEAKING" }
        if app.speech.isAwake { return "ONLINE" }
        if app.speech.isListening { return "LISTENING" }
        return "STANDBY"
    }

    private var leftContextPanel: some View {
        hudPanel(title: "SYSTEM") {
            hudRow("AI CORE", app.brainStatus, accent: cyan)
            hudRow("MEMORY", "\(app.memoryCount)", accent: cyan)
            hudRow("VOICE", app.speech.isListening ? "ACTIVE" : "OFFLINE", accent: app.speech.isListening ? cyan : .red)
        }
    }

    private var rightContextPanel: some View {
        hudPanel(title: "P1S LINK") {
            hudRow("STATE", app.configured ? app.status.state.rawValue.uppercased() : "SETUP", accent: app.configured ? cyan : amber)
            hudRow("JOB", app.status.jobName ?? "NONE", accent: cyan)
            hudRow("PROGRESS", "\(Int(app.status.progress))%", accent: cyan)
        }
    }

    private func hudPanel<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 6.4, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(cyan)
                Rectangle().fill(cyan.opacity(0.45)).frame(height: 0.7)
            }
            content()
        }
        .padding(8)
        .frame(width: 122, alignment: .leading)
        .background(panelFill.opacity(0.55))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(cyan.opacity(0.12), lineWidth: 0.6))
    }

    private func hudRow(_ label: String, _ value: String, accent: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 5.4, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
            Spacer(minLength: 3)
            Text(value)
                .font(.system(size: 5.4, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var lowerTelemetry: some View {
        VStack(spacing: 5) {
            if app.speech.isAwake && !app.speech.transcript.isEmpty {
                Text(app.speech.transcript.uppercased())
                    .font(.system(size: 6.8, weight: .medium, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(amber.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: 250)
            }

            HStack(spacing: 8) {
                Rectangle().fill(cyan.opacity(0.25)).frame(width: 36, height: 0.7)
                waveform
                Text(app.speech.isAwake ? "FOLLOW-UP MODE" : "WAKE: JARVIS")
                    .font(.system(size: 6.0, weight: .semibold, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(app.speech.isAwake ? amber : cyan.opacity(0.75))
                    .lineLimit(1)
                Rectangle().fill(cyan.opacity(0.25)).frame(width: 36, height: 0.7)
            }
        }
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(0..<15, id: \.self) { index in
                Capsule()
                    .fill(index.isMultiple(of: 7) && app.speech.isAwake ? amber : cyan)
                    .frame(width: 1.5, height: CGFloat(3 + ((index * 5) % 11)))
                    .scaleEffect(y: app.speech.isListening ? (pulse ? 1.12 : 0.78) : 0.35)
                    .opacity(app.speech.isListening ? 0.8 : 0.25)
            }
        }
        .frame(width: 56, height: 20)
    }

    private func hudGrid(size: CGSize) -> some View {
        ZStack {
            Path { path in
                for x in stride(from: 0.0, through: size.width, by: 32) {
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: 0.0, through: size.height, by: 32) {
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            .stroke(cyan.opacity(0.035), lineWidth: 0.5)

            Path { path in
                path.move(to: CGPoint(x: 14, y: 92)); path.addLine(to: CGPoint(x: 14, y: size.height - 58))
                path.move(to: CGPoint(x: size.width - 14, y: 92)); path.addLine(to: CGPoint(x: size.width - 14, y: size.height - 58))
            }
            .stroke(cyan.opacity(0.22), lineWidth: 0.8)
        }
    }

    private var conversationPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(app.messages.enumerated()), id: \.offset) { index, message in
                        HStack(alignment: .top, spacing: 7) {
                            if message.1 { Spacer(minLength: 36) }
                            if !message.1 {
                                Text("J")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(cyan)
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().stroke(cyan.opacity(0.4), lineWidth: 0.7))
                            }
                            Text(message.0)
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(message.1 ? .white.opacity(0.9) : cyan.opacity(0.9))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(message.1 ? Color.white.opacity(0.055) : cyan.opacity(0.05))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(message.1 ? Color.white.opacity(0.08) : cyan.opacity(0.15), lineWidth: 0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            if !message.1 { Spacer(minLength: 32) }
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .onChange(of: app.messages.count) { _, count in
                if count > 0 { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(count - 1, anchor: .bottom) } }
            }
        }
        .background(Color.black.opacity(0.72))
        .overlay(alignment: .top) { Rectangle().fill(cyan.opacity(0.16)).frame(height: 0.6) }
    }

    @ViewBuilder
    private var confirmationControls: some View {
        if let name = app.pendingPrintName {
            VStack(alignment: .leading, spacing: 7) {
                Text("PRINT AUTHORIZATION REQUIRED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(amber)
                Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(2)
                HStack {
                    Button("CANCEL") { app.cancelPendingPrint() }.buttonStyle(.bordered).tint(.white.opacity(0.75))
                    Spacer()
                    Button("CONFIRM PRINT") { Task { await app.confirmPendingPrint() } }
                        .buttonStyle(.borderedProminent).tint(amber).foregroundStyle(.black).disabled(app.isBusy)
                }
            }
            .padding(11)
            .background(panelFill)
            .overlay(Rectangle().stroke(amber.opacity(0.55), lineWidth: 0.8))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    private var commandBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(voiceDotColor).frame(width: 6, height: 6)
                Text(commandVoiceText)
                    .font(.system(size: 6.8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(app.speech.isListening ? cyan.opacity(0.78) : (app.speech.isSpeaking ? amber : .red))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
                if !app.speech.isListening && !app.speech.isSpeaking {
                    Button("RESTART") { app.speech.restartVoiceLink() }
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(amber)
                }
            }
            .padding(.horizontal, 12)

            HStack(spacing: 8) {
                TextField("Type to Jarvis…", text: $text)
                    .textInputAutocapitalization(.sentences)
                    .foregroundStyle(.white)
                    .tint(cyan)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(cyan.opacity(0.18), lineWidth: 0.7))
                    .onSubmit { sendText() }

                Button { sendText() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 34, height: 34)
                        .background(cyan)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
        }
        .background(Color.black)
    }

    private var commandVoiceText: String {
        if app.speech.isSpeaking { return "JARVIS SPEAKING" }
        if app.speech.isListening { return "ALWAYS LISTENING • SAY “JARVIS” OR “HEY JARVIS”" }
        return "VOICE LINK OFFLINE"
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
                Section("Jarvis voice") {
                    HStack { Text("Wake words"); Spacer(); Text("Jarvis / Hey Jarvis").foregroundStyle(.secondary) }
                    HStack { Text("Listener"); Spacer(); Text(app.speech.isListening ? "Active" : "Offline").foregroundStyle(app.speech.isListening ? .green : .orange) }
                    HStack { Text("Natural voice"); Spacer(); Text(app.speech.neuralVoiceStatus).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }

                    Picker("Voice", selection: Binding(
                        get: { app.speech.selectedVoiceIdentifier },
                        set: { app.speech.selectVoice(identifier: $0) }
                    )) {
                        ForEach(app.speech.availableVoiceChoices) { voice in Text(voice.label).tag(voice.id) }
                    }

                    Button("Preview Natural Voice") { app.speech.previewVoice() }
                    Button("Restart Voice Link") { app.speech.restartVoiceLink() }

                    if let error = app.speech.lastError, !error.isEmpty {
                        Text("Last voice error: \(error)").font(.footnote).foregroundStyle(.orange)
                    }
                }

                Section("P1S local connection") {
                    TextField("Printer IP address", text: $host).textInputAutocapitalization(.never).keyboardType(.numbersAndPunctuation)
                    TextField("Printer serial number", text: $serial).textInputAutocapitalization(.never)
                    SecureField("LAN access code", text: $accessCode)
                    Button("Save & Test P1S") { app.configure(host: host, serial: serial, accessCode: accessCode) }
                        .disabled(host.isEmpty || serial.isEmpty || accessCode.isEmpty || app.isBusy)
                }

                Section("MakerWorld") {
                    HStack { Text("Status"); Spacer(); Text(app.makerWorldSignedIn ? "Connected" : "Not connected").foregroundStyle(app.makerWorldSignedIn ? .green : .secondary) }
                    TextField("Bambu / MakerWorld email", text: $bambuAccount).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                    SecureField("Password", text: $bambuPassword)
                    TextField("Verification code", text: $bambuVerificationCode).keyboardType(.numberPad)
                    Button(app.makerWorldSignedIn ? "Sign In Again" : "Sign In to MakerWorld") {
                        Task {
                            await app.signInMakerWorld(account: bambuAccount, password: bambuPassword, verificationCode: bambuVerificationCode)
                            if app.makerWorldSignedIn { bambuPassword = ""; bambuVerificationCode = "" }
                        }
                    }
                    .disabled(bambuAccount.isEmpty || (bambuPassword.isEmpty && bambuVerificationCode.isEmpty) || app.isBusy)
                }

                Section("Intelligence") {
                    HStack { Text("AI core"); Spacer(); Text(app.brainStatus).foregroundStyle(.secondary) }
                    HStack { Text("Saved memories"); Spacer(); Text("\(app.memoryCount)").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Jarvis Systems")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { app.showSetup = false } } }
        }
    }
}
