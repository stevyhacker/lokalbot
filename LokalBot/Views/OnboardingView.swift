import SwiftUI
import AppKit

/// First-run onboarding and permission repair.
///
/// The structure mirrors CoTabby's polished setup flow while staying native to
/// LokalBot's product: a value-first wizard, a live-looking local demo, a
/// material backdrop, progress pips, and permission cards that update as macOS
/// grants arrive. Permission behavior remains owned by `PermissionManager`.
struct OnboardingView: View {
    enum Mode { case welcome, permissions }

    private enum WelcomeStep: Int, CaseIterable, Comparable {
        case welcome
        case flow
        case privacy
        case permissions

        static func < (lhs: WelcomeStep, rhs: WelcomeStep) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var next: WelcomeStep? { WelcomeStep(rawValue: rawValue + 1) }
        var previous: WelcomeStep? { WelcomeStep(rawValue: rawValue - 1) }
        var progressIndex: Int { rawValue + 1 }
    }

    var mode: Mode = .welcome

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var permissions = PermissionManager.shared
    @State private var step: WelcomeStep = .welcome
    @State private var navigatesForward = true

    private var isWelcomeMode: Bool { mode == .welcome }
    private var contentWidth: CGFloat { isWelcomeMode ? 640 : 560 }

    private var requiredPermissions: [AppPermission] {
        AppPermission.coreCases
    }

    private var optionalPermissions: [AppPermission] {
        AppPermission.allCases.filter(\.isOptionalOnboardingEnhancement)
    }

