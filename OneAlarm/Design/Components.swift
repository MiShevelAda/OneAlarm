import SwiftUI

// MARK: Buttons

/// Eight Sleep's primary: a solid white pill with black text.
struct SolidButton: View {
    let title: String
    var busy = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.black) }
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(.white, in: Capsule())
            .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
        .opacity(enabled && !busy ? 1 : 0.4)
        .disabled(!enabled || busy)
    }
}

/// Whoop's secondary: a thin outlined pill, uppercase, wide tracking.
struct GhostButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .tracking(1.7)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, minHeight: 54)
                .overlay(Capsule().strokeBorder(.white, lineWidth: 1.5))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

struct QuietButton: View {
    let title: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.white.opacity(0.09), in: Capsule())
                .foregroundStyle(role == .destructive ? Theme.State.failed : .white)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Chips

struct Chip: View {
    let text: String
    var dim = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Color.white.opacity(0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
            .foregroundStyle(dim ? Theme.grey : .white)
    }
}

// MARK: Notice

/// The failure states are where this app earns trust, so they get a real component rather than a
/// red `Text`. Each one says what happened and what to do.
struct Notice: View {
    enum Kind { case neutral, good, warn, bad }

    let kind: Kind
    let title: String?
    // NOT named `body`. A View already has `var body`, so a stored property of that
    // name is an invalid redeclaration rather than an overload.
    let message: String

    init(_ kind: Kind = .neutral, title: String? = nil, _ message: String) {
        self.kind = kind
        self.title = title
        self.message = message
    }

    private var tint: Color {
        switch kind {
        case .neutral: return Theme.grey
        case .good: return Theme.State.confirmed
        case .warn: return Theme.State.unconfirmed
        case .bad: return Theme.State.failed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            }
            Text(message).font(.system(size: 14)).foregroundStyle(kind == .neutral ? Theme.grey : tint.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(kind == .neutral ? Theme.card : tint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(kind == .neutral ? Theme.line : tint.opacity(0.32), lineWidth: 1)
        )
    }
}

// MARK: State pill

struct StatePill: View {
    let text: String
    let color: Color
    var showsDot = true

    var body: some View {
        HStack(spacing: 6) {
            if showsDot {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
        }
    }
}

extension DeviceSyncStatus {
    var pillColor: Color {
        switch self {
        case .idle, .writing, .verifying: return Theme.grey
        case .done: return Theme.State.confirmed
        case .warning: return Theme.State.unconfirmed
        case .failed: return Theme.State.failed
        }
    }

    var pillText: String {
        switch self {
        case .idle: return ""
        case .writing: return "Writing"
        case .verifying: return "Checking it landed"
        case .done(let m): return m
        case .warning(let m): return m
        case .failed(let m): return m
        }
    }
}

// MARK: Screen scaffold

/// Every screen sits on the same ground with the same gutters, so the ground gradient is continuous
/// and never restated per screen.
struct Screen<Content: View, Footer: View>: View {
    var title: String?
    var onBack: (() -> Void)?
    var trailing: AnyView?
    var content: () -> Content
    var footer: () -> Footer

    // Written out rather than relying on the memberwise initialiser, so the result builder
    // attributes are unambiguous at every call site.
    init(
        title: String? = nil,
        onBack: (() -> Void)? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.title = title
        self.onBack = onBack
        self.trailing = trailing
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 0) {
            if title != nil || onBack != nil {
                HStack {
                    Group {
                        if let onBack {
                            Button(action: onBack) {
                                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                            }
                        }
                    }
                    .frame(width: 40, alignment: .leading)

                    Spacer()
                    if let title { Text(title).themeLabel(.white) }
                    Spacer()

                    Group { trailing }.frame(width: 40, alignment: .trailing)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 16)
            }

            ScrollView {
                content().padding(.horizontal, Theme.gutter)
            }

            VStack(spacing: 10) { footer() }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 12)
                .padding(.bottom, 28)
        }
        .background(Theme.Ground.gradient.ignoresSafeArea())
        .foregroundStyle(.white)
    }
}

extension Screen where Footer == EmptyView {
    init(
        title: String? = nil,
        onBack: (() -> Void)? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, onBack: onBack, trailing: trailing, content: content, footer: { EmptyView() })
    }
}

// MARK: Step dots

struct StepDots: View {
    let total: Int
    let current: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? Color.white : Color.white.opacity(0.18))
                    .frame(width: 22, height: 3)
            }
        }
        .padding(.bottom, 18)
    }
}
