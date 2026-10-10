import MachCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// How long a sign-in code is worth showing for. They stop working within minutes; the list forgets them after an hour.
enum CodeAge {
    static let inList: TimeInterval = 3600
    static let opened: TimeInterval = 86_400

    static func fresh(_ thread: MailThread, within age: TimeInterval = inList) -> String? {
        guard let code = thread.code, Date().timeIntervalSince(thread.date) < age else { return nil }
        return code
    }
}

/// The sign-in code of a conversation, in its row. One tap (or click) copies it.
struct CodeChip: View {
    let code: String
    var scale: CGFloat = 1
    var action: (() -> Void)?

    var body: some View {
        let label = HStack(spacing: 4 * scale) {
            Text(code).font(.system(size: Theme.pt(12) * scale, weight: .semibold, design: .monospaced))
            Image(systemName: "doc.on.doc").font(.system(size: Theme.pt(9) * scale, weight: .semibold))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 6 * scale)
        .padding(.vertical, 2 * scale)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { label }.buttonStyle(.plain).help("Copy the code")
        } else {
            label
        }
    }
}

/// Microsoft's sign-in button, to its branding rules: the four-colour mark untouched, their wording, their light
/// button whatever the app's theme is.
struct MicrosoftButton: View {
    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    Rectangle().fill(Color(light: 0xF25022, dark: 0xF25022)).frame(width: 9.5, height: 9.5)
                    Rectangle().fill(Color(light: 0x7FBA00, dark: 0x7FBA00)).frame(width: 9.5, height: 9.5)
                }
                HStack(spacing: 2) {
                    Rectangle().fill(Color(light: 0x00A4EF, dark: 0x00A4EF)).frame(width: 9.5, height: 9.5)
                    Rectangle().fill(Color(light: 0xFFB900, dark: 0xFFB900)).frame(width: 9.5, height: 9.5)
                }
            }
            Text("Sign in with Microsoft").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(light: 0x5E5E5E, dark: 0x5E5E5E))
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.white, in: Rectangle())
        .overlay(Rectangle().strokeBorder(Color(light: 0x8C8C8C, dark: 0x8C8C8C), lineWidth: 1))
        .contentShape(Rectangle())
    }
}
