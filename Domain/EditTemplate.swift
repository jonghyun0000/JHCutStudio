import Foundation
public enum EditTemplate {
    public enum Kind: String, CaseIterable { case social = "숏폼 광고 · 시작/핵심/행동 안내", interview = "인터뷰 · 이름/주제/마무리", story = "스토리 · 장 제목/인용/엔드카드" }
    public static func track(kind: Kind, sequence: Sequence) throws -> Track {
        guard sequence.duration >= MediaTime(6,1) else { throw ProjectError("템플릿을 적용하려면 6초 이상 영상을 먼저 배치하세요.") }
        let presets: [String]
        switch kind { case .social: presets = ["headline","number","action"]; case .interview: presets = ["interview-name","location","closing"]; case .story: presets = ["chapter","quote","end-card"] }
        let length = min(3.0,sequence.duration.seconds/3)
        let starts = [0.0,max(length,(sequence.duration.seconds-length)/2),sequence.duration.seconds-length]
        var clips: [Clip] = []
        for (index,id) in presets.enumerated() {
            guard let preset = TitlePreset.builtIns.first(where: { $0.id == id }) else { continue }
            let title = TitleSizing.title(for: preset, width: sequence.width, height: sequence.height)
            var clip = Clip(name: preset.name, start: MediaTime(seconds: starts[index]), duration: MediaTime(seconds: length), title: title)
            clip.fadeIn = MediaTime(seconds:0.25); clip.fadeOut=MediaTime(seconds:0.25)
            clip.keyframes=[TransformKeyframe(time:.zero,transform:ClipTransform(y:-Double(sequence.height)*0.015)),TransformKeyframe(time:MediaTime(seconds:0.35),transform:ClipTransform())]
            clips.append(clip)
        }
        return Track(name:kind.rawValue,kind:.title,clips:clips)
    }
}
