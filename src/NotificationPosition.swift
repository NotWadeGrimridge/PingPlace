import Foundation

enum NotificationPosition: String, CaseIterable {
    case topLeft, topMiddle, topRight
    case middleLeft, deadCenter, middleRight
    case bottomLeft, bottomMiddle, bottomRight

    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topMiddle: return "Top Middle"
        case .topRight: return "Top Right"
        case .middleLeft: return "Middle Left"
        case .deadCenter: return "Middle"
        case .middleRight: return "Middle Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomMiddle: return "Bottom Middle"
        case .bottomRight: return "Bottom Right"
        }
    }
}
