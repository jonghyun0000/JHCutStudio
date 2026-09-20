import SwiftUI
import AppKit
import JHCutCore
import ImageIO

struct LibraryBrowser: View {
    @ObservedObject var model: EditorModel
    let audioOnly: Bool
    @State private var query = ""
    @State private var category = "전체"
    @State private var selected: String?
    @State private var favoritesOnly = false
    @AppStorage("libraryFavoriteIDs") private var favoriteIDs = ""
    private var favorites: Set<String> { Set(favoriteIDs.split(separator: "|").map(String.init)) }
    private var categories: [String] { audioOnly ? ["전체", "효과음", "배경음"] : ["전체", "오버레이", "배경", "텍스처"] }
    private var filtered: [LibraryAsset] {
        (model.bundledLibrary?.assets ?? []).filter { asset in
            let isAudio = asset.category == .sfx || asset.category == .music
            let matchesCategory = category == "전체" || asset.category.korean == category
            let haystack = ([asset.name, asset.author] + asset.tags).joined(separator: " ")
            return isAudio == audioOnly && matchesCategory && (!favoritesOnly || favorites.contains(asset.id)) && (query.isEmpty || haystack.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(audioOnly ? "사운드 라이브러리" : "편집 소스 라이브러리").font(JH.Font.sectionTitle)
                Spacer()
                Text("\(filtered.count)").font(JH.Font.numeric(11)).foregroundStyle(.secondary)
            }.padding(.top, 14)
            TextField("이름·태그·제작자 검색", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("라이브러리 검색"))
            HStack {
                Picker("종류", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }.labelsHidden()
                Button { favoritesOnly.toggle() } label: { Image(systemName: favoritesOnly ? "star.fill" : "star") }
                    .buttonStyle(.jhTool)
                    .jhIconLabel(favoritesOnly ? "전체 보기" : "즐겨찾기만 보기")
            }
            if model.bundledLibrary == nil {
                Text("라이브러리를 찾을 수 없습니다. Resources/Library를 포함해 앱을 다시 빌드하세요.").font(.caption).foregroundStyle(JH.Palette.warning)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { asset in row(asset) }
                }
            }
            if let item = filtered.first(where: { $0.id == selected }) { details(item) }
            Text("로컬 파일 · 원본 출처와 사용 조건 확인 가능").font(JH.Font.micro).foregroundStyle(.secondary).padding(.bottom, 9)
        }.padding(.horizontal, 12)
            .onChange(of: audioOnly) { category = "전체"; selected = nil; model.stopAudition() }
            .onDisappear { model.stopAudition() }
    }
    private func row(_ asset: LibraryAsset) -> some View {
        HStack(spacing: 9) {
            if audioOnly {
                Button { model.audition(asset) } label: {
                    Image(systemName: model.auditionID == asset.id ? "stop.circle.fill" : "play.circle.fill").font(.system(size: 27)).foregroundStyle(JH.Palette.accent)
                }
                .buttonStyle(.plain).disabled(model.isExporting)
                .jhIconLabel(model.auditionID == asset.id ? "미리듣기 정지" : "\(asset.name) 미리듣기")
            } else if let url = model.bundledLibrary?.url(for: asset) {
                LibraryThumbnail(url: url).frame(width: 57, height: 47).background(.black.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: JH.Radius.chip - 2, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(asset.name).font(JH.Font.label.weight(.medium)).lineLimit(2)
                Text(subtitle(asset)).font(JH.Font.micro).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { selected = asset.id; model.insertLibraryAsset(asset) } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.plain)
                .jhIconLabel("\(asset.name) 추가", hint: "플레이헤드 위치에 추가합니다")
                .disabled(model.isExporting || model.isImporting)
        }.padding(9).background(selected == asset.id ? JH.Palette.accent.opacity(0.16) : Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: JH.Radius.chip, style: .continuous)).contentShape(Rectangle()).onTapGesture { selected = asset.id }
    }
    private func subtitle(_ asset: LibraryAsset) -> String {
        let time = asset.duration.map { String(format: "%.1f초 · ", $0) } ?? ""
        return time + asset.category.korean + " · " + asset.license
    }
    private func details(_ asset: LibraryAsset) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            HStack {
                Text(asset.name).font(JH.Font.label.weight(.semibold))
                Spacer()
                Button { var ids = favorites; if ids.contains(asset.id) { ids.remove(asset.id) } else { ids.insert(asset.id) }; favoriteIDs = ids.sorted().joined(separator: "|") } label: { Image(systemName: favorites.contains(asset.id) ? "star.fill" : "star") }
                    .buttonStyle(.plain)
                    .jhIconLabel(favorites.contains(asset.id) ? "즐겨찾기 해제" : "즐겨찾기 추가")
            }
            Text("\(asset.sourceLabel) · \(asset.author) · \(asset.license)").font(JH.Font.caption).foregroundStyle(.secondary)
            Text(asset.tags.joined(separator: " · ")).font(JH.Font.micro).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                if let url = URL(string: asset.sourceURL), url.scheme == "https" { Link("원본 출처", destination: url).font(.caption) }
                if let url = URL(string: asset.licenseURL), url.scheme == "https" { Link("사용 조건", destination: url).font(.caption) }
            }
            Button(audioOnly ? "현재 위치에 오디오 추가" : "현재 위치에 소스 추가") { model.insertLibraryAsset(asset) }.buttonStyle(.jhPrimary).disabled(model.isExporting || model.isImporting)
        }
    }
}

extension LibraryCategory {
    var korean: String {
        switch self { case .sfx: return "효과음"; case .music: return "배경음"; case .overlay: return "오버레이"; case .background: return "배경"; case .texture: return "텍스처" }
    }
}

struct LibraryThumbnail: View {
    let url: URL
    @State private var thumbnail: NSImage?
    var body: some View {
        Group { if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() } else { Image(systemName: "photo").foregroundStyle(.secondary) } }
            .task(id: url) {
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 280] as CFDictionary) {
                    thumbnail = NSImage(cgImage: image, size: .zero)
                }
            }
    }
}
