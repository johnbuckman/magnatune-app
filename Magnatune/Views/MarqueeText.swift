import SwiftUI

/// One line of text that scrolls like a Times Square sign when it doesn't fit.
/// Text that fits sits still. Text that doesn't waits `startDelay`, scrolls right to left
/// until its end is in view, pauses `endPause`, jumps back to the start and repeats.
/// John, 2026-11-23 (to-do 10537243790): used for the song title and artist name in the
/// mini player and in Now Playing.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    /// Where the text sits when it fits (e.g. `.center` in Now Playing).
    var alignment: Alignment = .leading
    var startDelay: Double = 2
    var endPause: Double = 2
    /// Scroll speed in points per second.
    var speed: Double = 30

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - boxWidth) }

    var body: some View {
        // The hidden copy gives the view its one-line height and lets it fill the width.
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: alignment)
            .overlay(
                GeometryReader { box in
                    Text(text).font(font).lineLimit(1).fixedSize()
                        .background(GeometryReader { t in
                            Color.clear.preference(key: MarqueeWidthKey.self, value: t.size.width)
                        })
                        .offset(x: overflow > 0 ? offset : 0)
                        .frame(width: box.size.width, height: box.size.height,
                               alignment: overflow > 0 ? .leading : alignment)
                        .onAppear { boxWidth = box.size.width }
                        .onChange(of: box.size.width) { boxWidth = $0 }
                }
                .clipped()
            )
            .onPreferenceChange(MarqueeWidthKey.self) { textWidth = $0 }
            // Restart the cycle whenever the text or the space it has changes; the task is
            // cancelled when the view leaves the screen.
            .task(id: "\(text)|\(Int(textWidth))|\(Int(boxWidth))") { await run() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    private func run() async {
        reset()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
            let distance = overflow
            guard !Task.isCancelled, distance > 0 else { return }
            let duration = Double(distance) / speed
            withAnimation(.linear(duration: duration)) { offset = -distance }
            try? await Task.sleep(nanoseconds: UInt64((duration + endPause) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            reset()
        }
    }

    /// Jump back to the start without animating.
    private func reset() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { offset = 0 }
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
