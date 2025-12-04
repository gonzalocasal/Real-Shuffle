import SwiftUI
import UIKit
import MusicKit
import AVKit

// MARK: - Wrapper isolate currentTime updates
struct NowPlayingWrapper: View {
    @ObservedObject var player: MusicPlayerService
    @Binding var showFullPlayer: Bool
    var animation: Namespace.ID
    
    @State private var cachedBackgroundImage: Image? = nil
    @State private var currentArtworkURL: URL? = nil
    @State private var imageVersion: Int = 0
    @State private var showMetadataSheet: Bool = false
    
    var body: some View {
        NowPlayingContent(
            nowPlaying: player.nowPlaying,
            isPlaying: player.isPlaying,
            isShuffleEnabled: player.isShuffleEnabled,
            repeatMode: player.repeatMode,
            isArtistFilterEnabled: player.isArtistFilterEnabled,
            isAlbumFilterEnabled: player.isAlbumFilterEnabled,
            isAirPlayActive: player.isAirPlayActive,
            cachedBackgroundImage: cachedBackgroundImage,
            backgroundImageID: "\(currentArtworkURL?.absoluteString ?? "")-\(imageVersion)",
            currentTime: player.currentTime,
            duration: player.duration,
            showFullPlayer: $showFullPlayer,
            showMetadataSheet: $showMetadataSheet,
            animation: animation,
            onPlayPause: { player.togglePlayPause() },
            onNext: { player.playNext() },
            onPrevious: { player.playPrevious() },
            onShuffle: { player.toggleShuffle() },
            onRepeat: { player.toggleRepeat() },
            onArtistFilter: { player.toggleArtistFilter() },
            onAlbumFilter: { player.toggleAlbumFilter() },
            onSeek: { player.seek(to: $0) }
        )
        .sheet(isPresented: $showMetadataSheet) {
            MetadataPopupView(song: player.nowPlaying, isPresented: $showMetadataSheet)
                .presentationDetents([.medium, .fraction(0.4)]) // Altura media
                .presentationDragIndicator(.hidden)
        }
        .onChange(of: player.nowPlaying?.musicItemID) {
            loadBackgroundImage()
        }
        .onAppear {
            loadBackgroundImage()
        }
        .preferredColorScheme(.dark)
    }
    
    private func loadBackgroundImage() {
        let newURL = player.nowPlaying?.librarySong?.artwork?.url(width: 500, height: 500)
        
        guard newURL != currentArtworkURL else { return }
        currentArtworkURL = newURL
        
        guard let url = newURL else {
            withAnimation(.easeInOut(duration: 0.3)) {
                cachedBackgroundImage = nil
                imageVersion += 1
            }
            return
        }
        
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let uiImage = UIImage(data: data) {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        cachedBackgroundImage = Image(uiImage: uiImage)
                        imageVersion += 1
                    }
                }
            }
        }
    }
}

// MARK: - Native UISlider Wrapper
struct NativeSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onEditingChanged: (Bool) -> Void
    
    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = .white.withAlphaComponent(0.3)
        slider.thumbTintColor = .white
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchDown), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }
    
    func updateUIView(_ slider: UISlider, context: Context) {
        // Solo actualizar si no está siendo editado
        if !context.coordinator.isEditing {
            slider.minimumValue = Float(range.lowerBound)
            slider.maximumValue = Float(range.upperBound)
            slider.value = Float(value)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, onEditingChanged: onEditingChanged)
    }
    
    class Coordinator: NSObject {
        var value: Binding<Double>
        var onEditingChanged: (Bool) -> Void
        var isEditing = false
        
        init(value: Binding<Double>, onEditingChanged: @escaping (Bool) -> Void) {
            self.value = value
            self.onEditingChanged = onEditingChanged
        }
        
        @objc func touchDown() {
            isEditing = true
            onEditingChanged(true)
        }
        
        @objc func touchUp() {
            isEditing = false
            onEditingChanged(false)
        }
        
        @objc func valueChanged(_ slider: UISlider) {
            value.wrappedValue = Double(slider.value)
        }
    }
}

