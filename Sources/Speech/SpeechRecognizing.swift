import AVFAudio
import CoreMedia

/// 인식기가 내보내는 한 번의 전사 갱신.
/// `text`는 누적 전체(확정 prefix + 진행 중 volatile 꼬리)이고,
/// `confirmedCharCount`는 그중 앞쪽 '확정된'(더 이상 바뀌지 않는) 글자 수다.
/// 이 분리가 flicker 제거와 confirmed-prefix 증분 번역의 토대가 된다.
struct TranscriptionUpdate: Sendable {
    let text: String
    let confirmedCharCount: Int
    var confidence: Double = 1.0      // 평균 인식 신뢰도(환각 필터용). 미지원 엔진은 1.0.
}

/// 음성 인식 엔진 추상화. 지금은 Apple 온디바이스 구현만 있지만,
/// 나중에 클라우드/스트리밍 엔진 구현체로 교체할 수 있도록 프로토콜로 둔다.
protocol SpeechRecognizing: AnyObject {
    /// 전사가 갱신될 때마다 호출된다. 임의 스레드에서 호출될 수 있다.
    var onUpdate: ((TranscriptionUpdate) -> Void)? { get set }

    /// 모델 다운로드 진행률(0~1)을 알린다. 임의 스레드에서 호출될 수 있다.
    /// 다운로드를 진행률 보고하는 엔진만 호출한다.
    var onDownloadProgress: ((Double) -> Void)? { get set }

    /// 모델을 미리 내려받아 콜드스타트를 줄인다(가능한 엔진만). 실패해도 조용히 무시.
    func prewarm(locale: Locale) async

    /// 주어진 언어로 인식을 시작한다. 필요하면 모델을 내려받는다.
    func start(locale: Locale) async throws

    /// 캡처된 오디오 버퍼를 PTS와 함께 엔진에 밀어 넣는다. 임의 스레드에서 호출 가능.
    func append(_ buffer: AVAudioPCMBuffer, at time: CMTime)

    func stop() async
}
