import SwiftUI

/// The generator's options: length, character classes, and which symbols,
/// with a live preview that regenerates on every change. Use hands the
/// shown password to the caller and remembers the settings for the
/// one-tap Generate button (app-group defaults, per device). The preview
/// is shown in the clear, since the point is to look at it; it is plain
/// @State and goes with the sheet.
struct GeneratorSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onUse: (String) -> Void

    @State private var settings = GeneratorSettings.load()
    @State private var lengthText = ""
    @State private var preview = ""
    @State private var problem: String?

    /// The slider covers the everyday range; the field reaches the core's ceiling.
    private static let sliderMax = 64

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(preview)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            regenerate()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!settings.isValid)
                        .accessibilityLabel("New password")
                    }
                    if let problem {
                        Text(problem).foregroundStyle(.red).font(.footnote)
                    } else if !settings.hasAnyClass {
                        Text("Turn on at least one kind of character.")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                } header: {
                    Text("Preview")
                }

                Section {
                    HStack {
                        Text("Length")
                        Spacer()
                        TextField("Length", text: $lengthText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                            .onChange(of: lengthText) { _, text in
                                let digits = String(text.filter(\.isNumber).prefix(3))
                                if digits != text { lengthText = digits }
                                if let n = Int(digits),
                                   (GeneratorSettings.minLength...GeneratorSettings.maxLength).contains(n) {
                                    settings.length = n
                                }
                            }
                    }
                    Slider(
                        value: Binding(
                            get: { Double(min(settings.length, Self.sliderMax)) },
                            set: { value in
                                settings.length = Int(value.rounded())
                                lengthText = "\(settings.length)"
                            }
                        ),
                        in: Double(GeneratorSettings.minLength)...Double(Self.sliderMax),
                        step: 1
                    )
                } footer: {
                    Text("\(GeneratorSettings.minLength) to \(GeneratorSettings.maxLength) characters. The slider stops at 64; type a larger number for more.")
                }

                Section {
                    Toggle("Lowercase letters", isOn: $settings.lowercase)
                    Toggle("Uppercase letters", isOn: $settings.uppercase)
                    Toggle("Digits", isOn: $settings.digits)
                    Picker("Symbols", selection: $settings.symbols) {
                        Text("None").tag(GeneratorSettings.Symbols.noSymbols)
                        Text("Basic").tag(GeneratorSettings.Symbols.basic)
                        Text("Full").tag(GeneratorSettings.Symbols.full)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    switch settings.symbols {
                    case .noSymbols:
                        Text("Letters and digits only, like pass generate --no-symbols.")
                    case .basic:
                        Text("The punctuation most sites accept: \(generatorSymbols(set: .basic))")
                    case .full:
                        Text("All 32 punctuation characters, the pass default.")
                    }
                }
            }
            .navigationTitle("Password generator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use password") {
                        settings.save()
                        onUse(preview)
                        dismiss()
                    }
                    .disabled(!settings.isValid || preview.isEmpty)
                }
            }
            .onAppear {
                lengthText = "\(settings.length)"
                regenerate()
            }
            .onChange(of: settings) { _, _ in regenerate() }
        }
    }

    private func regenerate() {
        guard settings.isValid else {
            preview = ""
            return
        }
        do {
            preview = try PasswordGenerator.generate(settings)
            problem = nil
        } catch {
            preview = ""
            problem = error.ponyMessage
        }
    }
}
