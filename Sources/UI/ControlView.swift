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

            Section("음성인식 엔진") {
                Picker("엔진", selection: $pipeline.sttEngine) {
                    ForEach(STTEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.inline)
                .disabled(pipeline.isRunning)
                if pipeline.sttEngine.needsDownload {
                    Text("첫 사용 시 모델(수백 MB)을 내려받습니다. 일본어 권장.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if pipeline.sttEngine == .fluidParakeetJa {
                    Toggle("멤버 이름 부스팅 (실험)", isOn: $pipeline.nameBoosting)
                        .disabled(pipeline.isRunning)
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
