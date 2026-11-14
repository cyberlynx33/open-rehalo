import Foundation

/// The manoeuvre a routing service says a step starts with (BRouter's voice hints; Valhalla and OSRM
/// have the same vocabulary). Nil on a step from a service that gives none, such as Apple's, where
/// the turn is read from the geometry and the text.
public enum RoutedManeuver: Equatable, Sendable, Codable {
    case depart, arrive
    case straight
    case slightLeft, left, sharpLeft
    case slightRight, right, sharpRight
    case keepLeft, keepRight
    case uTurn
    /// Exit number counted from the entry; `clockwise` is the way round the island (left-hand
    /// traffic). Right-hand traffic goes round counter-clockwise.
    case roundabout(exit: Int, clockwise: Bool)

    /// A manoeuvre the rider has to make, however small the angle the geometry gives it: a fork's
    /// "keep right" can be under 20° and still be the turn that matters.
    public var isTurn: Bool {
        switch self {
        case .depart, .arrive, .straight: return false
        default: return true
        }
    }

    /// The exit and direction of a roundabout, nil for anything else.
    public var roundabout: (exit: Int, clockwise: Bool)? {
        if case .roundabout(let exit, let clockwise) = self { return (exit, clockwise) }
        return nil
    }

    /// Left (−1), right (+1) or neither (0), as the manoeuvre says, for a sanity check against the
    /// geometry's angle.
    public var side: Int {
        switch self {
        case .slightLeft, .left, .sharpLeft, .keepLeft: return -1
        case .slightRight, .right, .sharpRight, .keepRight: return 1
        default: return 0
        }
    }
}

/// The ring's roundabout glyph (`Commands.roundabout(exits:)`) wants the angle of every exit from the
/// entry, the one to take first. A routing service only says which exit and how far round it is, so
/// the exits before it are spread evenly between the entry and the one to take.
public enum RoundaboutExits {
    /// The firmware draws at most this many exits.
    public static let maximumExits = 10

    /// Angles in the ring's frame (0 = ahead, + = right), the exit to take first, then the exits
    /// passed on the way to it from the nearest to the entry. `angle` is the net turn of the exit to
    /// take; `exit` its number (1 = the first exit). Going round counter-clockwise (right-hand
    /// traffic) the exits come at decreasing angles from the entry (behind, +180) to the exit; going
    /// clockwise, at increasing angles from −180.
    public static func angles(exit: Int, angle: Int, clockwise: Bool) -> [Int] {
        let own = NavMath.normalized(angle)
        let n = min(max(exit, 1), maximumExits)
        var out = [own]
        let from = clockwise ? -180.0 : 180.0
        for k in 1..<n {
            let a = from + (Double(own) - from) * Double(k) / Double(n)
            out.append(NavMath.normalized(Int(a.rounded())))
        }
        return out
    }
}
