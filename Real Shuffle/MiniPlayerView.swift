import SwiftUI
import MusicKit

struct MiniPlayerView: View {
    @ObservedObject var player: MusicPlayerService
    @Binding var showFullPlayer: Bool
    var animation: Namespace.ID
    
    var body: some View {
        HStack(spacing: 12) {
            if let url = player.nowPlaying?.librarySong?.artwork?.url(width: 60, height: 60) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray.opacity(0.3)
                }
                .frame(width: 50, height: 50)
                .cornerRadius(8)
                .matchedGeometryEffect(id: "Artwork", in: animation)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(player.nowPlaying?.title ?? "No Song")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .matchedGeometryEffect(id: "Title", in: animation, properties: .position)
                
                Text(player.nowPlaying?.artist ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .matchedGeometryEffect(id: "Artist", in: animation, properties: .position)
            }
            
            Spacer(minLength: 0)
        
            HStack(spacing: 12) {
                Button(action: { player.playPrevious() }) {
                    Image(systemName: "backward.fill").font(.title3)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                Button(action: { player.togglePlayPause() }) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                }
                .keyboardShortcut(.space, modifiers: [])
                Button(action: { player.playNext() }) {
                    Image(systemName: "forward.fill").font(.title3)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .foregroundColor(.primary)
        }
        .padding(12)
        .frame(maxWidth: 600)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                showFullPlayer = true
            }
        }
    }
}
