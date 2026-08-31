import AppKit
import SwiftUI

struct OnboardingBackdrop: View {
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

struct OnboardingStepHeader: View {
    var systemImage: String?
    var tint: Color = Brand.teal
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            if let systemImage {
                IconTile(systemImage: systemImage, tint: tint, size: 44)
                    .padding(.bottom, 4)
            }

            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

struct OnboardingProgressPips: View {
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
        .accessibilityIdentifier("onboarding.progress")
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

struct OnboardingCardChrome: ViewModifier {
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

struct OnboardingReveal: ViewModifier {
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

extension View {
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

extension AppPermission {
    var onboardingTint: Color {
        switch self {
        case .microphone:
            Brand.teal
        case .screenRecording:
            Brand.tealBright
        case .accessibility:
            Brand.teal
        case .inputMonitoring:
            Brand.amber
        }
    }
}
