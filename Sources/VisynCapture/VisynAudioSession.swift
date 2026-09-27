import AVFoundation

/// 两条路线共用的音频会话设置。
///
/// 采样缓冲路线只需要能播放；视频通话路线要让系统认作「通话进行中」，
/// 通常得用通话形态的会话，代价是会打断其它 App 的音频。
enum VisynAudioSession {
    static func activate(_ choice: VisynPictureInPictureAudioSession) throws {
        let session = AVAudioSession.sharedInstance()
        switch choice {
        case .playback:
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        case .videoCall:
            try session.setCategory(.playAndRecord, mode: .videoChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        }
        try session.setActive(true)
    }
}
