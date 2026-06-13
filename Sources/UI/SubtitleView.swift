import SwiftUI

/// 떠다니는 패널 안에 그려지는 자막바.
/// 확정 번역은 흰색으로 잠기고, 진행 중(volatile) 번역은 회색 꼬리로 덧붙는다.
struct SubtitleView: View {
    @EnvironmentObject var pipeline: SubtitlePipeline

    private var translationText: AttributedString {
        let confirmed = pipeline.confirmedTranslation
        let volatile = pipeline.volatileTranslation

        if confirmed.isEmpty && volatile.isEmpty {
            var placeholder = AttributedString(pipeline.isRunning ? "…" : "자막 대기 중")
            placeholder.foregroundColor = .white.opacity(0.5)
            return placeholder
        }

        var result = AttributedString(confirmed)
        result.foregroundColor = .white
        if !volatile.isEmpty {
            if !confirmed.isEmpty { result += AttributedString(" ") }
            var tail = AttributedString(volatile)
            tail.foregroundColor = .white.opacity(0.55)
            result += tail
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !pipeline.liveSource.isEmpty {
                Text(pipeline.liveSource)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .shadow(color: .black.opacity(0.9), radius: 2)
                    .shadow(color: .black.opacity(0.6), radius: 1)
            }

            Text(translationText)
                .font(.system(size: 28, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                // 배경 박스 없이 떠 있으므로, 어떤 영상 위에서도 읽히도록 그림자를 겹쳐 외곽선 효과.
                .shadow(color: .black.opacity(0.95), radius: 3)
                .shadow(color: .black.opacity(0.8), radius: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .padding(12)
    }
}
