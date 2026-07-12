import SwiftUI

/// The auth gate. Login is required at launch, so this is the app's real
/// root: it shows the sign-in screen until there's a confirmed session, then
/// the home experience.
struct RootView: View {
    @Environment(AuthSession.self) private var auth

    var body: some View {
        switch auth.state {
        case .checking:
            // A stored token is being confirmed; brief, so just the mark.
            ZStack {
                Color(Kodo.cardBottom).ignoresSafeArea()
                KodoEmblem(size: 64)
            }
        case .loggedOut:
            LoginView(auth: auth)
        case .loggedIn:
            // HomeView owns the model context, so it drives the pull; here
            // we just retry any pushes that were queued while offline.
            HomeView()
                .task { await SyncEngine.shared.flush() }
        }
    }
}
