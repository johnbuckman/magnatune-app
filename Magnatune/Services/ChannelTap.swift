import Foundation
import AVFoundation
import MediaToolbox
import CoreAudio

/// Which channel of a stereo track this device plays. `.left` / `.right` copy that one
/// channel to BOTH of this device's speakers, so two iPads side by side can act as the left
/// and right speakers of one stereo pair (see StereoPair.swift). `.normal` = untouched stereo.
enum ChannelMode: String, CaseIterable, Identifiable {
    case normal, left, right
    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: return "Stereo"
        case .left: return "Left only"
        case .right: return "Right only"
        }
    }
    var opposite: ChannelMode {
        switch self {
        case .left: return .right
        case .right: return .left
        case .normal: return .normal
        }
    }
    static let defaultsKey = "audio.channelMode"
}

/// Builds an AVAudioMix whose MTAudioProcessingTap duplicates one channel of a stereo item
/// into the other. Works on file and progressive-HTTP assets (all Magnatune audio); a mono
/// source passes through unchanged.
enum ChannelTap {
    /// Returns nil for `.normal` (no tap at all, so ordinary playback carries zero risk) or
    /// when the asset has no audio track / the tap can't be created.
    static func audioMix(for asset: AVAsset, mode: ChannelMode) async -> AVAudioMix? {
        guard mode != .normal,
              let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let ctx = TapContext(sourceChannel: mode == .left ? 0 : 1)
        let info = Unmanaged.passRetained(ctx).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: info,
            init: tapInit, finalize: tapFinalize, prepare: tapPrepare, unprepare: nil, process: tapProcess)
        var tap: MTAudioProcessingTap?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                             kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard err == noErr, let tap else {
            Unmanaged<TapContext>.fromOpaque(info).release()
            return nil
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

/// Per-tap state, owned by the tap (released in finalize). Written in prepare, read on the
/// real-time audio thread in process.
private final class TapContext {
    let sourceChannel: Int
    var channels = 0
    var interleaved = false
    var bytesPerSample = 4
    init(sourceChannel: Int) { self.sourceChannel = sourceChannel }
}

private func context(_ tap: MTAudioProcessingTap) -> TapContext {
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let ctx = context(tap)
    let f = format.pointee
    ctx.channels = Int(f.mChannelsPerFrame)
    ctx.interleaved = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
    ctx.bytesPerSample = max(1, Int(f.mBitsPerChannel) / 8)
}

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
    guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
    let ctx = context(tap)
    guard ctx.channels == 2 else { return }            // mono (or surround): leave as is
    let abl = UnsafeMutableAudioBufferListPointer(bufferList)
    let src = ctx.sourceChannel, dst = 1 - ctx.sourceChannel
    if !ctx.interleaved {
        guard abl.count >= 2, let s = abl[src].mData, let d = abl[dst].mData else { return }
        memcpy(d, s, Int(min(abl[src].mDataByteSize, abl[dst].mDataByteSize)))
    } else {
        guard abl.count >= 1, let base = abl[0].mData else { return }
        let bps = ctx.bytesPerSample
        let n = Int(framesOut.pointee)
        let p = base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<n {
            let frame = p + i * 2 * bps
            memcpy(frame + dst * bps, frame + src * bps, bps)
        }
    }
}
