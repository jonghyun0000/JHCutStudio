import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import JHCutCore

struct TimelineSurface: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    @ObservedObject private var clock: PlaybackClock
    init(model: EditorModel) { self.model = model; self.clock = model.playbackClock }
    final class Coordinator {
        var observer: NSObjectProtocol?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        let canvas = TimelineCanvas(); canvas.model = model; scroll.documentView = canvas
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak model, weak scroll] _ in
            guard let y = scroll?.contentView.bounds.origin.y else { return }
            Task { @MainActor in if model?.timelineScrollY != y { model?.timelineScrollY = y } }
        }
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let canvas = view.documentView as? TimelineCanvas else { return }
        canvas.model = model
        let nextFrame = NSRect(x: 0, y: 0, width: max(view.contentSize.width, (model.project.sequence.duration.seconds + 8) * model.zoom), height: max(28 + CGFloat(model.project.sequence.tracks.count) * 51, view.contentSize.height))
        if canvas.frame != nextFrame { canvas.frame = nextFrame }
        if model.playing {
            let x = model.playhead * model.zoom, visible = view.contentView.bounds
            if x > visible.maxX - 30 || x < visible.minX {
                let next = max(0, min(canvas.frame.width - visible.width, x - visible.width * 0.2))
                view.contentView.scroll(to: NSPoint(x: next, y: visible.origin.y)); view.reflectScrolledClipView(view.contentView)
            }
        }
        canvas.loadThumbnails(); canvas.loadWaveforms(); canvas.needsDisplay = true
    }
}

@MainActor
final class TimelineCanvas: NSView {
    weak var model: EditorModel?
    private var thumbnails: [UUID: NSImage] = [:]
    private var loading: Set<UUID> = []
    private var thumbnailKeys: [UUID: String] = [:]
    private var thumbnailFailures: [UUID: String] = [:]
    private var thumbnailCheck = Date.distantPast
    private var dragClip: Clip?
    private var dragTrack: UUID?
    private var dragOrigin = NSPoint.zero
    private var dragMode = 0 // 0 move, 1 leading edge, 2 trailing edge
    private var drafts: [UUID: Clip] = [:]
    private var dragClips: [UUID: (trackID: UUID, clip: Clip)] = [:]
    private var hitClip = false
    private var snapGuide: MediaTime?
    private struct WaveformEntry { var key: String; var peaks: [Float] }
    private var waveforms: [UUID: WaveformEntry] = [:]
    private var waveformLoading: [UUID: String] = [:]
    private var waveformFailures: [UUID: String] = [:]
    private var waveformCheck = Date.distantPast
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private let laneHeight: CGFloat = 51
    private let rulerHeight: CGFloat = 28

