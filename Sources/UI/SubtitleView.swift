import SwiftUI

/// 떠다니는 패널 안에 그려지는 롤링 자막바.
/// 끝난 발화는 위로 쌓이며 흐려지고(이전 문장), 현재 발화는 아래에 또렷하게 표시된다.
/// 새 발화가 들어오면 위로 스크롤되듯 올라간다(CGV 시상식 실시간자막 스타일).
struct SubtitleView: View {
    @EnvironmentObject var pipeline: SubtitlePipeline

    /// 현재(진행 중) 줄 = 확정 부분 + 진행 중 꼬리. 둘 다 또렷한 흰색.
    private var currentLine: String {
        let c = pipeline.confirmedTranslation
        let v = pipeline.volatileTranslation
        if c.isEmpty { return v }
        if v.isEmpty { return c }
        return c + " " + v
    }

    /// 위에 보여줄 이전 문장들(최근 3개). 오래될수록 위로.
    private var recentHistory: [HistoryLine] {
        Array(pipeline.history.suffix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // 이전 문장들(흐리게)
            ForEach(recentHistory) { line in
                Text(line.text)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            }

            // 현재 발화의 원문(작은 일본어)
            if !pipeline.liveSource.isEmpty {
                Text(pipeline.liveSource)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            // 현재 문장(또렷)
            if !currentLine.isEmpty {
                Text(currentLine)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            } else if pipeline.history.isEmpty {
                Text(pipeline.isRunning ? "…" : "자막 대기 중")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        // 아래 정렬: 내용이 적으면 바닥에 붙고, 쌓이면 위로 자라며 오래된 줄이 위로 밀려난다.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .padding(12)
        .animation(.easeOut(duration: 0.25), value: pipeline.history)   // 스크롤하듯 부드럽게
    }
}