    private var missingRequiredCount: Int {
        requiredPermissions.filter { permissions.granted[$0] != true }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            if isWelcomeMode {
                OnboardingProgressPips(
                    current: step.progressIndex,
                    total: WelcomeStep.allCases.count
                )
                .padding(.top, 24)
                .transition(.opacity)
            }

            ZStack {
                currentPage
                    .id(isWelcomeMode ? step.rawValue : WelcomeStep.permissions.rawValue)
                    .transition(pageTransition)
            }

            if isWelcomeMode {
                footer
            }
        }
        .frame(width: contentWidth)
        .background(OnboardingBackdrop())
        .onAppear {
            if mode == .permissions { step = .permissions }
            permissions.startPolling()
        }
        .onDisappear { permissions.stopPolling() }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch isWelcomeMode ? step : .permissions {
        case .welcome:
            welcomePage
        case .flow:
            flowPage
        case .privacy:
            privacyPage
        case .permissions:
            permissionPage
        }
    }

    private var pageTransition: AnyTransition {
        guard isWelcomeMode, !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .move(edge: navigatesForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: navigatesForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func go(to next: WelcomeStep) {
        navigatesForward = next > step
        guard !reduceMotion else {
            step = next
            return
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
            step = next
        }
    }
}

// MARK: - Pages

private extension OnboardingView {
    var welcomePage: some View {
        VStack(spacing: 24) {
            appIcon
                .onboardingReveal(0)

            VStack(spacing: 8) {
                Text("Welcome to LokalBot")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                Text("Your local meeting memory, with recording, recap, search, and cotyping on this Mac.")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onboardingReveal(1)

            LokalBotHeroDemo()
                .frame(maxWidth: 460)
                .onboardingReveal(2)

            HStack(spacing: 8) {
                OnboardingFeatureChip(systemImage: "lock.fill", label: "On-device")
                OnboardingFeatureChip(systemImage: "waveform", label: "Records both sides")
                OnboardingFeatureChip(systemImage: "text.cursor", label: "Cotyping ready")
            }
            .onboardingReveal(3)
        }
        .padding(.horizontal, 46)
        .padding(.top, 34)
        .padding(.bottom, 22)
    }

    var flowPage: some View {
        VStack(spacing: 24) {
            OnboardingStepHeader(
                systemImage: "waveform.badge.magnifyingglass",
                title: "Calls become a searchable memory",
                subtitle: "LokalBot quietly turns meetings into useful local artifacts."
            )
            .onboardingReveal(0)

            VStack(spacing: 10) {
                TimelineCard(
                    number: "1",
                    systemImage: "dot.radiowaves.left.and.right",
                    tint: Brand.teal,
                    title: "Detect and record",
                    subtitle: "Meeting audio is captured as separate mic and system tracks."
                )
                .onboardingReveal(1)

                TimelineCard(
                    number: "2",
                    systemImage: "doc.text.viewfinder",
                    tint: .indigo,
                    title: "Transcribe and summarize",
                    subtitle: "Local models produce the transcript, decisions, and action items."
                )
                .onboardingReveal(2)

                TimelineCard(
                    number: "3",
                    systemImage: "magnifyingglass.circle.fill",
                    tint: .orange,
                    title: "Search and ask",
                    subtitle: "Replay, search screen text, and ask questions across your library."
                )
                .onboardingReveal(3)
            }
        }
        .pagePadding()
    }

    var privacyPage: some View {
        VStack(spacing: 24) {
            OnboardingStepHeader(
                systemImage: "lock.shield.fill",
                title: "Private by default",
                subtitle: "The setup asks for macOS access only where the local workflow needs it."
            )
            .onboardingReveal(0)

            VStack(spacing: 10) {
                PrivacyCard(
                    systemImage: "externaldrive.fill",
                    tint: Brand.teal,
                    title: "Stored locally",
                    subtitle: "Audio, transcripts, summaries, embeddings, and screenshots live under LokalBot's local app support folder."
                )
                .onboardingReveal(1)

                PrivacyCard(
                    systemImage: "network.slash",
                    tint: .purple,
                    title: "No account required",
                    subtitle: "Model downloads are explicit. Optional custom backends are only used when you choose them."
                )
                .onboardingReveal(2)

                PrivacyCard(
                    systemImage: "menubar.rectangle",
                    tint: Brand.amber,
                    title: "Runs from the menu bar",
                    subtitle: "After setup, LokalBot can stay out of the way and keep working from the menu bar."
                )
                .onboardingReveal(3)
            }
        }
        .pagePadding()
    }

    var permissionPage: some View {
        VStack(spacing: 22) {
            OnboardingStepHeader(
                systemImage: missingRequiredCount == 0 ? "checkmark.shield.fill" : "lock.shield.fill",
                tint: missingRequiredCount == 0 ? .green : Brand.teal,
                title: isWelcomeMode ? "Grant LokalBot access" : "Permissions",
                subtitle: permissionSubtitle
            )
            .onboardingReveal(0)

            VStack(spacing: 10) {
                ForEach(Array(requiredPermissions.enumerated()), id: \.element) { index, permission in
                    PermissionSetupCard(
                        permission: permission,
                        granted: permissions.granted[permission] ?? permission.isGranted,
                        request: {
                            permissions.request(permission)
                            permissions.openSettings(for: permission)
                        }
                    )
                    .onboardingReveal(1 + index)
                }

                ForEach(Array(optionalPermissions.enumerated()), id: \.element) { index, permission in
                    PermissionSetupCard(
                        permission: permission,
                        granted: permissions.granted[permission] ?? permission.isGranted,
                        isOptional: true,
                        request: {
                            permissions.request(permission)
                            permissions.openSettings(for: permission)
                        }
                    )
                    .onboardingReveal(1 + requiredPermissions.count + index)
                }
            }

            manualAppCard
                .onboardingReveal(2 + requiredPermissions.count + optionalPermissions.count)

            relaunchCard
                .onboardingReveal(3 + requiredPermissions.count + optionalPermissions.count)
        }
        .pagePadding(top: isWelcomeMode ? 18 : 28, bottom: isWelcomeMode ? 14 : 28)
    }

    var permissionSubtitle: String {
        if missingRequiredCount == 0 {
            return "Required permissions are granted. Relaunch if macOS asked you to restart the app."
        }
        let noun = missingRequiredCount == 1 ? "permission" : "permissions"
        return "Grant the \(missingRequiredCount) required \(noun), then come back here. Cotype input monitoring is optional."
    }
}

// MARK: - Footer

private extension OnboardingView {
    var footer: some View {
        HStack(spacing: 10) {
            if let previous = step.previous {
                Button("Back") { go(to: previous) }
                    .controlSize(.large)
            }

            Spacer(minLength: 0)

            if step == .permissions {
                Button("I'll do this later") {
                    dismiss()
                }
                .controlSize(.large)

                Button("Start using LokalBot") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.teal)
                .controlSize(.large)
                .disabled(!permissions.allGranted)
                .help(permissions.allGranted ? "" : "Grant the required permissions to finish setup.")
            } else if let next = step.next {
                Button(step == .privacy ? "Continue to permissions" : "Continue") {
                    go(to: next)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.teal)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .scaledToFit()
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            .shadow(color: Brand.teal.opacity(0.45), radius: 22, y: 8)
    }

    var manualAppCard: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }

            VStack(alignment: .leading, spacing: 2) {
                Text("Adding LokalBot manually?")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("Drag this app icon into System Settings if macOS asks you to add the app to a permission list.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
            .controlSize(.regular)
        }
        .padding(16)
        .onboardingCard(cornerRadius: 14)
    }

    var relaunchCard: some View {
        HStack(spacing: 12) {
            OnboardingIconTile(systemImage: "arrow.triangle.2.circlepath", tint: .orange, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Relaunch after granting access")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("Some macOS permissions only take effect after the app starts again.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("Relaunch") { PermissionManager.relaunch() }
                .controlSize(.regular)
        }
        .padding(16)
        .onboardingCard(cornerRadius: 14)
    }
}

// MARK: - Hero Demo

private struct LokalBotHeroDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase = 0

    private let phases = [
        ("Recording", "Google Meet", "Mic + system audio"),
        ("Transcript", "Decision: ship beta Friday", "Action items extracted"),
        ("Ask", "What did we promise Alex?", "Searches local meetings")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18))
                Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25))
            }
            .frame(height: 7)
            .opacity(0.85)

            HStack(alignment: .center, spacing: 14) {
                OnboardingIconTile(
                    systemImage: phase == 0 ? "waveform" : phase == 1 ? "doc.text.viewfinder" : "bubble.left.and.text.bubble.right.fill",
                    tint: phase == 0 ? Brand.teal : phase == 1 ? .indigo : .orange,
                    size: 42
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(phases[phase].0)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(phases[phase].1)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(phases[phase].2)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Brand.teal.opacity(0.24), lineWidth: 1)
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: phase)
        }
        .padding(16)
        .onboardingCard(cornerRadius: 14)
        .task(id: reduceMotion) {
            guard !reduceMotion else {
                phase = 1
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_550_000_000)
                if Task.isCancelled { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                    phase = (phase + 1) % phases.count
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Cards

private struct PermissionSetupCard: View {
    let permission: AppPermission
    let granted: Bool
    var isOptional = false
    let request: () -> Void

    private var tileTint: Color {
        if granted || isOptional { return permission.onboardingTint }
        return .orange
    }

    var body: some View {
        HStack(spacing: 14) {
            OnboardingIconTile(systemImage: permission.systemImageName, tint: tileTint)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))

                    if isOptional {
                        Text("Optional")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }

                Text(permission.onboardingSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if granted {
                PermissionDoneBadge()
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                if isOptional {
                    Button("Allow") { request() }
                        .buttonStyle(.bordered)
                        .tint(permission.onboardingTint)
                        .controlSize(.regular)
                } else {
                    Button("Allow") { request() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.regular)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCard()
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: granted)
    }
}

private struct PermissionDoneBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
            Text("Done")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.green)
    }
}

