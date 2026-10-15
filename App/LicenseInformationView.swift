import SwiftUI

/// All notices are local bundle resources; opening this sheet makes no network request.
struct LicenseInformationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Document.source
    private enum Document: String, CaseIterable, Identifiable {
        case source, dependencies, runtime, media, artwork
        var id: String { rawValue }
        var label: String {
            switch self {
            case .source: return "MIT 라이선스"
            case .dependencies: return "외부 구성요소"
            case .runtime: return "Whisper 고지"
            case .media: return "소재 출처"
            case .artwork: return "로고"
            }
        }
        var resource: String {
            switch self {
            case .source: return "Legal/LICENSE.txt"
            case .dependencies: return "Legal/THIRD_PARTY_NOTICES.md"
            case .runtime: return "Whisper/THIRD-PARTY-NOTICES.txt"
            case .media: return "Library/CREDITS.md"
            case .artwork: return "Legal/BRAND.md"
            }
        }
    }
    private var text: String? {
        guard let root = Bundle.main.resourceURL else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(selection.resource), encoding: .utf8)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("라이선스 및 소재 출처").font(.title2.bold())
            Text("Open source licenses & credits").foregroundStyle(.secondary)
            Text("앱 소스는 MIT, 내장 미디어는 각 소재의 CC0 고지를 따릅니다. 음성 인식 구성요소와 로고의 고지도 아래에서 확인할 수 있습니다.")
                .font(.callout)
            Picker("고지 선택", selection: $selection) {
                ForEach(Document.allCases) { item in Text(item.label).tag(item) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("license-document-picker")
            if let text {
                ScrollView {
                    Text(text).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("license-document-content")
            } else {
                ContentUnavailableView("고지 파일이 없습니다", systemImage: "doc.questionmark", description: Text("이 빌드에 고지 파일이 포함되지 않았습니다. 배포본을 확인하거나 앱을 다시 빌드하세요."))
            }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 760, height: 580)
    }
}