    func loadThumbnails(force: Bool = false) {
        guard let model, force || Date().timeIntervalSince(thumbnailCheck) > 1 else { return }
        thumbnailCheck = Date()
        let used = Set(model.project.sequence.tracks.flatMap(\.clips).compactMap(\.assetID))
        thumbnails = thumbnails.filter { used.contains($0.key) }
        thumbnailKeys = thumbnailKeys.filter { used.contains($0.key) }
        thumbnailFailures = thumbnailFailures.filter { used.contains($0.key) }
        for asset in model.project.assets where used.contains(asset.id) && !loading.contains(asset.id) && asset.kind != .audio {
            guard loading.count < 2 else { break }
            let url = asset.resolvedURL(relativeTo: model.mediaBaseURL)
            let metadata = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let key = "\(url.standardizedFileURL.path)|\(metadata?.fileSize ?? -1)|\(metadata?.contentModificationDate?.timeIntervalSince1970 ?? -1)|180|v1"
            guard thumbnailKeys[asset.id] != key, thumbnailFailures[asset.id] != key else { continue }
            guard thumbnails[asset.id] != nil || thumbnails.count < 40 else { continue }
            thumbnails[asset.id] = nil; thumbnailKeys[asset.id] = nil
            loading.insert(asset.id)
            Task { [weak self] in
                var result: NSImage?
                if asset.kind == .image {
                    if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 180] as CFDictionary) {
                        result = NSImage(cgImage: image, size: .zero)
                    }
                } else {
                    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url)); gen.appliesPreferredTrackTransform = true; gen.maximumSize = CGSize(width: 150, height: 90)
                    if let value = try? await gen.image(at: .zero) { result = NSImage(cgImage: value.image, size: .zero) }
                }
                self?.thumbnails[asset.id] = result
                if result != nil { self?.thumbnailKeys[asset.id] = key; self?.thumbnailFailures[asset.id] = nil }
                else { self?.thumbnailFailures[asset.id] = key }
                self?.loading.remove(asset.id); self?.needsDisplay = true
                self?.loadThumbnails(force: true)
            }
        }
    }
    func loadWaveforms(force: Bool = false) {
        guard let model, force || Date().timeIntervalSince(waveformCheck) > 1 else { return }
        waveformCheck = Date()
        let used = Set(model.project.sequence.tracks.flatMap(\.clips).compactMap(\.assetID))
        waveforms = waveforms.filter { used.contains($0.key) }
        waveformFailures = waveformFailures.filter { used.contains($0.key) }
        for asset in model.project.assets where used.contains(asset.id) && (asset.kind == .audio || asset.hasAudio) {
            guard waveformLoading.count < 2 else { break }
            let url = asset.resolvedURL(relativeTo: model.mediaBaseURL)
            let metadata = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let key = "\(url.standardizedFileURL.path)|\(metadata?.fileSize ?? -1)|\(metadata?.contentModificationDate?.timeIntervalSince1970 ?? -1)|320|v1"
            guard waveformLoading[asset.id] == nil, waveforms[asset.id]?.key != key, waveformFailures[asset.id] != key else { continue }
            guard waveforms[asset.id] != nil || waveforms.count < 64 else { continue }
            waveforms[asset.id] = nil; waveformLoading[asset.id] = key
            Task { [weak self] in
                do {
                    let peaks = try await WaveformAnalyzer.analyze(url: url, bins: 320)
                    guard let self else { return }
                    self.waveforms[asset.id] = WaveformEntry(key: key, peaks: peaks)
                    self.waveformFailures[asset.id] = nil
                } catch {
                    self?.waveformFailures[asset.id] = key
                }
                self?.waveformLoading[asset.id] = nil
                self?.needsDisplay = true
                self?.loadWaveforms(force: true)
            }
        }
    }
    private func rect(for clip: Clip, lane: Int) -> NSRect {
        guard let model else { return .zero }
        return NSRect(x: clip.start.seconds * model.zoom, y: rulerHeight + CGFloat(lane) * laneHeight + 4, width: max(3, clip.duration.seconds * model.zoom), height: laneHeight - 8)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        // Canvas token, shared with the SwiftUI chrome so the timeline reads as one surface with it.
        NSColor(calibratedWhite: 0.055, alpha: 1).setFill(); dirtyRect.fill()
        let visible = visibleRect

        // Ruler band: a seam under it separates time from content without a hard divider.
        NSColor.white.withAlphaComponent(0.035).setFill()
        NSRect(x: visible.minX, y: 0, width: visible.width, height: rulerHeight).fill()
        NSColor.white.withAlphaComponent(0.09).setFill()
        NSRect(x: visible.minX, y: rulerHeight - 0.5, width: visible.width, height: 0.5).fill()

        let step = model.zoom > 90 ? 1 : model.zoom > 30 ? 2 : 5
        let first = max(0, Int(visible.minX / model.zoom) / step * step)
        let last = Int(visible.maxX / model.zoom) + step
        for second in stride(from: first, through: last, by: step) {
            let x = CGFloat(second) * model.zoom
            // Minute marks read stronger than second marks.
            let major = second % 60 == 0
            NSColor.white.withAlphaComponent(major ? 0.14 : 0.055).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: rulerHeight)); line.line(to: NSPoint(x: x, y: bounds.height))
            line.lineWidth = 0.5; line.stroke()
            NSColor.white.withAlphaComponent(major ? 0.3 : 0.16).setFill()
            NSRect(x: x, y: rulerHeight - (major ? 9 : 5), width: 0.5, height: major ? 9 : 5).fill()
            drawText(String(format: "%02d:%02d", second / 60, second % 60),
                     rect: NSRect(x: x + 5, y: 5, width: 60, height: 14), size: 9,
                     color: NSColor.white.withAlphaComponent(major ? 0.62 : 0.4))
        }

        for (index, track) in model.project.sequence.tracks.enumerated() {
            let laneTop = rulerHeight + CGFloat(index) * laneHeight
            // Alternating lane wash gives vertical rhythm without drawing a grid.
            if index % 2 == 1 {
                NSColor.white.withAlphaComponent(0.018).setFill()
                NSRect(x: visible.minX, y: laneTop, width: visible.width, height: laneHeight).fill()
            }
            let y = rulerHeight + CGFloat(index + 1) * laneHeight
            NSColor.white.withAlphaComponent(0.055).setFill()
            NSRect(x: visible.minX, y: y - 0.5, width: visible.width, height: 0.5).fill()

            for original in track.clips {
                let clip = drafts[original.id] ?? original
                let r = rect(for: clip, lane: index)
                guard r.intersects(visible) else { continue }
                let color = Self.trackColor(track.kind)
                let shape = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)

                // Vertical gradient plus a top highlight: the clip reads as a raised surface, matching
                // the way glass chrome above it catches light.
                let dim = track.isHidden ? 0.28 : 1.0
                let gradient = NSGradient(starting: color.blended(withFraction: 0.18, of: .white)?.withAlphaComponent(0.92 * dim) ?? color,
                                          ending: color.blended(withFraction: 0.22, of: .black)?.withAlphaComponent(0.92 * dim) ?? color)
                gradient?.draw(in: shape, angle: -90)
                NSColor.white.withAlphaComponent(0.16 * dim).setStroke()
                shape.lineWidth = 1; shape.stroke()

                NSGraphicsContext.saveGraphicsState(); shape.addClip()
                if let id = clip.assetID, let thumbnail = thumbnails[id] {
                    thumbnail.draw(in: NSRect(x: r.minX + 4, y: r.minY + 3, width: 48, height: 36), from: .zero, operation: .sourceOver, fraction: 0.65, respectFlipped: true, hints: nil)
                }
                if let id = clip.assetID, let waveform = waveforms[id], let asset = model.project.assets.first(where: { $0.id == id }) {
                    drawWaveform(waveform.peaks, clip: clip, sourceDuration: asset.duration.seconds, rect: r, dimmed: track.isMuted)
                }
                let inset: CGFloat = clip.assetID.flatMap { thumbnails[$0] } != nil ? 57 : 10
                drawText(clip.title?.text ?? clip.name, rect: NSRect(x: r.minX + inset, y: r.minY + 7, width: max(0, r.width - inset - 8), height: 16), size: 10, color: .white)
                drawText(String(format: "%.2f초%@", clip.duration.seconds, track.isMuted ? " · 음소거" : ""), rect: NSRect(x: r.minX + inset, y: r.minY + 25, width: max(0, r.width - inset - 8), height: 12), size: 8, color: .white.withAlphaComponent(0.65))
                NSGraphicsContext.restoreGraphicsState()
                if let id = clip.assetID, waveformFailures[id] != nil, track.kind == .audio {
                    drawText("파형 읽기 실패", rect: NSRect(x: r.maxX - 90, y: r.minY + 25, width: 84, height: 12), size: 8, color: .orange)
                }
                if model.selectedClipIDs.contains(clip.id) || model.selectedClipID == clip.id {
                    // Halo then crisp edge, so selection survives on both light and dark clip colours.
                    Self.accent.withAlphaComponent(0.35).setStroke(); shape.lineWidth = 4; shape.stroke()
                    Self.accent.setStroke(); shape.lineWidth = 1.5; shape.stroke()
                    Self.accent.withAlphaComponent(0.95).setFill()
                    NSBezierPath(roundedRect: NSRect(x: r.minX + 3, y: r.midY - 8, width: 2.5, height: 16), xRadius: 1.25, yRadius: 1.25).fill()
                    NSBezierPath(roundedRect: NSRect(x: r.maxX - 5.5, y: r.midY - 8, width: 2.5, height: 16), xRadius: 1.25, yRadius: 1.25).fill()
                }
            }
        }
        if let snapGuide {
            let x = snapGuide.seconds * model.zoom
            Self.accent.withAlphaComponent(0.8).setFill()
            NSRect(x: x - 0.5, y: rulerHeight, width: 1, height: bounds.height - rulerHeight).fill()
        }
        drawPlayhead(at: model.playhead * model.zoom)
    }

    static let accent = NSColor(calibratedRed: 0.36, green: 0.84, blue: 0.74, alpha: 1)
    static let playheadColor = NSColor(calibratedRed: 0.98, green: 0.41, blue: 0.35, alpha: 1)
    static func trackColor(_ kind: TrackKind) -> NSColor {
        switch kind {
        case .video: return NSColor(calibratedRed: 0.24, green: 0.52, blue: 0.78, alpha: 1)
        case .overlay: return NSColor(calibratedRed: 0.55, green: 0.42, blue: 0.82, alpha: 1)
        case .title: return NSColor(calibratedRed: 0.85, green: 0.60, blue: 0.24, alpha: 1)
        case .audio: return NSColor(calibratedRed: 0.20, green: 0.63, blue: 0.51, alpha: 1)
        }
    }

    /// A capsule head on the ruler with a hairline stem, rather than a triangle on a 1.5pt bar.
    private func drawPlayhead(at x: CGFloat) {
        Self.playheadColor.withAlphaComponent(0.28).setFill()
        NSRect(x: x - 1.5, y: rulerHeight, width: 3, height: bounds.height - rulerHeight).fill()
        Self.playheadColor.setFill()
        NSRect(x: x - 0.5, y: rulerHeight, width: 1, height: bounds.height - rulerHeight).fill()
        let head = NSBezierPath(roundedRect: NSRect(x: x - 7, y: 4, width: 14, height: rulerHeight - 9), xRadius: 4, yRadius: 4)
        head.fill()
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSRect(x: x - 0.5, y: 9, width: 1, height: rulerHeight - 19).fill()
    }
    private func drawText(_ text: String, rect: NSRect, size: CGFloat, color: NSColor) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium), .foregroundColor: color, .paragraphStyle: style])
    }
    private func drawWaveform(_ peaks: [Float], clip: Clip, sourceDuration: Double, rect: NSRect, dimmed: Bool) {
        guard let model, !peaks.isEmpty, sourceDuration > 0, rect.width > 2 else { return }
        let area = rect.intersection(visibleRect)
        guard !area.isEmpty else { return }
        let rate = clip.playbackRate?.multiplier ?? 1
        let middle = rect.maxY - 10.5
        NSColor.white.withAlphaComponent(dimmed ? 0.11 : 0.27).setStroke()
        let waveform = NSBezierPath(); waveform.lineWidth = 1
        for x in stride(from: area.minX + 1, to: area.maxX, by: 2) {
            let localTime = max(0, min(clip.duration.seconds, (x - rect.minX) / model.zoom))
            let sourceStart = clip.sourceStart.seconds + localTime * rate
            let sourceEnd = sourceStart + 2 / model.zoom * rate
            let low = max(0, min(peaks.count - 1, Int(sourceStart / sourceDuration * Double(peaks.count))))
            let high = max(low, min(peaks.count - 1, Int(sourceEnd / sourceDuration * Double(peaks.count))))
            let peak = Double(peaks[low...high].max() ?? 0)
            var volume = clip.evaluatedVolume(at: MediaTime(seconds: localTime))
            if let fade = clip.audioFadeIn, fade > .zero { volume *= min(1, localTime / fade.seconds) }
            if let fade = clip.audioFadeOut, fade > .zero { volume *= min(1, (clip.duration.seconds - localTime) / fade.seconds) }
            let height = min(1, max(0, peak * volume)) * 8
            waveform.move(to: NSPoint(x: x, y: middle - height)); waveform.line(to: NSPoint(x: x, y: middle + height))
        }
        waveform.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        guard let model, !model.isExporting else { return }
        window?.makeFirstResponder(self)
        dragClip = nil; dragTrack = nil; dragClips = [:]; drafts = [:]; hitClip = false; snapGuide = nil
        let point = convert(event.locationInWindow, from: nil); dragOrigin = point
        for (index, track) in model.project.sequence.tracks.enumerated() {
            for clip in track.clips.reversed() {
                let r = rect(for: clip, lane: index)
                if r.contains(point) {
                    hitClip = true
                    if event.modifierFlags.contains(.command) { model.selectClip(clip.id, extend: true) }
                    else if !model.selectedClipIDs.contains(clip.id) { model.selectClip(clip.id) }
                    else { model.selectedClipID = clip.id }
                    guard model.selectedClipIDs.contains(clip.id) else { needsDisplay = true; return }
                    dragMode = point.x - r.minX < 7 ? 1 : r.maxX - point.x < 7 ? 2 : 0
                    let selectedIDs = dragMode == 0 ? model.selectedClipIDs : [clip.id]
                    for candidateTrack in model.project.sequence.tracks {
                        for candidate in candidateTrack.clips where selectedIDs.contains(candidate.id) {
                            guard !candidateTrack.isLocked else {
                                dragClips = [:]; model.error = "선택한 클립 중 잠긴 트랙의 항목이 있습니다. 잠금을 해제한 뒤 이동하세요."
                                needsDisplay = true; return
                            }
                            dragClips[candidate.id] = (candidateTrack.id, candidate)
                        }
                    }
                    dragClip = clip; dragTrack = track.id; drafts = dragClips.mapValues { $0.clip }
                    needsDisplay = true; return
                }
            }
        }
        if !event.modifierFlags.contains(.command) { model.selectedClipID = nil; model.selectedClipIDs = [] }
        model.seek(point.x / model.zoom)
    }
    private func frameTime(_ seconds: Double) -> MediaTime {
        guard let rate = model?.project.sequence.frameRate else { return MediaTime(seconds: seconds) }
        let fps = Double(rate.numerator) / Double(rate.denominator)
        return rate.time(forFrame: Int64((seconds * fps).rounded()))
    }
    private func snappedDelta(_ delta: MediaTime, edges: [MediaTime], excluding: Set<UUID>) -> MediaTime {
        snapGuide = nil
        guard let model, model.snappingEnabled else { return delta }
        let targets = [MediaTime.zero, frameTime(model.playhead)] + model.project.sequence.tracks.flatMap(\.clips).filter { !excluding.contains($0.id) }.flatMap { [$0.start, $0.end] }
        var distance = 8.0 / model.zoom
        var result = delta
        for edge in edges {
            for target in targets {
                let candidateDistance = abs((edge + delta - target).seconds)
                if candidateDistance < distance {
                    distance = candidateDistance
                    result = target - edge
                    snapGuide = target
                }
            }
        }
        return result
    }
    override func mouseDragged(with event: NSEvent) {
        guard let model, !model.isExporting else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let clip = dragClip else { if !hitClip { model.seek(point.x / model.zoom) }; return }
        let delta = frameTime((point.x - dragOrigin.x) / model.zoom)
        let frame = model.project.sequence.frameRate.time(forFrame: 1)
        if dragMode == 0 {
            let moving = dragClips.values.map(\.clip)
            let snapped = snappedDelta(delta, edges: moving.flatMap { [$0.start, $0.end] }, excluding: Set(dragClips.keys))
            let minimumStart = moving.map(\.start).min() ?? .zero
            let allowed = max(.zero - minimumStart, snapped)
            if allowed != snapped { snapGuide = nil }
            drafts = dragClips.mapValues { item in var value = item.clip; value.start = value.start + allowed; return value }
        } else {
            var value = clip
            let rate = clip.playbackRate ?? PlaybackRate()
            let asset = clip.assetID.flatMap { id in model.project.assets.first { $0.id == id } }
            let temporal = asset?.kind != .image && clip.title == nil
            if dragMode == 1 {
                let snapped = snappedDelta(delta, edges: [clip.start], excluding: [clip.id])
                let sourceRoom = temporal ? rate.timelineDuration(for: clip.sourceStart) : clip.start
                let lower = max(.zero - sourceRoom, .zero - clip.start)
                let shift = max(lower, min(snapped, clip.duration - frame))
                if shift != snapped { snapGuide = nil }
                value.start = clip.start + shift
                value.sourceStart = temporal ? clip.sourceStart + rate.sourceDuration(for: shift) : .zero
                value.duration = clip.duration - shift
            } else {
                let snapped = snappedDelta(delta, edges: [clip.end], excluding: [clip.id])
                let maxDuration = temporal ? rate.timelineDuration(for: (asset?.duration ?? clip.sourceDuration) - clip.sourceStart) : MediaTime(86_400, 1)
                value.duration = min(maxDuration, max(frame, clip.duration + snapped))
                if value.duration != clip.duration + snapped { snapGuide = nil }
            }
            drafts = [clip.id: value]
        }
        needsDisplay = true; autoscroll(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        if let model {
            let commands: [EditCommand] = dragClips.values.compactMap { item in
                guard let draft = drafts[item.clip.id], draft != item.clip else { return nil }
                if dragMode != 0 {
                    return .trimClip(trackID: item.trackID, clipID: item.clip.id, newStart: draft.start, newSourceStart: draft.sourceStart, newDuration: draft.duration)
                }
                return .updateClip(trackID: item.trackID, clip: draft)
            }
            if !commands.isEmpty { model.perform(.batch(commands)) }
        }
        dragClip = nil; dragTrack = nil; dragClips = [:]; drafts = [:]; hitClip = false; snapGuide = nil; needsDisplay = true
    }
}
