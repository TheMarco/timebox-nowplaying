import Foundation
import AppKit
import ImageIO

struct NowPlayingInfo {
    var title: String? = nil
    var artist: String? = nil
    var artwork: CGImage? = nil
}

/// Current "now playing" info. Tries the private MediaRemote framework first
/// (fast, any player) and falls back to Music.app via AppleScript when
/// MediaRemote is gated (macOS ~15.4+). Completion is delivered on the main thread.
enum NowPlaying {
    private static let mediaRemote = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW
    )

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void

    static var isAvailable: Bool { true } // MediaRemote and/or Music.app fallback

    static func fetch(_ completion: @escaping (NowPlayingInfo) -> Void) {
        fetchMediaRemote { mediaRemoteInfo in
            if mediaRemoteInfo.artwork != nil {
                completion(mediaRemoteInfo)
                return
            }
            MusicNowPlaying.fetch { musicInfo in
                if musicInfo.title != nil || musicInfo.artwork != nil {
                    completion(musicInfo)
                } else {
                    completion(mediaRemoteInfo)
                }
            }
        }
    }

    private static func fetchMediaRemote(_ completion: @escaping (NowPlayingInfo) -> Void) {
        guard let mediaRemote, let symbol = dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingInfo") else {
            completion(NowPlayingInfo())
            return
        }
        let getInfo = unsafeBitCast(symbol, to: GetInfoFn.self)
        getInfo(DispatchQueue.main) { dict in
            var info = NowPlayingInfo()
            info.title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String
            info.artist = dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String
            if let data = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
               let image = NSImage(data: data),
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                info.artwork = cgImage
            }
            completion(info)
        }
    }

    /// Fallback artwork when the player exposes no embedded art (e.g. Apple Music
    /// streaming): look the track up on the iTunes Search API by "artist title".
    static func iTunesArtwork(title: String?, artist: String?) async -> CGImage? {
        let term = [artist, title].compactMap { $0 }.joined(separator: " ")
        guard !term.isEmpty,
              let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(q)&entity=song&limit=1")
        else { return nil }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let art = results.first?["artworkUrl100"] as? String else { return nil }

        // Ask for a bigger image than the 100px thumbnail the API returns by default.
        let big = art.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        guard let imgURL = URL(string: big),
              let (imgData, _) = try? await URLSession.shared.data(from: imgURL),
              let src = CGImageSourceCreateWithData(imgData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return cgImage
    }
}

/// Reads the current track + album artwork from Music.app via AppleScript.
/// Requires the Automation permission ("control Music"), prompted on first use.
enum MusicNowPlaying {
    private static let artworkPath = NSTemporaryDirectory() + "timebox_music_artwork.dat"

    static func fetch(_ completion: @escaping (NowPlayingInfo) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let info = fetchSync()
            DispatchQueue.main.async { completion(info) }
        }
    }

    private static func fetchSync() -> NowPlayingInfo {
        // Don't launch Music if it isn't already running.
        let musicRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.apple.Music" }
        guard musicRunning else { return NowPlayingInfo() }

        try? FileManager.default.removeItem(atPath: artworkPath)

        let source = """
        tell application "Music"
            set ps to (player state as text)
            if ps is "stopped" then return {"", "", "no"}
            set trackName to (name of current track)
            set trackArtist to (artist of current track)
            try
                set rawArt to (raw data of artwork 1 of current track)
                set f to open for access (POSIX file "\(artworkPath)") with write permission
                set eof f to 0
                write rawArt to f
                close access f
            end try
            return {trackName, trackArtist, "yes"}
        end tell
        """

        guard let script = NSAppleScript(source: source) else { return NowPlayingInfo() }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return NowPlayingInfo() }

        var info = NowPlayingInfo()
        if result.numberOfItems >= 3 {
            info.title = result.atIndex(1)?.stringValue
            info.artist = result.atIndex(2)?.stringValue
            let playing = (result.atIndex(3)?.stringValue == "yes")
            if playing,
               let data = FileManager.default.contents(atPath: artworkPath),
               let image = NSImage(data: data),
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                info.artwork = cgImage
            }
        }
        return info
    }
}
