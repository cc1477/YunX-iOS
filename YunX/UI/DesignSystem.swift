// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import SwiftUI

// MARK: - 背景

/// 全局背景：系统分组背景 + 两团随主题色变化的柔光，让玻璃卡片有东西可「透」
struct AppBackground: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            GeometryReader { proxy in
                let w = proxy.size.width
                Circle()
                    .fill(settings.accent.color.opacity(scheme == .dark ? 0.35 : 0.22))
                    .frame(width: w * 1.1)
                    .blur(radius: 90)
                    .offset(x: -w * 0.35, y: -w * 0.55)
                Circle()
                    .fill(settings.accent.secondary.opacity(scheme == .dark ? 0.28 : 0.16))
                    .frame(width: w * 0.9)
                    .blur(radius: 100)
                    .offset(x: w * 0.45, y: -w * 0.2)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 卡片

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let trailing, let action {
                Button(trailing, action: action).font(.subheadline)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - 按钮

struct GradientButtonStyle: ButtonStyle {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(settings.accent.gradient.opacity(isEnabled ? 1 : 0.45),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: settings.accent.color.opacity(isEnabled ? 0.35 : 0), radius: 12, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct ChipButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(tint)
            .background(tint.opacity(configuration.isPressed ? 0.22 : 0.12), in: Capsule())
    }
}

// MARK: - 平台图标

struct PlatformLogo: View {
    let name: String
    var size: CGFloat = 36
    var dimmed = false

    var body: some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .padding(size * 0.12)
            .frame(width: size, height: size)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.primary.opacity(0.06)))
            .saturation(dimmed ? 0 : 1)
            .opacity(dimmed ? 0.5 : 1)
    }
}

/// 文件类型图标：带色块的 SF Symbol
struct FileIcon: View {
    let kind: FileKind
    var size: CGFloat = 40

    var color: Color {
        switch kind {
        case .folder: return Color(hex: 0xF5B83D)
        case .video: return Color(hex: 0xFF5A5F)
        case .image: return Color(hex: 0x34C759)
        case .audio: return Color(hex: 0xAF52DE)
        case .archive: return Color(hex: 0xFF9500)
        case .document: return Color(hex: 0x007AFF)
        case .apk: return Color(hex: 0x5AC8FA)
        case .code: return Color(hex: 0x8E8E93)
        case .other: return Color(hex: 0x8E8E93)
        }
    }

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct Tag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - 进度条

struct ProgressCapsule: View {
    let value: Double
    var indeterminate = false
    @Environment(SettingsStore.self) private var settings
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                if indeterminate {
                    Capsule()
                        .fill(settings.accent.gradient)
                        .frame(width: proxy.size.width * 0.3)
                        .offset(x: phase * proxy.size.width)
                        .onAppear {
                            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
                        }
                } else {
                    Capsule()
                        .fill(settings.accent.gradient)
                        .frame(width: max(6, proxy.size.width * value))
                        .animation(.easeOut(duration: 0.3), value: value)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }
}

// MARK: - 提示条

struct Toast: Equatable {
    enum Style { case success, error, info }
    let message: String
    let style: Style
}

@MainActor
@Observable
final class ToastCenter {
    var current: Toast?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func show(_ message: String, _ style: Toast.Style = .info) {
        hideTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { current = Toast(message: message, style: style) }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut) { current = nil }
        }
    }
}

struct ToastOverlay: View {
    @Environment(ToastCenter.self) private var center

    var body: some View {
        VStack {
            if let toast = center.current {
                HStack(spacing: 10) {
                    Image(systemName: icon(toast.style)).foregroundStyle(color(toast.style))
                    Text(toast.message).font(.subheadline.weight(.medium)).lineLimit(3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.thickMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { center.current = nil }
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private func icon(_ style: Toast.Style) -> String {
        switch style {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(_ style: Toast.Style) -> Color {
        switch style {
        case .success: return .green
        case .error: return .orange
        case .info: return .accentColor
        }
    }
}
