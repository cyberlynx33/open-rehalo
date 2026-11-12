import SwiftUI

/// Map orientation, shared by the Map tab and Navigating (Apple Maps style):
/// - `north`: north up; the rider's marker turns.
/// - `compass`: the map turns so what's ahead is up (iPhone compass; hybrid with GPS in Navigating).
/// - `free`: the rider turned or moved the map by hand; it stays loose until Centre.
/// The round button toggles North ⇄ Compass; turning the map with two fingers enters Free; in Free
/// the button turns it north up again. Each screen remembers North / Compass, never Free.
enum MapOrientation: String {
    case north, compass, free
}

/// The orientation button in the map's thumb column: shows the current mode; in Free its arrow
/// points north (`mapHeading` = the map's current heading).
struct OrientationButton: View {
    let orientation: MapOrientation
    var mapHeading: Double = 0
    /// Button diameter (`MapRoundButton.size`); Navigating uses the riding target.
    var size: CGFloat = 48
    let action: () -> Void

    var body: some View {
        switch orientation {
        case .north:
            MapRoundButton(systemImage: "location.north.line.fill", label: "Switch to compass",
                           size: size, action: action)
        case .compass:
            MapRoundButton(systemImage: "safari.fill", label: "Switch to north up", isOn: true,
                           size: size, action: action)
        case .free:
            MapRoundButton(systemImage: "location.north.fill", label: "Turn the map north up",
                           rotation: -mapHeading, size: size, action: action)
        }
    }
}
