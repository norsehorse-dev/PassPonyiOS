import SwiftUI

/// Top-level first-run carousel: swipeable slides, Skip in the top-right
/// (hidden on the last page), dot indicator plus Next / Done at the
/// bottom. Rendered by RootView while the onboarding flag is unset,
/// replacing both the lock screen and the store list until the user
/// finishes or skips. Replayable from Settings (Show welcome tour again).
struct OnboardingView: View {
    let onComplete: () -> Void

    @EnvironmentObject var model: AppModel
    @State private var currentPage = 0

    private let slides = OnboardingSlides.all

    private var isLastPage: Bool { currentPage >= slides.count - 1 }

    var body: some View {
        VStack(spacing: 0) {

            // Top bar (Skip)
            HStack {
                Spacer()
                if !isLastPage {
                    Button {
                        onComplete()
                    } label: {
                        Text("Skip")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // Preserve layout height when Skip is hidden.
                    Color.clear.frame(height: 22)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Pager
            TabView(selection: $currentPage) {
                ForEach(slides.indices, id: \.self) { i in
                    OnboardingPage(
                        slide: slides[i],
                        onAdvance: { advance() }
                    )
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: currentPage)
            // Re-key on language change so a pick on slide one re-resolves
            // every slide live; currentPage lives outside this subtree and
            // survives the rebuild.
            .id(model.language)

            // Bottom bar (dots + advance button)
            HStack {
                pageIndicator
                Spacer()
                advanceButton
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    // MARK: - Sub-views

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(slides.indices, id: \.self) { i in
                Circle()
                    .fill(i == currentPage
                          ? Color.accentColor
                          : Color.secondary.opacity(0.3))
                    .frame(
                        width: i == currentPage ? 10 : 8,
                        height: i == currentPage ? 10 : 8
                    )
                    .animation(.easeInOut(duration: 0.2), value: currentPage)
            }
        }
    }

    private var advanceButton: some View {
        Button {
            if isLastPage {
                onComplete()
            } else {
                advance()
            }
        } label: {
            Text(LocalizedStringKey(isLastPage ? "Done" : "Next"))
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .frame(height: 36)
        }
        .buttonStyle(.borderedProminent)
    }

    // MARK: - Actions

    private func advance() {
        guard currentPage < slides.count - 1 else { return }
        withAnimation { currentPage += 1 }
    }
}