// MARK: - Playback Slider
struct PlaybackSliderView: View {
    let currentTime: Double
    let duration: Double
    let songID: MusicItemID?
    let onSeek: (Double) -> Void
    
    @State private var sliderValue: Double = 0
    @State private var isDragging: Bool = false
    
    var body: some View {
        VStack(spacing: 8) {
            NativeSlider(
                value: $sliderValue,
                range: 0...max(duration, 1),
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing {
                        // Al soltar, enviamos el seek final
                        onSeek(sliderValue)
                    }
                }
            )
            .frame(height: 20)
            
            HStack {
                Text(formatTime(isDragging ? sliderValue : currentTime))
                Spacer()
                Text(formatTime(duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundColor(.white.opacity(0.6))
        }
        .padding(.horizontal, 30)
        
    
        .onChange(of: currentTime) { oldValue, newValue in
            if !isDragging {
                sliderValue = newValue
            }
        }
        .onChange(of: songID) { _, _ in
            isDragging = false
            sliderValue = 0
        }
        
        .onAppear {
            sliderValue = currentTime
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        if seconds.isNaN || seconds.isInfinite { return "0:00" }
        let secs = Int(seconds)
        let minutes = secs / 60
        let remainingSeconds = secs % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

// MARK: - Content
struct NowPlayingContent: View {
    let nowPlaying: RSSong?
    let isPlaying: Bool
    let isShuffleEnabled: Bool
    let repeatMode: MusicKit.MusicPlayer.RepeatMode
    let isArtistFilterEnabled: Bool
    let isAlbumFilterEnabled: Bool
    let isAirPlayActive: Bool
    let cachedBackgroundImage: Image?
    let backgroundImageID: String
    let currentTime: Double
    let duration: Double
    @Binding var showFullPlayer: Bool
    @Binding var showMetadataSheet: Bool
    var animation: Namespace.ID
    
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onShuffle: () -> Void
    let onRepeat: () -> Void
    let onArtistFilter: () -> Void
    let onAlbumFilter: () -> Void
    let onSeek: (Double) -> Void
    
    @State private var dragOffset: CGSize = .zero
    
    var body: some View {
        GeometryReader { geometry in
            backgroundLayer
                .offset(y: dragOffset.height)
            
            contentLayer(geometry: geometry)
                .offset(y: dragOffset.height)
                .gesture(dismissGesture)
        }
        .ignoresSafeArea()
    }
    
    // MARK: - Background Layer
    private var backgroundLayer: some View {
        BackgroundView(cachedImage: cachedBackgroundImage, imageID: backgroundImageID)
    }
    
    // MARK: - Content Layer
    private func contentLayer(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            dragPill.padding(.top, geometry.safeAreaInsets.top)
            
            VStack(spacing: 0) {
                artworkSection(geometry: geometry)
                Spacer().frame(height: 20)
                controlsSection(geometry: geometry)
            }
            .frame(maxWidth: 800)
            .padding(.bottom, UIDevice.current.userInterfaceIdiom == .pad ? 80 : geometry.safeAreaInsets.bottom + 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Drag pill
    private var dragPill: some View {
        Capsule()
            .fill(Color.white.opacity(0.3))
            .frame(width: 40, height: 5)
            .padding(.top, 60)
            .padding(.bottom, 20)
    }
    
    // MARK: - Artwork Section
    private func artworkSection(geometry: GeometryProxy) -> some View {
        Group {
            if let song = nowPlaying?.librarySong,
               let url = song.artwork?.url(width: 600, height: 600) {
                let heightMultiplier = UIDevice.current.userInterfaceIdiom == .pad ? 0.48 : 0.55
                let artSize = min(min(geometry.size.width - 60, geometry.size.height * heightMultiplier), 600)
                
                ArtworkContainerView(url: url, size: artSize, isPlaying: isPlaying, animation: animation)
            }
        }
    }
    
    // MARK: - Controls Section
    private func controlsSection(geometry: GeometryProxy) -> some View {
        VStack(spacing: 30) {
            trackInfoAndFilters
            
            PlaybackSliderView(
                currentTime: currentTime,
                duration: duration,
                songID: nowPlaying?.musicItemID,
                onSeek: onSeek
            )
            .frame(maxWidth: 800)
            
            MainControlsView(
                isPlaying: isPlaying,
                onPlayPause: onPlayPause,
                onNext: onNext,
                onPrevious: onPrevious
            )
            
            SecondaryControlsView(
                isShuffleEnabled: isShuffleEnabled,
                repeatMode: repeatMode,
                isAirPlayActive: isAirPlayActive,
                onShuffle: onShuffle,
                onRepeat: onRepeat
            )
        }
    }
    
    private var trackInfoAndFilters: some View {
        HStack {
            TrackInfoView(
                title: nowPlaying?.title ?? "",
                artist: nowPlaying?.artist ?? "",
                animation: animation,
                onTap: { // <--- Acción al hacer tap
                                    let generator = UIImpactFeedbackGenerator(style: .light)
                                    generator.impactOccurred()
                                    showMetadataSheet = true
                                }
            )
            Spacer()
            FilterButtonsView(
                isArtistFilterEnabled: isArtistFilterEnabled,
                isAlbumFilterEnabled: isAlbumFilterEnabled,
                onArtistFilter: onArtistFilter,
                onAlbumFilter: onAlbumFilter
            )
        }
        .padding(.horizontal, 30)
    }
    
    // MARK: - Gestures
    private var dismissGesture: some Gesture {
    DragGesture()
        .onChanged { value in
            if value.translation.height > 0 {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragOffset = value.translation
                }
            }
        }
        .onEnded { value in
            if value.translation.height > 100 {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    showFullPlayer = false
                    dragOffset = .zero
                }
            } else {
                withAnimation(.easeOut(duration: 0.25)) {
                    dragOffset = .zero
                }
            }
        }
    }
}

// MARK: - Background View
struct BackgroundView: View, Equatable {
    let cachedImage: Image?
    let imageID: String
    
    static func == (lhs: BackgroundView, rhs: BackgroundView) -> Bool {
        lhs.imageID == rhs.imageID
    }
    
    var body: some View {
        ZStack {
            Color.black
            
            if let cached = cachedImage {
                cached
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 50)
                    .opacity(0.4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .drawingGroup()
    
    }
}

// MARK: - Artwork Container (Aislado)
struct ArtworkContainerView: View, Equatable {
    let url: URL
    let size: CGFloat
    let isPlaying: Bool // 1. Nuevo parámetro
    var animation: Namespace.ID
    
    
    static func == (lhs: ArtworkContainerView, rhs: ArtworkContainerView) -> Bool {
        lhs.url == rhs.url &&
        lhs.size == rhs.size &&
        lhs.isPlaying == rhs.isPlaying
    }
    
    var body: some View {
        ZStack {
            // Glow (Fondo borroso)
            AsyncImage(url: url) { img in
                img.resizable()
                   .aspectRatio(contentMode: .fill)
                   .blur(radius: 30)
                   .opacity(0.6)
            } placeholder: {
                EmptyView()
            }
            .frame(width: size * 0.85, height: size * 0.85)
            .drawingGroup()
            
            // Main artwork
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 20).fill(.gray.opacity(0.3))
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .matchedGeometryEffect(id: "Artwork", in: animation)
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        }
        .scaleEffect(isPlaying ? 1.0 : 0.8)
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: isPlaying)
    }
}


// MARK: - Track Info
struct TrackInfoView: View, Equatable {
    let title: String
    let artist: String
    var animation: Namespace.ID
    let onTap: () -> Void
    
    static func == (lhs: TrackInfoView, rhs: TrackInfoView) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist
    }
    
    var body: some View {
        Button(action: {
            onTap()
        }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .matchedGeometryEffect(id: "Title", in: animation, properties: .position)
                
                Text(artist)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .matchedGeometryEffect(id: "Artist", in: animation, properties: .position)
            }
            
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filter Buttons
struct FilterButtonsView: View {
    let isArtistFilterEnabled: Bool
    let isAlbumFilterEnabled: Bool
    let onArtistFilter: () -> Void
    let onAlbumFilter: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            FilterButton(
                isEnabled: isArtistFilterEnabled,
                icon: "music.microphone",
                action: onArtistFilter
            )
            FilterButton(
                isEnabled: isAlbumFilterEnabled,
                icon: "square.stack",
                action: onAlbumFilter
            )
        }
    }
}

struct FilterButton: View, Equatable {
    let isEnabled: Bool
    let icon: String
    let action: () -> Void
    
    static func == (lhs: FilterButton, rhs: FilterButton) -> Bool {
        lhs.isEnabled == rhs.isEnabled && lhs.icon == rhs.icon
    }
    
    var body: some View {
        Button(action: {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                action()
            }
        }) {
            ZStack {
                Circle()
                    .fill(isEnabled ? Color.white : Color.white.opacity(0.2))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(isEnabled ? .black : .white.opacity(0.7))
            }
        }
    }
}

// MARK: - Main Controls (Aislado)
struct MainControlsView: View, Equatable {
    let isPlaying: Bool
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    
    static func == (lhs: MainControlsView, rhs: MainControlsView) -> Bool {
        lhs.isPlaying == rhs.isPlaying
    }
    
    private let sideButtonSize: CGFloat = 45
    
    var body: some View {
        HStack(spacing: 50) {
            Button(action: onPrevious) {
                Image(systemName: "backward.fill").font(.system(size: 35))
                .frame(width: sideButtonSize, height: sideButtonSize, alignment: .center)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 75))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 80, height: 80, alignment: .center)
            }
            .keyboardShortcut(.space, modifiers: [])
            Button(action: onNext) {
                Image(systemName: "forward.fill").font(.system(size: 35))
                    .frame(width: sideButtonSize, height: sideButtonSize, alignment: .center)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .foregroundColor(.white)
    }
}


// MARK: - Secondary Controls
struct SecondaryControlsView: View, Equatable {
    let isShuffleEnabled: Bool
    let repeatMode: MusicKit.MusicPlayer.RepeatMode
    let isAirPlayActive: Bool
    let onShuffle: () -> Void
    let onRepeat: () -> Void
    
    static func == (lhs: SecondaryControlsView, rhs: SecondaryControlsView) -> Bool {
        lhs.isShuffleEnabled == rhs.isShuffleEnabled &&
        lhs.repeatMode == rhs.repeatMode &&
        lhs.isAirPlayActive == rhs.isAirPlayActive
    }
    
    var body: some View {
        HStack(spacing: 60) {
            ShuffleButton(isEnabled: isShuffleEnabled, action: onShuffle)
            RepeatButton(mode: repeatMode, action: onRepeat)
            AirPlayButtonView(isActive: isAirPlayActive)
        }
        .padding(.bottom, 30)
    }
}

struct ShuffleButton: View, Equatable {
    let isEnabled: Bool
    let action: () -> Void
    
    static func == (lhs: ShuffleButton, rhs: ShuffleButton) -> Bool {
        lhs.isEnabled == rhs.isEnabled
    }
    
    var body: some View {
        Button(action: {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                action()
            }
        }) {
            ZStack {
                Circle()
                    .fill(isEnabled ? Color.white : Color.white.opacity(0.1))
                    .frame(width: 50, height: 50)
                Image(systemName: "shuffle")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(isEnabled ? .black : .white.opacity(0.6))
            }
        }
    }
}

struct RepeatButton: View, Equatable {
    let mode: MusicKit.MusicPlayer.RepeatMode
    let action: () -> Void
    
