import SwiftUI
import Combine
import MusicKit
import MediaPlayer
import AVFoundation
import WidgetKit

/// Main service class that handles all music playback functionality.
/// Uses ApplicationMusicPlayer from MusicKit with a custom queue management layer
/// to support shuffle, filters, and efficient handling of large libraries (6000+ songs).
@MainActor
class MusicPlayerService: ObservableObject {
    
    private var nextCount: Int = 0
    
    static let shared = MusicPlayerService()

    @Published var results: [RSSong] = []
    @Published var nowPlaying: RSSong? = nil
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 200
    @Published var currentIndex: Int = 0
    @Published var playOrder: [Int] = []
    @Published var orderPos: Int = 0
    @Published var isAirPlayActive: Bool = false
    
    @Published var isShuffleEnabled: Bool = false
    @Published var repeatMode: MusicKit.MusicPlayer.RepeatMode = .none
    @Published var isArtistFilterEnabled: Bool = false
    @Published var isAlbumFilterEnabled: Bool = false
    
    // MARK: - Private Properties
    private var playerStateCancellable: AnyCancellable?
    private var queueEntryCancellable: AnyCancellable?
    private var playbackTimeCancellable: AnyCancellable?
    
    private let refillBatchSize = 75
    private let queueThreshold = 20
    private var isLoadingMoreSongs = false
    
    private var fullLibrary: [RSSong] = []
    private var isUserChangingSong = false
    private var isSeekInProgress = false
    private var lastSeekTime: Date? = nil
    
    private var contextBeforeArtistFilter: [RSSong] = []
    private var contextBeforeAlbumFilter: [RSSong] = []
    private var currentContext: [RSSong] = []
    private var shuffledContext: [RSSong] = []
    
    private var lastPublishedTime: Double = 0
    private var lastPublishedPlayingState: Bool = false
    private var lastPublishedSongID: UUID? = nil
    
    private var songIndexByMusicItemID: [MusicItemID: Int] = [:]
    private var songIndexByTitleArtist: [String: Int] = [:]

    // MARK: - Inicialization
    /// Private initializer that sets up all observers for player state, queue changes, and AirPlay.
    private init() {
        observePlayerState()
        observeQueueChanges()
        startAirPlayObserver()
    }
    
    // MARK: - Pemissions and Loading
    
    /// Initializes the service by requesting music authorization.
    func initialize() async {
        await requestMusicAuthorization()
    }

    /// Requests permission to access the user's music library.
    func requestMusicAuthorization() async {
        let status = await MusicAuthorization.request()
        #if DEBUG
        if status != .authorized { print("⚠️ No authorized") }
        #endif
    }

    /// Loads the user's entire music library into results and fullLibrary.
    /// Builds search indices for O(1) lookup and initializes the queue with shuffle enabled.
    func loadUserLibraryIntoResults(limit: Int? = nil) async {
        let status = await MusicAuthorization.currentStatus
        if status != .authorized {
            _ = await MusicAuthorization.request()
        }

        do {
            #if DEBUG
            print("🔄 Loading full library...")
            #endif
            
            var request = MusicLibraryRequest<Song>()
            if let limit = limit { request.limit = limit }
            
            let response = try await request.response()
            let items = response.items

            guard !items.isEmpty else { return }

            let mapped: [RSSong] = items.map { song in
                RSSong(
                    title: song.title,
                    artist: song.artistName,
                    album: song.albumTitle ?? "Unknown Album",
                    cover: "",
                    musicItemID: song.id,
                    librarySong: song
                )
            }

            results = mapped
            fullLibrary = mapped
            currentContext = mapped
            
            buildSearchIndices(from: mapped)
            
            playOrder = Array(0..<mapped.count)
            orderPos = 0
            
            if let randomSong = mapped.randomElement() {
                nowPlaying = randomSong
                lastPublishedSongID = randomSong.id
                if let songDuration = randomSong.librarySong?.duration {
                    self.duration = songDuration
                }
            }
            

            currentIndex = 0
            isPlaying = false
            lastPublishedPlayingState = false
            currentTime = 0
            lastPublishedTime = 0
            
            populateFullQueue()
            toggleShuffle()
            
            #if DEBUG
            print("✅ Syccessfully loaded library, \(playOrder.count)")
            #endif

        } catch {
            #if DEBUG
            print("❌ Error Loading library:", error)
            #endif
        }
    }
    
