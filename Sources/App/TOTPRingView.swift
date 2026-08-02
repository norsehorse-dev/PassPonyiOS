import SwiftUI

/// Live TOTP code with the progress ring, re-derived each second from the
/// already-decrypted entry bytes (no re-decryption on tick).
struct TOTPRingView: View {
    let content: Data

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = UInt64(context.date.timeIntervalSince1970)
            if let totp = entryTotp(content: content, unixTime: now) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 4)
                        Circle()
                            .trim(
                                from: 0,
                                to: CGFloat(totp.secondsRemaining) / CGFloat(max(totp.period, 1))
                            )
                            .stroke(
                                totp.secondsRemaining <= 5 ? Color.red : Color.accentColor,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        Text("\(totp.secondsRemaining)")
                            .font(.caption2.monospacedDigit())
                    }
                    .frame(width: 36, height: 36)

                    Text(formatted(totp.code))
                        .font(.system(.title2, design: .monospaced))
                        .textSelection(.enabled)

                    Spacer()

                    Button {
                        Clipboard.copyEphemeral(Data(totp.code.utf8))
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func formatted(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<mid]) \(code[mid...])"
    }
}
