import SwiftUI

struct IslandExpandedNavigationView: View {
    let state: IslandShellExpandedNavigationRenderState

    private var selectedTabID: String? {
        state.tabs.first(where: { $0.isSelected })?.id
    }

    var body: some View {
        HStack(spacing: CodexIslandChromeMetrics.moduleHeaderToolbarSpacing) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CodexIslandChromeMetrics.moduleTabSpacing) {
                        ForEach(state.tabs) { tab in
                            Button(action: tab.action) {
                                HStack(spacing: 8) {
                                    tabIcon(tab)
                                        .frame(width: 14, height: 14, alignment: .center)

                                    Text(tab.title)
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)

                                    if tab.showsPendingBadge {
                                        Circle()
                                            .fill(Color(red: 0.29, green: 0.86, blue: 0.46))
                                            .frame(width: 7, height: 7)
                                    }
                                }
                                .foregroundStyle(tab.isSelected ? Color.black.opacity(0.92) : .white.opacity(0.72))
                                .padding(.horizontal, CodexIslandChromeMetrics.moduleTabHorizontalPadding)
                                .padding(.vertical, CodexIslandChromeMetrics.moduleTabVerticalPadding)
                                .background(
                                    tab.isSelected
                                        ? Color.white.opacity(0.92)
                                        : Color.white.opacity(0.06),
                                    in: Capsule()
                                )
                                .frame(height: max(32, CodexIslandChromeMetrics.moduleNavigationRowHeight - 4))
                                .transaction { transaction in
                                    transaction.animation = nil
                                }
                            }
                            .buttonStyle(.plain)
                            .id(tab.id)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .onAppear {
                    scrollToSelectedTab(using: proxy)
                }
                .onChange(of: selectedTabID) { _, _ in
                    scrollToSelectedTab(using: proxy)
                }
            }

            Button(action: state.openSettings) {
                Image(systemName: "gear")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.white.opacity(0.94))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Open settings")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scrollToSelectedTab(using proxy: ScrollViewProxy) {
        guard let selectedTabID else {
            return
        }

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.18)) {
                proxy.scrollTo(selectedTabID, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func tabIcon(_ tab: IslandShellTabRenderState) -> some View {
        if let iconAssetName = tab.iconAssetName {
            Image(iconAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: tab.symbolName)
                .font(.system(size: 12, weight: .semibold))
        }
    }
}