    /// Builds two dictionaries for O(1) song lookup:
    /// - songIndexByMusicItemID: lookup by MusicKit ID
    /// - songIndexByTitleArtist: lookup by "title|artist|album" key (handles same song in different albums)
    private func buildSearchIndices(from songs: [RSSong]) {
        songIndexByMusicItemID = [:]
        songIndexByTitleArtist = [:]
        
        for (index, song) in songs.enumerated() {
            if let musicID = song.musicItemID {
                songIndexByMusicItemID[musicID] = index
            }
            // Incluir álbum en la clave para diferenciar versiones
            let key = "\(song.title.lowercased())|\(song.artist.lowercased())|\(song.album.lowercased())"
            songIndexByTitleArtist[key] = index
        }
    }

    // MARK: - Populate queue
    
    /// Populates the initial queue with the first batch of songs from playOrder.
    /// Used during initial load.
    private func populateFullQueue() {
        let appPlayer = ApplicationMusicPlayer.shared
        guard !playOrder.isEmpty else { return }
        
        let startPos = orderPos
        let endPos = min(startPos + refillBatchSize, playOrder.count)
        let batchIndices = Array(playOrder[startPos..<endPos])
        let songsInBatch = batchIndices.compactMap { idx -> Song? in
            results[idx].librarySong
        }
        
        guard !songsInBatch.isEmpty else { return }
        appPlayer.queue = ApplicationMusicPlayer.Queue(for: songsInBatch, startingAt: songsInBatch.first)
    }

    // MARK: - Observer state of player
    
