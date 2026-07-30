import Foundation

/// Where the app talks to its Go backend. Debug points at a locally running
/// `docker compose` stack (simulator reaches the Mac's localhost directly;
/// a physical device needs the Mac's LAN IP here plus an ATS exception).
enum BackendConfig {
    static let baseURL: URL = {
        #if DEBUG
        // The Mac's LAN IP running `docker compose` in backend/ — reachable
        // from both the simulator and a physical device on the same network.
        // Update when the Mac's IP changes (`ipconfig getifaddr en0`).
        return URL(string: "http://192.168.3.70:8080")!
        #else
        return URL(string: "https://api.squatter.fit")!
        #endif
    }()
}
