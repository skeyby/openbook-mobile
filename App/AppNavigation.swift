import SwiftUI
import Observation
import OpenBookCore

// Every context pushes the same value routes into the home's NavigationStack.
enum AppRoute: Hashable {
    case myProfile, followRequests, search, person(String), post(String), people(String, Relationship)
}

@MainActor @Observable
final class AppNavigation {
    var path: [AppRoute] = []
}
