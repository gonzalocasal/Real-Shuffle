import SwiftUI
import MusicKit
import UIKit

// MARK: - Sort Options
enum SongSortOption: String, CaseIterable {
    case title = "title"
    case artist = "artist"
    case dateAdded = "dateAdded"
    
    var icon: String {
        switch self {
        case .title: return "music.note"
        case .artist: return "music.microphone"
        case .dateAdded: return "clock"
        }
    }
}

// MARK: - Playing Indicator
struct PlayingIndicator: View {
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary)
                    .frame(width: 3, height: isAnimating ? 14 : 4)
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.15),
                        value: isAnimating
                    )
            }
        }
        .frame(height: 14)
        .onAppear { isAnimating = true }
    }
}

// MARK: - Artwork Image View
struct ArtworkImageView: View {
    let artwork: MusicKit.Artwork?
    
    var body: some View {
        Group {
            if let artwork = artwork {
                ArtworkImage(artwork, width: 50, height: 50)
                    .cornerRadius(6)
            } else {
                ZStack {
                    Color.gray.opacity(0.2)
                    Image(systemName: "music.note")
                        .foregroundColor(.gray)
                }
                .frame(width: 50, height: 50)
                .cornerRadius(6)
            }
        }
        .frame(width: 50, height: 50)
    }
}

