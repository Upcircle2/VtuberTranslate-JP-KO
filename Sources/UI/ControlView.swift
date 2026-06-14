import SwiftUI
import Translation

/// 컨트롤 창: 음원 앱 선택, 언어 선택, 시작/중지.
struct ControlView: View {
    @EnvironmentObject var pipeline: SubtitlePipeline

    var body: some View {
        Form {
            Section("음원 앱") {
                Picker("앱 선택", selection: $pipeline.selectedAppID) {
                    Text("선택 안 함").tag(pid_t?.none)
                    ForEach(pipeline.availableApps, id: \.processID) { app in
                        Text(app.applicationName).tag(pid_t?.some(app.processID))
                    }
                }
                Button("앱 목록 새로고침") {
                    Task { await pipeline.refreshApps() }
                }
            }

            Section("언어") {
                Picker("음성 언어", selection: $pipeline.sourceLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .disabled(pipeline.isRunning)
                Picker("번역 언어", selection: $pipeline.targetLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .disabled(pipeline.isRunning)
                Toggle("대화체(반말)로 표시", isOn: $pipeline.casualizeKorean)
            }

            Section("고품질 번역 (DeepL)") {
                Toggle("DeepL 사용 — 확정 자막", isOn: $pipeline.useDeepL)
                if pipeline.useDeepL {
                    SecureField("DeepL API 키", text: $pipeline.deepLApiKey)
                        .textFieldStyle(.roundedBorder)
                    Text("확정(흰색) 자막만 DeepL로 번역하고, 진행 중(회색)은 온디바이스로 즉시 처리합니다. 키 없음·오류·오프라인이면 자동으로 온디바이스로 폴백합니다. 무료 키는 :fx로 끝나며 deepl.com/pro-api 에서 발급.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("음성인식") {
                LabeledContent("엔진", value: "Parakeet-ja (일본어)")
                Text("첫 사용 시 모델(수백 MB)을 내려받습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("멤버 이름 보정", isOn: $pipeline.nameBoosting)
                    .disabled(pipeline.isRunning)
                if pipeline.nameBoosting {
                    Text("홀로라이브·VSPO 멤버 이름을 한국어 정식 표기로 바꿉니다(예: 兎田ぺこら→우사다 페코라). STT 어휘 부스팅용 모델을 추가로 내려받습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(pipeline.isRunning ? "중지" : "시작") {
                    Task {
                        if pipeline.isRunning {
                            await pipeline.stop()
                        } else {
                            await pipeline.start()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pipeline.selectedAppID == nil)

                Text(pipeline.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .task {
            await pipeline.refreshApps()
            await pipeline.prepare()      // 음성 모델 사전 다운로드(콜드스타트 감소)
        }
        .translationTask(pipeline.translationConfig) { session in
            pipeline.attachTranslationSession(session)
            try? await session.prepareTranslation()
        }
    }
}