    static func == (lhs: RepeatButton, rhs: RepeatButton) -> Bool {
        lhs.mode == rhs.mode
    }
    
    var body: some View {
        Button(action: {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            action()
        }) {
            ZStack {
                Circle()
                    .fill(mode != .none ? Color.white : Color.white.opacity(0.1))
                    .frame(width: 50, height: 50)
                Image(systemName: mode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(mode != .none ? .black : .white.opacity(0.6))
            }
        }
    }
}

struct AirPlayButtonView: View, Equatable {
    let isActive: Bool
    
    static func == (lhs: AirPlayButtonView, rhs: AirPlayButtonView) -> Bool {
        lhs.isActive == rhs.isActive
    }
    
    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? Color.white : Color.white.opacity(0.1))
                .frame(width: 50, height: 50)
            
            Image(systemName: "airplayaudio")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(isActive ? .black : .white.opacity(0.6))
                .allowsHitTesting(false)
            
            AirPlayInvisibleButton()
                .frame(width: 50, height: 50)
        }
    }
}

struct AirPlayInvisibleButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.backgroundColor = .clear
        view.tintColor = .clear
        view.activeTintColor = .clear
        view.prioritizesVideoDevices = false
        
        // Disable iPadOS cursor interaction
        if let internalButton = view.subviews.first(where: { $0 is UIButton }) as? UIButton {
            internalButton.isPointerInteractionEnabled = false
        }
        
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Metadata Popup
struct MetadataPopupView: View {
    let song: RSSong?
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationStack {
            ScrollView {
                if let libSong = song?.librarySong {
                    VStack(spacing: 20) {
                        VStack(spacing: 16) {
                            if let trackNumber = libSong.trackNumber {
                                infoRow(icon: "music.note.list", label: "metadata.track", value: "\(trackNumber)")
                            }
                            
                            infoRow(icon: "square.stack", label: "metadata.album", value: libSong.albumTitle)
                            
                            if let date = libSong.releaseDate {
                                infoRow(icon: "calendar", label: "metadata.year", value: String(Calendar.current.component(.year, from: date)))
                            }
                                                        
                            infoRow(icon: "person", label: "metadata.composer", value: libSong.composerName)
                        }
                        
                        Divider().padding(.vertical, 4)
                        
                        VStack(spacing: 16) {
                            if let playCount = libSong.playCount {
                                infoRow(icon: "hifispeaker", label: "metadata.play_count", value: "\(playCount)")
                            }
                            
                            if let lastPlayed = libSong.lastPlayedDate {
                                infoRow(icon: "clock.arrow.circlepath", label: "metadata.last_played", value: lastPlayed.formatted(date: .abbreviated, time: .omitted))
                            }
                            
                            if let dateAdded = libSong.libraryAddedDate {
                                infoRow(icon: "music.note.house", label: "metadata.date_added", value: dateAdded.formatted(date: .abbreviated, time: .omitted))
                            }
                        }
                    }
                    .padding()
                    
                } else {
                    ContentUnavailableView(
                        String(localized: "metadata.unavailable"),
                        systemImage: "info.circle"
                    )
                    .padding(.top, 50)
                }
            }

            .navigationTitle(song?.title ?? String(localized: "metadata.default_title"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.fraction(0.85), .large])
        .presentationDragIndicator(.visible)
    }
    
    @ViewBuilder
    func infoRow(icon: String, label: LocalizedStringKey, value: String?) -> some View {
        if let val = value, !val.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                
                HStack(spacing: 8) {Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
                    Text(label).foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Text(val).foregroundStyle(.primary).multilineTextAlignment(.trailing)
            }
        }
    }
}

typealias NowPlayingView = NowPlayingWrapper