// MARK: - Song Row
struct SongRowView: View {
    let song: RSSong
    let isPlaying: Bool
    let onTap: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            ArtworkImageView(artwork: song.librarySong?.artwork)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Text(song.artist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            if isPlaying {
                PlayingIndicator()
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}
// MARK: - Main View
struct SongListView: View {
    @ObservedObject var player: MusicPlayerService
    
    var isLoading: Bool = false
    
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var isScrolled = false
    @State private var searchTask: Task<Void, Never>?
    @State private var sortedSongs: [RSSong] = []
    @State private var finalDisplayedSongs: [RSSong] = []
    @State private var sortTask: Task<Void, Never>?
    
    @FocusState private var isSearchFocused: Bool
    
    @AppStorage("songSortOption") private var sortOptionRaw: String = SongSortOption.title.rawValue
    @AppStorage("songSortAscending") private var sortAscending: Bool = true
    
    private var sortOption: SongSortOption {
        SongSortOption(rawValue: sortOptionRaw) ?? .title
    }
    
    // MARK: - Sort Logic
    private func updateSortedSongs() {
        sortTask?.cancel()
        
        let sourceSongs = player.results
        let currentOption = sortOption
        let currentAscending = sortAscending

        sortTask = Task.detached(priority: .userInitiated) {
            
            if sourceSongs.isEmpty {
                await MainActor.run {
                    self.sortedSongs = []
                    self.performSearch()
                }
                return
            }

            let sorted = sourceSongs.sorted { song1, song2 in
                let comparison: Bool
                switch currentOption {
                case .title:
                    comparison = song1.title.localizedCaseInsensitiveCompare(song2.title) == .orderedAscending
                case .artist:
                    let artistComp = song1.artist.localizedCaseInsensitiveCompare(song2.artist)
                    if artistComp == .orderedSame {
                        comparison = song1.title.localizedCaseInsensitiveCompare(song2.title) == .orderedAscending
                    } else {
                        comparison = artistComp == .orderedAscending
                    }
                case .dateAdded:
                    let date1 = song1.librarySong?.libraryAddedDate ?? .distantPast
                    let date2 = song2.librarySong?.libraryAddedDate ?? .distantPast
                    comparison = date1 > date2
                }
                return currentAscending ? comparison : !comparison
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.sortedSongs = sorted
                }
                self.performSearch()
            }
        }
    }
    
    // MARK: - Do search
    private func performSearch() {

        if debouncedSearchText.isEmpty {
            if finalDisplayedSongs != sortedSongs {
                withAnimation(.easeOut(duration: 0.2)) {
                    finalDisplayedSongs = sortedSongs
                }
            }
            return
        }
        
        let query = debouncedSearchText
        let source = sortedSongs
        
        Task.detached(priority: .userInitiated) {
            let filtered = source.filter { song in
                
                let titleMatch = song.title.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
                
                let artistMatch = song.artist.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
                
                return titleMatch || artistMatch
            }
            
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.finalDisplayedSongs = filtered
                }
            }
        }
    }
    
    // Debounce
    private func onSearchTextChanged() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                debouncedSearchText = searchText
            }
        }
    }
    
    // MARK: - Body
    var body: some View {
        NavigationView {
        contentSection

            .safeAreaInset(edge: .top) {
                headerSection
            }

            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .onAppear {
            if sortedSongs.isEmpty && !player.results.isEmpty {
                updateSortedSongs()
            }
        }
        .onChange(of: player.results.count) { updateSortedSongs() }
        .onChange(of: sortOptionRaw) { updateSortedSongs() }
        .onChange(of: sortAscending) { updateSortedSongs() }
        .onChange(of: searchText) { onSearchTextChanged() }
        .onChange(of: debouncedSearchText) { performSearch() }
    }
    
    // MARK: - Header
    private var headerSection: some View {
    VStack(spacing: 0) {
        VStack(spacing: 8) {
            HStack {
                Text("app.title")
                    .font(isScrolled ? .headline : .largeTitle)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(isScrolled ? 0 : 1)
                    .overlay(
                        Text("app.title")
                            .font(.headline)
                            .opacity(isScrolled ? 1 : 0)
                    )
            }
            .padding(.horizontal, 20)
            HStack(spacing: 12) {
                
            
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 17))
                
                TextField("library.search.placeholder", text: $searchText)
                    .focused($isSearchFocused)
                    .textFieldStyle(.plain)
                
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        isSearchFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
                
            }
            .frame(height: 36)
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(10)
            sortButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
    .frame(maxWidth: .infinity)
    .padding(.bottom, 8)
    // SOLUCIÓN VISUAL IPHONE:
    .background {
        Rectangle()
            .fill(.ultraThinMaterial)
            .ignoresSafeArea(edges: .top) // <- Solo el fondo sube hasta arriba
    }
    .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
}
    
    // MARK: - Content
    private var contentSection: some View {
        Group {
            if isLoading {
                loadingView
            } else if player.results.isEmpty {
                emptyLibraryView
            } else if finalDisplayedSongs.isEmpty && !debouncedSearchText.isEmpty {
                noResultsView
            } else {
                songListView(songs: finalDisplayedSongs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - List
    private func songListView(songs: [RSSong]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollOffsetKey.self,
                        value: geo.frame(in: .named("scroll")).minY
                    )
                }
                .frame(height: 0)
        
                
                ForEach(songs) { song in
                    VStack(spacing: 0) {
                        SongRowView(
                            song: song,
                            isPlaying: player.nowPlaying?.id == song.id,
                            onTap: { [player] in
                                player.playSong(song, in: songs)
                            }
                        )
                        .padding(.horizontal, 20)
                        
                        Divider().padding(.leading, 82)
                    }
                }
                
                Spacer().frame(height: 120)
            }
        }
        
        .scrollDismissesKeyboard(.immediately)
        .coordinateSpace(name: "scroll")
        .onPreferenceChange(ScrollOffsetKey.self) { value in
            let shouldScroll = value < 0
            if isScrolled != shouldScroll {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isScrolled = shouldScroll
                }
            }
        }
    }
    
    // MARK: - Sort Button
    private var sortButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            
            if sortAscending {
                sortAscending = false
            } else {
                sortAscending = true
                let cases = SongSortOption.allCases
                if let idx = cases.firstIndex(of: sortOption) {
                    sortOptionRaw = cases[(idx + 1) % cases.count].rawValue
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 44, height: 44)
                
                HStack(spacing: 2) {
                    Image(systemName: sortOption.icon)
                        .font(.system(size: 16, weight: .bold))
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 6, weight: .bold))
                }
                .foregroundColor(.primary)
            }
        }
    }
    
    // MARK: - Empty States
    private var loadingView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 60)
            ProgressView().scaleEffect(1.5)
            Text("library.status.loading")
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }
    
    private var emptyLibraryView: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 60)
            Image(systemName: "music.note.list")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("library.status.empty.title")
                .font(.headline)
            Text("library.status.empty.message")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    private var noResultsView: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 60)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("library.status.no_results")
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }

}

// MARK: - Preference Key
struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
