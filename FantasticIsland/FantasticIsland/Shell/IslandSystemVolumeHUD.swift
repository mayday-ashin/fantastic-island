import SwiftUI

struct IslandSystemVolumeHUD: View {
    @ObservedObject var controller: IslandSystemVolumeController
    var isExpanded: Bool

    var body: some View {
        HStack(spacing: isExpanded ? 15 : 0) {
            if isExpanded {
                Image(systemName: volumeSymbolName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.94))
                    .frame(width: 18, height: 18)
                    .contentTransition(.interpolate)
                    .animation(.smooth(duration: 0.16), value: volumeSymbolName)
            }

            IslandSystemVolumeProgressBar(
                value: controller.isMuted ? 0 : controller.volume,
                onChanged: controller.setAbsolute
            )
            // frame(width: isExpanded ? 展开的音量条长度 : 收起的音量条长度, height: 高度)
            .frame(width: isExpanded ? 90 : 65, height: 5)
            .padding(.horizontal, 5)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Volume")
    }

    private var volumeSymbolName: String {
        if controller.isMuted || controller.volume <= 0.001 {
            return "speaker.slash.fill"
        }

        switch controller.volume {
        case 0..<0.34:
            return "speaker.wave.1.fill"
        case 0.34..<0.67:
            return "speaker.wave.2.fill"
        default:
            return "speaker.wave.3.fill"
        }
    }
}

private struct IslandSystemVolumeProgressBar: View {
    let value: CGFloat
    let onChanged: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geometry in
            let progress = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.2))
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.58 + (progress * 0.42)),
                                Color.white.opacity(0.30 + (progress * 0.70)),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * progress)
                    .shadow(
                        color: .white.opacity(0.38 + (progress * 0.48)),
                        radius: 4 + (progress * 3)
                    )
                    .shadow(
                        color: .white.opacity(0.20 + (progress * 0.30)),
                        radius: 8 + (progress * 4)
                    )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard geometry.size.width > 0 else { return }
                        onChanged(min(max(gesture.location.x / geometry.size.width, 0), 1))
                    }
            )
        }
    }
}
