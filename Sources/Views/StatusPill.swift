import SwiftUI

/// Colored dot + status label displayed below the mascot sprite.
struct StatusPill: View {
    let status: Status

    var body: some View {
        HStack(spacing: 6) {
            // Colored dot
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .overlay(
                    // Pulsing ring for busy/searching states
                    Circle()
                        .stroke(dotColor.opacity(0.5), lineWidth: 2)
                        .scaleEffect(isPulsing ? 2.0 : 1.0)
                        .opacity(isPulsing ? 0.0 : 0.8)
                        .animation(
                            isPulsing ? .easeOut(duration: 1.0).repeatForever(autoreverses: false) : .default,
                            value: isPulsing
                        )
                )

            // Status label
            Text(status.displayLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(.black.opacity(0.5))
                .shadow(color: dotColor.opacity(0.3), radius: 4)
        )
    }

    private var dotColor: Color {
        switch status {
        case .idle: return .green
        case .busy: return .red
        case .service: return .blue
        case .searching, .initializing: return .yellow
        case .disconnected: return .gray
        case .visiting: return .teal
        case .carrying: return .orange
        }
    }

    private var isPulsing: Bool {
        status == .busy || status == .searching
    }
}