    /// Observes changes in ApplicationMusicPlayer state (play/pause/stop).
    /// Updates isPlaying flag and triggers syncCurrentSong when state changes.
    private func observePlayerState() {
        let appPlayer = ApplicationMusicPlayer.shared

        playerStateCancellable = appPlayer.state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                
                let state = appPlayer.state
                let newIsPlaying = (state.playbackStatus == .playing)
                
                if self.lastPublishedPlayingState != newIsPlaying {
                    self.isPlaying = newIsPlaying
                    self.lastPublishedPlayingState = newIsPlaying
                    self.onPlayingStateChanged()
                }
                
                self.syncCurrentSong()
            }
    }

    /// Observes changes in the player queue (song advancement).
    /// Uses debounce to avoid excessive updates when queue changes rapidly.
    private func observeQueueChanges() {
        let appPlayer = ApplicationMusicPlayer.shared
        
        queueEntryCancellable = appPlayer.queue.objectWillChange
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncCurrentSong()
            }
    }
    
    /// Synchronizes the nowPlaying state with the actual current song in ApplicationMusicPlayer.
    /// Uses O(1) lookup via songIndexByMusicItemID, with fallback to title+artist+album search.
    /// Also triggers queue refill check after sync.
    private func syncCurrentSong() {
        guard !isUserChangingSong else { return }
        
        let appPlayer = ApplicationMusicPlayer.shared
        
        guard let entry = appPlayer.queue.currentEntry,
              let item = entry.item,
              case .song(let s) = item else {
            return
        }
        
        // Search O(1)
        var foundIndex: Int? = songIndexByMusicItemID[s.id]
        
        if foundIndex == nil {
            let albumTitle = s.albumTitle ?? ""
            let key = "\(s.title.lowercased())|\(s.artistName.lowercased())|\(albumTitle.lowercased())"
            foundIndex = songIndexByTitleArtist[key]
        }
        
        let finalSong: RSSong
        
        if let idx = foundIndex, idx < results.count {
            finalSong = results[idx]
            if currentIndex != idx {
                currentIndex = idx
            }
        } else {
            finalSong = RSSong(
                title: s.title,
                artist: s.artistName,
                album: s.albumTitle ?? "Unknown Album",
                cover: "",
                musicItemID: s.id,
                librarySong: s
            )
        }
        
        // update dauration
        if let staticDuration = finalSong.librarySong?.duration {
            if abs(duration - staticDuration) > 0.1 {
                duration = staticDuration
            }
        } else if let playerDuration = s.duration {
            if abs(duration - playerDuration) > 0.1 {
                duration = playerDuration
            }
        }
        
        // Publish if changed
        if lastPublishedSongID != finalSong.id || nowPlaying?.title != finalSong.title {
            nowPlaying = finalSong
            lastPublishedSongID = finalSong.id
        }
        
        checkAndRefillQueue()
    }
    
    // MARK: - Control Timer based state of playback
    /// Called when playing state changes. Starts or stops the playback time observer accordingly.
    private func onPlayingStateChanged() {
        if isPlaying {
            startPlaybackTimeObserver()
        } else {
            stopPlaybackTimeObserver()
        }
    }
    
    /// Stops the timer that updates currentTime.
    private func stopPlaybackTimeObserver() {
        playbackTimeCancellable?.cancel()
        playbackTimeCancellable = nil
    }
    
    /// Starts a timer that updates currentTime every 0.75 seconds while playing.
    /// Only runs when isPlaying is true to save resources.
    private func startPlaybackTimeObserver() {
        playbackTimeCancellable?.cancel()
        playbackTimeCancellable = nil
        
        guard isPlaying else { return }
        
        playbackTimeCancellable = Timer
            .publish(every: 0.75, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updatePlaybackTime()
            }
    }

    /// Seeks to a specific time in the current song.
    /// Temporarily sets isSeekInProgress to prevent time observer conflicts.
    func seek(to time: TimeInterval) {
        guard time.isFinite, time >= 0, time <= duration else { return }
        
        isSeekInProgress = true
        
        let appPlayer = ApplicationMusicPlayer.shared
        appPlayer.playbackTime = time
        currentTime = time
        lastSeekTime = Date()
        
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            
            let realTime = appPlayer.playbackTime
            currentTime = realTime
            lastPublishedTime = realTime
            isSeekInProgress = false
        }
    }

    /// Updates currentTime from the player and handles repeat modes near song end.
    /// Called by the playback time observer timer.
    private func updatePlaybackTime() {
        guard isPlaying, !isUserChangingSong, !isSeekInProgress else { return }
        
        let current = ApplicationMusicPlayer.shared.playbackTime
        
        guard duration > 0 else { return }
        
        // Repeat modes only close the final
        if current >= (duration - 1.5) {
            if repeatMode == .one {
                Task { await handleRepeatOne(appPlayer: ApplicationMusicPlayer.shared) }
                return
            }
            
            if repeatMode == .all {
                handleRepeatAll()
                return
            }
        }
        
        // update if change more than  0.5 segundos
        if abs(lastPublishedTime - current) >= 0.5 {
            currentTime = current
            lastPublishedTime = current
        }
    }

    
    /// Checks if the queue needs more songs and adds them if necessary.
    ///
    /// For small contexts (≤100 songs): No refill needed, everything is already loaded.
    /// For large contexts (>100 songs): Adds next batch when remaining songs < threshold.
    ///
    /// Handles repeat mode: only wraps to beginning if repeatMode == .all
    private func checkAndRefillQueue() {
        guard !isLoadingMoreSongs else { return }
        
        let player = ApplicationMusicPlayer.shared
        let queue = player.queue
        
        guard let currentEntry = queue.currentEntry, !queue.entries.isEmpty else { return }
        guard let indexInQueue = queue.entries.firstIndex(of: currentEntry) else { return }
        
        let songsRemaining = queue.entries.count - (indexInQueue + 1)
        
        /// If enough songs remain, do nothing
        if songsRemaining > queueThreshold { return }
        
        /// Determine source list
        var sourceList = isShuffleEnabled ? shuffledContext : currentContext
        if sourceList.isEmpty {
            sourceList = fullLibrary
        }
        
        guard !sourceList.isEmpty else { return }
        
        /// CASE 1: Small context (album, filtered artist, small search)
        /// Everything is already loaded, no refill needed
        /// Repeat is handled in handleRepeatAll
        if sourceList.count <= 100 {
            #if DEBUG
            print("⏹ Small context (\(sourceList.count)), no refill. Repeat: \(repeatMode)")
            #endif
            return
        }
        
        /// CASE 2: Large context - needs refill
        isLoadingMoreSongs = true
        
        Task(priority: .background) {
            defer { isLoadingMoreSongs = false }
            
            guard let lastEntry = queue.entries.last,
                  let lastItem = lastEntry.item,
                  case .song(let lastSong) = lastItem else { return }
            
            /// Find the last song in context by MusicItemID
            var indexInContext = sourceList.firstIndex(where: { $0.musicItemID == lastSong.id })
            
            /// Fallback: search by title + artist + album
            if indexInContext == nil {
                let searchTitle = lastSong.title.lowercased()
                let searchArtist = lastSong.artistName.lowercased()
                let searchAlbum = (lastSong.albumTitle ?? "").lowercased()
                indexInContext = sourceList.firstIndex(where: {
                    $0.title.lowercased() == searchTitle &&
                    $0.artist.lowercased() == searchArtist &&
                    $0.album.lowercased() == searchAlbum
                })
            }
            
            guard let foundIndex = indexInContext else {
                #if DEBUG
                print("⚠️ Song '\(lastSong.title)' not found in large context")
                #endif
                return
            }
            
            let start = foundIndex + 1
            
            /// If we reached the end of the large context
            if start >= sourceList.count {
                guard repeatMode == .all else {
                    #if DEBUG
                    print("⏹ End of large context, repeat disabled")
                    #endif
                    return
                }
                
                /// Repeat all: wrap to beginning
                let end = min(refillBatchSize, sourceList.count)
                let songsToAdd = sourceList[0..<end]
                let musicKitSongs = songsToAdd.compactMap { $0.librarySong }
                guard !musicKitSongs.isEmpty else { return }
                
                do {
                    try await player.queue.insert(musicKitSongs, position: .tail)
                    #if DEBUG
                    print("🔁 Large context, repeat all from start: +\(musicKitSongs.count)")
                    #endif
                } catch {
                    print("Error refill: \(error)")
                }
                return
            }
            
            /// Add next batch
            let end = min(start + refillBatchSize, sourceList.count)
            let songsToAdd = sourceList[start..<end]
            let musicKitSongs = songsToAdd.compactMap { $0.librarySong }
            guard !musicKitSongs.isEmpty else { return }
            
            do {
                try await player.queue.insert(musicKitSongs, position: .tail)
                #if DEBUG
                print("✅ Refill large context from \(start): +\(musicKitSongs.count)")
                #endif
            } catch {
                print("Error refill: \(error)")
            }
        }
    }

    /// Builds the queue array for a given song and context.
    /// For small contexts (≤100): Returns ALL songs (enables prev/next navigation within album/artist)
    /// For large contexts (>100): Returns songs from current position + 100 (batch loading)
    private func buildQueue(for librarySong: Song, song: RSSong, context: [RSSong]) -> [Song] {
        let sourceList = isShuffleEnabled ? shuffledContext : context
        
        guard let index = sourceList.firstIndex(where: { $0.id == song.id }) else { return [librarySong] }
        
        /// Small context (album/filtered artist): load everything for full prev/next navigation
        if sourceList.count <= 100 {
            return sourceList.compactMap { $0.librarySong }
        }
        
        /// Large context: load from current song + batch
        let end = min(sourceList.count, index + 100)
        let slice = sourceList[index..<end]
        
        return slice.compactMap { $0.librarySong }
    }
    
    /// Refreshes the shuffled context, keeping the current song at position 0
    /// and shuffling all other songs after it.
    private func refreshShuffledContext(keeping currentSong: RSSong) {
        let others = currentContext.filter { $0.id != currentSong.id }
        shuffledContext = [currentSong] + others.shuffled()
    }
    

    // MARK: - Controls
    
    /// Toggles between play and pause states.
    /// If queue is empty or at beginning, rebuilds the queue before playing.
    func togglePlayPause() {
            Task {
                do {
                    let appPlayer = ApplicationMusicPlayer.shared
                    
                    if isPlaying {
                        try await appPlayer.pause()
                        isPlaying = false
                        lastPublishedPlayingState = false
                        onPlayingStateChanged()
                    } else {
                        let expectedSong = nowPlaying
                        let needsQueueBuild = appPlayer.queue.entries.isEmpty || (currentTime == 0 && !isPlaying)
                        
                        if needsQueueBuild, let current = nowPlaying, let libSong = current.librarySong {
                            let musicKitSongs = buildQueue(for: libSong, song: current, context: currentContext)
                            
                            guard !musicKitSongs.isEmpty else { return }
                            appPlayer.queue = ApplicationMusicPlayer.Queue(for: musicKitSongs, startingAt: libSong)
                            
                        } else if appPlayer.queue.entries.isEmpty {
                            populateFullQueue()
                        }
                        
                        isUserChangingSong = true
                        
                        try await appPlayer.play()
                        
                        /// Update UI
                        await MainActor.run {
                            isPlaying = true
                            lastPublishedPlayingState = true
                            onPlayingStateChanged()
                        }
                        
                        try? await Task.sleep(for: .milliseconds(300))
                        
                        if let expected = expectedSong, nowPlaying?.id != expected.id {
                            nowPlaying = expected
                            lastPublishedSongID = expected.id
                        }
                        
                        isUserChangingSong = false
                    }
                } catch {
                    isUserChangingSong = false
                    #if DEBUG
                    print("❌ toggle error:", error)
                    #endif
                }
            }
        }

    /// Skips to the next song.
    /// If not playing: selects next song from context (random if shuffle, sequential if not).
    /// If playing: uses system skipToNextEntry.
    func playNext() {
        nextCount = nextCount + 1
        if !isPlaying, let current = nowPlaying {
            let context = currentContext.isEmpty ? results : currentContext
            
            let nextSong: RSSong
            
            if isShuffleEnabled {
                let otherSongs = context.filter { $0.id != current.id }
                guard let randomSong = otherSongs.randomElement() else { return }
                nextSong = randomSong
            } else {
                guard let currentIndex = context.firstIndex(where: { $0.id == current.id }) else { return }
                let nextIndex = (currentIndex + 1) % context.count
                nextSong = context[nextIndex]
            }
            
            nowPlaying = nextSong
            lastPublishedSongID = nextSong.id
            currentTime = 0
            lastPublishedTime = 0
            if let duration = nextSong.librarySong?.duration {
                self.duration = duration
            }
            
            if let librarySong = nextSong.librarySong {
                Task {
                    let musicKitSongs = buildQueue(for: librarySong, song: nextSong, context: context)
                    guard !musicKitSongs.isEmpty else { return }
                    ApplicationMusicPlayer.shared.queue = ApplicationMusicPlayer.Queue(for: musicKitSongs, startingAt: librarySong)
                    restoreRepeatMode()
                }
            }
            return
        }
        
        Task {
            do {
                try await ApplicationMusicPlayer.shared.skipToNextEntry()
                try? await Task.sleep(for: .milliseconds(200))
                syncCurrentSong()
            } catch {
                #if DEBUG
                print("❌ Error playNext: \(error)")
                #endif
            }
        }
    }

    /// Skips to the previous song.
    /// If playback > 3 seconds: restarts current song instead.
    /// If not playing: selects previous song from context.
    /// If playing: uses system skipToPreviousEntry.
    func playPrevious() {
        
        let currentPlayerTime = ApplicationMusicPlayer.shared.playbackTime
        
        // If more than 3 seconds in, restart current song
        if currentPlayerTime > 3.0 {
            seek(to: 0)
            return
        }
        
        if !isPlaying, let current = nowPlaying {
            let context = currentContext.isEmpty ? results : currentContext
            
            let prevSong: RSSong
            
            if isShuffleEnabled {
                let otherSongs = context.filter { $0.id != current.id }
                guard let randomSong = otherSongs.randomElement() else { return }
                prevSong = randomSong
            } else {
                guard let currentIndex = context.firstIndex(where: { $0.id == current.id }) else { return }
                let prevIndex = currentIndex > 0 ? currentIndex - 1 : context.count - 1
                prevSong = context[prevIndex]
            }
            
            nowPlaying = prevSong
            lastPublishedSongID = prevSong.id
            currentTime = 0
            lastPublishedTime = 0
            if let duration = prevSong.librarySong?.duration {
                self.duration = duration
            }
            
            if let librarySong = prevSong.librarySong {
                Task {
                    let musicKitSongs = buildQueue(for: librarySong, song: prevSong, context: context)
                    guard !musicKitSongs.isEmpty else { return }
                    ApplicationMusicPlayer.shared.queue = ApplicationMusicPlayer.Queue(for: musicKitSongs, startingAt: librarySong)
                    restoreRepeatMode()
                }
            }
            return
        }
        
        Task {
            do {
                try await ApplicationMusicPlayer.shared.skipToPreviousEntry()
                try? await Task.sleep(for: .milliseconds(200))
                syncCurrentSong()
            } catch {
                #if DEBUG
                print("❌ Error playPrevious: \(error)")
                #endif
            }
        }
    }
    
    func playSong(_ song: RSSong, in context: [RSSong]) {
        
        #if DEBUG
        print("🎵 playSong called:")
        print("   - song: \(song.title)")
        print("   - context.count: \(context.count)")
        #endif
        
        /// Disable filters if context has multiple artists/albums
        if context.count > 1 {
            let contextArtists = Set(context.prefix(100).map { $0.artist.lowercased() })
            let contextAlbums = Set(context.prefix(100).map { $0.album.lowercased() })
            
            if contextArtists.count > 1 && isArtistFilterEnabled {
                isArtistFilterEnabled = false
            }
            if contextAlbums.count > 1 && isAlbumFilterEnabled {
                isAlbumFilterEnabled = false
            }
        }
        
        currentContext = context
            
        #if DEBUG
        print("   - currentContext.count after assign: \(currentContext.count)")
        #endif
        
        isUserChangingSong = true
        nowPlaying = song
        lastPublishedSongID = song.id
        
        if isShuffleEnabled {
            refreshShuffledContext(keeping: song)
        }
        
        if let duration = song.librarySong?.duration {
            self.duration = duration
        }
        currentTime = 0
        lastPublishedTime = 0
        
        Task(priority: .userInitiated) {
            defer {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    isUserChangingSong = false
                    syncCurrentSong()
                }
            }
            
            guard let librarySong = song.librarySong else { return }
            let musicKitSongs = buildQueue(for: librarySong, song: song, context: context)
            
            guard !musicKitSongs.isEmpty else { return }
            
            let player = ApplicationMusicPlayer.shared
            player.queue = ApplicationMusicPlayer.Queue(for: musicKitSongs, startingAt: librarySong)
            
            do {
                try await player.play()
                await MainActor.run {
                    isPlaying = true
                    lastPublishedPlayingState = true
                    onPlayingStateChanged()
                }
                restoreRepeatMode()
            } catch {
                await MainActor.run {
                    isPlaying = false
                    lastPublishedPlayingState = false
                    onPlayingStateChanged()
                }
            }
        }
    }
    
    
    // MARK: - Handle Repeat
    
    /// Handles repeat one mode by pausing, seeking to 0, and resuming playback.
    private func handleRepeatOne(appPlayer: ApplicationMusicPlayer) async {
        do {
            try await appPlayer.pause()
            appPlayer.playbackTime = 0
            try await appPlayer.play()
            
            await MainActor.run {
                currentTime = 0
                lastPublishedTime = 0
            }
        } catch {
            #if DEBUG
            print("❌ Error in Repeat 1: \(error)")
            #endif
        }
    }

    /// Handles repeat all mode for small contexts.
    /// When at the last song in context, plays the first song to create a loop.
    private func handleRepeatAll() {
        #if DEBUG
        print("🔁 handleRepeatAll called")
        print("   - nowPlaying: \(nowPlaying?.title ?? "nil")")
        print("   - currentContext.count: \(currentContext.count)")
        #endif
        
        guard let currentSong = nowPlaying,
              let index = currentContext.firstIndex(where: { $0.id == currentSong.id }),
              index == currentContext.count - 1,
              let firstSong = currentContext.first else {
            #if DEBUG
            print("   - Conditions not met for repeat all")
            #endif
            return
        }
        
        #if DEBUG
        print("   - Executing repeat all, returning to: \(firstSong.title)")
        #endif
        
        playSong(firstSong, in: currentContext)
    }

    // MARK: - Toggles
    
    /// Toggles shuffle mode on/off.
    /// When enabled: creates shuffledContext with current song first, rest shuffled.
    /// When disabled: clears shuffledContext.
    /// Rebuilds queue to reflect the change.
    func toggleShuffle() {
        isShuffleEnabled.toggle()
        guard let current = nowPlaying, let librarySong = current.librarySong else { return }
        
        if currentContext.isEmpty { currentContext = results }
        
        if isShuffleEnabled {
            refreshShuffledContext(keeping: current)
        } else {
            shuffledContext = []
        }
        
        rebuildQueuePreservingPosition(current: current, librarySong: librarySong)
    }
        
    /// Cycles through repeat modes: none → all → one → none.
    /// Applies the mode to the system player.
    func toggleRepeat() {
        var nextMode: MusicKit.MusicPlayer.RepeatMode
        switch repeatMode {
        case .none: nextMode = .all
        case .all: nextMode = .one
        case .one: nextMode = .none
        @unknown default: nextMode = .none
        }
        
        repeatMode = nextMode
        applyRepeatModeToSystem(nextMode)
    }
    
    /// Toggles artist filter on/off.
    /// When enabled: filters to show only songs by current artist (from fullLibrary).
    /// When disabled: restores previous context (search results or fullLibrary).
    /// Saves context before filtering to allow proper restoration.
    func toggleArtistFilter() {
        guard let current = nowPlaying, let librarySong = current.librarySong else { return }
        
        isArtistFilterEnabled.toggle()
        
        if isArtistFilterEnabled {
            /// If album filter was active, deactivate it but keep its original context
            if isAlbumFilterEnabled {
                isAlbumFilterEnabled = false
                contextBeforeArtistFilter = contextBeforeAlbumFilter.isEmpty ? fullLibrary : contextBeforeAlbumFilter
                contextBeforeAlbumFilter = []
            } else {
                // Guardar el contexto actual como respaldo
                contextBeforeArtistFilter = currentContext.isEmpty ? fullLibrary : currentContext
            }
            
            let currentArtist = current.artist.lowercased()
            /// Filter from fullLibrary to get ALL songs by artist
            let artistSongs = fullLibrary.filter { $0.artist.lowercased() == currentArtist }
            
            #if DEBUG
            print("🎤 Artist filter enabled:")
            print("   - Artist: \(current.artist)")
            print("   - Saved context: \(contextBeforeArtistFilter.count) songs")
            print("   - Artist songs (from fullLibrary): \(artistSongs.count)")
            #endif
            
            guard !artistSongs.isEmpty else {
                isArtistFilterEnabled = false
                contextBeforeArtistFilter = []
                return
            }
            
            currentContext = artistSongs
        } else {
            // Restore previous context (search or fullLibrary)
            currentContext = contextBeforeArtistFilter.isEmpty ? fullLibrary : contextBeforeArtistFilter
            contextBeforeArtistFilter = []
            
            #if DEBUG
            print("🎤 Artist filter disabled, context restored: \(currentContext.count) songs")
            #endif
        }
        
        if isShuffleEnabled {
            refreshShuffledContext(keeping: current)
        }
        
        rebuildQueuePreservingPosition(current: current, librarySong: librarySong)
    }


    /// Toggles album filter on/off.
    /// When enabled: filters to show only songs from current album (from fullLibrary), sorted by disc/track.
    /// When disabled: restores previous context (search results or fullLibrary).
    /// Saves context before filtering to allow proper restoration.
    func toggleAlbumFilter() {
        guard let current = nowPlaying, let librarySong = current.librarySong else { return }
        
        isAlbumFilterEnabled.toggle()

        if isAlbumFilterEnabled {
            /// If artist filter was active, deactivate it but keep its original context
            if isArtistFilterEnabled {
                isArtistFilterEnabled = false
                contextBeforeAlbumFilter = contextBeforeArtistFilter.isEmpty ? fullLibrary : contextBeforeArtistFilter
                contextBeforeArtistFilter = []
            } else {
                contextBeforeAlbumFilter = currentContext.isEmpty ? fullLibrary : currentContext
            }
            
            let currentAlbum = current.album.lowercased()
            let currentArtist = current.artist.lowercased()
            
            /// Filter from fullLibrary by album AND artist to avoid mixing albums with same name
            var albumSongs = fullLibrary.filter {
                $0.album.lowercased() == currentAlbum &&
                $0.artist.lowercased() == currentArtist
            }
            
            /// Sort by disc number, then track number
            albumSongs.sort { s1, s2 in
                let disc1 = s1.librarySong?.discNumber ?? 1
                let disc2 = s2.librarySong?.discNumber ?? 1
                
                if disc1 != disc2 {
                    return disc1 < disc2
                }
                
                let track1 = s1.librarySong?.trackNumber ?? 0
                let track2 = s2.librarySong?.trackNumber ?? 0
                return track1 < track2
            }
            
            #if DEBUG
            print("💿 Album filter enabled:")
            print("   - Album: \(current.album)")
            print("   - Artist: \(current.artist)")
            print("   - Saved context: \(contextBeforeAlbumFilter.count) songs")
            print("   - Album songs (from fullLibrary): \(albumSongs.count)")
            #endif
            
            guard !albumSongs.isEmpty else {
                isAlbumFilterEnabled = false
                contextBeforeAlbumFilter = []
                return
            }
            
            currentContext = albumSongs
            
            if (isShuffleEnabled) {
                toggleShuffle()
            }
        } else {
            /// Restore previous context
            currentContext = contextBeforeAlbumFilter.isEmpty ? fullLibrary : contextBeforeAlbumFilter
            contextBeforeAlbumFilter = []
            
            #if DEBUG
            print("💿 Album filter disabled, context restored: \(currentContext.count) songs")
            #endif
        }
        
        if isShuffleEnabled {
            refreshShuffledContext(keeping: current)
        }
        
        rebuildQueuePreservingPosition(current: current, librarySong: librarySong)
    }
    
    
    /// Rebuilds the queue while preserving the current playback position.
    /// Used after toggling shuffle or filters to update the queue without interrupting playback.
    private func rebuildQueuePreservingPosition(current: RSSong, librarySong: Song) {
        Task(priority: .userInitiated) {
            let player = ApplicationMusicPlayer.shared
            let savedTime = player.playbackTime
            let wasPlaying = isPlaying
            
            let musicKitSongs = buildQueue(for: librarySong, song: current, context: currentContext)
            
            guard !musicKitSongs.isEmpty else { return }
            
            /// Create queue with all songs, starting at current
            player.queue = ApplicationMusicPlayer.Queue(for: musicKitSongs, startingAt: librarySong)
            
            #if DEBUG
            print("🔨 Rebuild queue:")
            print("   - Context: \(currentContext.count) songs")
            print("   - Queue created: \(musicKitSongs.count) songs")
            print("   - Starting at: \(current.title)")
            #endif
            
            if wasPlaying {
                do {
                    try await player.play()
                    player.playbackTime = savedTime
                } catch {
                    #if DEBUG
                    print("❌ Error resume: \(error)")
                    #endif
                }
            }
            
            restoreRepeatMode()
        }
    }
    
    /// Re-applies the current repeat mode to the system player.
    /// Called after queue rebuilds to ensure repeat mode is preserved.
    private func restoreRepeatMode() {
        applyRepeatModeToSystem(repeatMode)
    }
    
    
    /// Applies a repeat mode to the system's MPMusicPlayerController.
    /// Needed because ApplicationMusicPlayer doesn't expose repeat mode directly.
    private func applyRepeatModeToSystem(_ mode: MusicKit.MusicPlayer.RepeatMode) {
        Task { @MainActor in
            let classicPlayer = MPMusicPlayerController.applicationQueuePlayer
            var classicMode: MPMusicRepeatMode
            switch mode {
            case .none: classicMode = .none
            case .all: classicMode = .all
            case .one: classicMode = .one
            @unknown default: classicMode = .none
            }
            classicPlayer.repeatMode = classicMode
        }
    }
    
    // MARK: - AirPlay

    /// Starts observing AirPlay route changes to update isAirPlayActive flag.
    private func startAirPlayObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            self?.checkAirPlayStatus()
        }
        checkAirPlayStatus()
    }

    /// Checks current audio route and updates isAirPlayActive if changed.
    private func checkAirPlayStatus() {
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        let isAirPlay = currentRoute.outputs.contains { $0.portType == .airPlay }
        
        if isAirPlayActive != isAirPlay {
            isAirPlayActive = isAirPlay
        }
    }
   
    // MARK: - Cleanup
    
    /// Cancels all Combine subscriptions when the service is deallocated.
    deinit {
        playerStateCancellable?.cancel()
        queueEntryCancellable?.cancel()
        playbackTimeCancellable?.cancel()
    }
}

struct RSSong: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let artist: String
    let album: String
    let cover: String
    let musicItemID: MusicItemID?
    let librarySong: Song?

    init(title: String, artist: String, cover: String) {
        self.title = title
        self.artist = artist
        self.album = ""
        self.cover = cover
        self.musicItemID = nil
        self.librarySong = nil
    }

    init(title: String, artist: String, cover: String, musicItemID: MusicItemID?) {
        self.title = title
        self.artist = artist
        self.album = ""
        self.cover = cover
        self.musicItemID = musicItemID
        self.librarySong = nil
    }

    init(title: String, artist: String, album: String, cover: String, musicItemID: MusicItemID?, librarySong: Song?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.cover = cover
        self.musicItemID = musicItemID
        self.librarySong = librarySong
    }
}
