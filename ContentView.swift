import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: JarvisAppModel
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("JARVIS").font(.largeTitle.bold())
                            Text("P1S • AMS").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle().fill(.green).frame(width: 10, height: 10)
                    }
                    .foregroundStyle(.white)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(app.messages.enumerated()), id: \.offset) { _, message in
                                HStack {
                                    if message.1 { Spacer() }
                                    Text(message.0)
                                        .padding(12)
                                        .background(message.1 ? .white.opacity(0.14) : .blue.opacity(0.18))
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                        .foregroundStyle(.white)
                                    if !message.1 { Spacer() }
                                }
                            }
                        }
                    }

                    HStack {
                        TextField("Tell Jarvis what to do…", text: $text)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                let command = text
                                text = ""
                                app.handle(command)
                            }

                        Button {
                            Task {
                                if app.speech.isListening { app.speech.stop() }
                                else { try? await app.speech.start() }
                            }
                        } label: {
                            Image(systemName: app.speech.isListening ? "mic.fill" : "mic")
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding()
            }
            .navigationBarHidden(true)
        }
        .preferredColorScheme(.dark)
    }
}
