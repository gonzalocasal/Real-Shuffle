import SwiftUI

struct WidgetState: Codable {
    let title: String
    let artist: String
    let coverURL: String
    let isPlaying: Bool
}

class SharedDataManager {
    // Reemplaza con TU identificador de grupo exacto
    static let suiteName = "group.com.tuempresa.musicplayer"
    
    static func saveState(title: String, artist: String, coverURL: String, isPlaying: Bool) {
        let state = WidgetState(title: title, artist: artist, coverURL: coverURL, isPlaying: isPlaying)
        if let data = try? JSONEncoder().encode(state) {
            let userDefaults = UserDefaults(suiteName: suiteName)
            userDefaults?.set(data, forKey: "widgetState")
            // Avisar al sistema que recargue los widgets
            // Nota: Importar WidgetKit en el archivo donde llames a esto, o usa una notificación
        }
    }
    
    static func loadState() -> WidgetState? {
        let userDefaults = UserDefaults(suiteName: suiteName)
        if let data = userDefaults?.data(forKey: "widgetState") {
            return try? JSONDecoder().decode(WidgetState.self, from: data)
        }
        return nil
    }
}