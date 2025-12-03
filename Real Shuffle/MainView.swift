import SwiftUI

struct MainView: View {
    @ObservedObject private var player = MusicPlayerService.shared
    @State private var showingFullPlayer = false
    @State private var isLoadingLibrary = true
    @Namespace private var animation 
    
    var body: some View {
        ZStack(alignment: .bottom) {
            SongListView(player: player, isLoading: isLoadingLibrary)
                .zIndex(0)

            if player.nowPlaying != nil {
                ZStack(alignment: .bottom) {
                    if !showingFullPlayer {
                        MiniPlayerView(
                            player: player,
                            showFullPlayer: $showingFullPlayer,
                            animation: animation
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .zIndex(1)
                    }
                    
                    if showingFullPlayer {
                        NowPlayingView(
                            player: player,
                            showFullPlayer: $showingFullPlayer,
                            animation: animation
                        )
                        .zIndex(2)
                        .transition(.opacity)
                    }
                }
            }
        }
        .onAppear {
            #if !targetEnvironment(simulator)
            Task { @MainActor in
                await player.loadUserLibraryIntoResults()
                isLoadingLibrary = false
            }
            #else
            print("⚠️ Simulator")
            isLoadingLibrary = false
            #endif
        }
    }
}