private struct TimelineCard: View {
    let number: String
    let systemImage: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                OnboardingIconTile(systemImage: systemImage, tint: tint, size: 42)
                Text(number)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(5)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .onboardingCard()
    }
}

private struct PrivacyCard: View {
    let systemImage: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            OnboardingIconTile(systemImage: systemImage, tint: tint, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .onboardingCard()
    }
}

private struct OnboardingFeatureChip: View {
    let systemImage: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Brand.teal)

            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

// MARK: - Shared Onboarding Chrome

private struct OnboardingBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)

            RadialGradient(
                colors: [Brand.tealBright.opacity(colorScheme == .dark ? 0.26 : 0.14), .clear],
                center: UnitPoint(x: 0.12, y: -0.08),
                startRadius: 8,
                endRadius: 460
            )

            RadialGradient(
                colors: [Brand.teal.opacity(colorScheme == .dark ? 0.16 : 0.09), .clear],
                center: UnitPoint(x: 0.96, y: 0.03),
                startRadius: 8,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingIconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.84), tint],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: tint.opacity(0.32), radius: size * 0.14, y: size * 0.06)

            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

private struct OnboardingStepHeader: View {
    var systemImage: String?
    var tint: Color = Brand.teal
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            if let systemImage {
                OnboardingIconTile(systemImage: systemImage, tint: tint, size: 44)
                    .padding(.bottom, 4)
            }

            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct OnboardingProgressPips: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(1...total, id: \.self) { index in
                Capsule()
                    .fill(fillStyle(for: index))
                    .frame(width: index == current ? 26 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current) of \(total)")
    }

    private func fillStyle(for index: Int) -> AnyShapeStyle {
        if index == current {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Brand.tealBright, Brand.teal],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        if index < current {
            return AnyShapeStyle(Brand.teal.opacity(0.55))
        }
        return AnyShapeStyle(Color.secondary.opacity(0.22))
    }
}

private struct OnboardingCardChrome: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }
}

private struct OnboardingReveal: ViewModifier {
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 14)
            .onAppear {
                guard !reduceMotion else {
                    revealed = true
                    return
                }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85).delay(Double(index) * 0.06)) {
                    revealed = true
                }
            }
    }
}

private extension View {
    func onboardingCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(OnboardingCardChrome(cornerRadius: cornerRadius))
    }

    func onboardingReveal(_ index: Int) -> some View {
        modifier(OnboardingReveal(index: index))
    }

    func pagePadding(top: CGFloat = 24, bottom: CGFloat = 18) -> some View {
        padding(.horizontal, 36)
            .padding(.top, top)
            .padding(.bottom, bottom)
    }
}

private extension AppPermission {
    var onboardingTint: Color {
        switch self {
        case .microphone:
            Brand.teal
        case .screenRecording:
            .indigo
        case .accessibility:
            .purple
        case .inputMonitoring:
            Brand.amber
        }
    }
}
