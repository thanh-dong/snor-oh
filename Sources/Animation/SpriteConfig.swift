import Foundation

/// Sprite sheet configuration per character and status.
enum SpriteConfig {

    // MARK: - Constants

    static let frameBasePx: CGFloat = 128    // Display size (pixels)
    static let frameDurationMs: Double = 80  // 12.5 fps
    static let autoFreezeTimeout: TimeInterval = 10.0
    static let autoFreezeStatuses: Set<Status> = [.idle, .disconnected]

    // MARK: - Built-in Characters

    static let builtInPets = ["sprite", "samurai", "hancock"]

    /// Returns true if the pet ID refers to a custom (non-built-in) pet.
    static func isCustomPet(_ pet: String) -> Bool {
        pet.hasPrefix("custom-")
    }

    /// Sprite sheet info for a given (pet, status) pair.
    static func sheet(pet: String, status: Status) -> SpriteSheetInfo {
        switch pet {
        case "sprite":
            switch status {
            case .idle:          return .init(filename: "Idle-Anim",   frames: 6,  frameWidth: 32, frameHeight: 64, row: 0, subdirectory: "sprite")
            case .busy:          return .init(filename: "Charge-Anim", frames: 10, frameWidth: 32, frameHeight: 48, row: 0, subdirectory: "sprite")
            case .service:       return .init(filename: "Hop-Anim",    frames: 10, frameWidth: 32, frameHeight: 96, row: 0, subdirectory: "sprite")
            case .disconnected:  return .init(filename: "Sleep-Anim",  frames: 2,  frameWidth: 40, frameHeight: 24, row: 0, subdirectory: "sprite")
            case .searching:     return .init(filename: "Walk-Anim",   frames: 4,  frameWidth: 32, frameHeight: 48, row: 0, subdirectory: "sprite")
            case .initializing:  return .init(filename: "Idle-Anim",   frames: 6,  frameWidth: 32, frameHeight: 64, row: 0, subdirectory: "sprite")
            case .visiting:      return .init(filename: "Swing-Anim",  frames: 9,  frameWidth: 72, frameHeight: 80, row: 0, subdirectory: "sprite")
            }
        case "samurai":
            switch status {
            case .disconnected:  return .square("SamuraiSleep",   3,  128)
            case .busy:          return .square("SamuraiBark",    6,  128)
            case .service:       return .square("SamuraiSniff",   8,  128)
            case .idle:          return .square("SamuraiSitting", 6,  128)
            case .searching:     return .square("SamuraiIdle",    8,  128)
            case .initializing:  return .square("SamuraiIdle",    8,  128)
            case .visiting:      return .square("SamuraiSitting", 6,  128)
            }
        case "hancock":
            switch status {
            case .disconnected:  return .square("HancockSleep",    1, 128)
            case .busy:          return .square("HancockBark",     9, 128)
            case .service:       return .square("HancockSniff",   18, 128)
            case .idle:          return .square("HancockSitting", 10, 128)
            case .searching:     return .square("HancockIdle",    17, 128)
            case .initializing:  return .square("HancockIdle",    17, 128)
            case .visiting:      return .square("HancockSitting", 10, 128)
            }
        default:
            // Custom pets: look up from CustomOhhManager
            if let ohh = CustomOhhManager.shared.ohh(withID: pet),
               let entry = ohh.sprite(for: status) {
                return .square(entry.fileName, entry.frames, 128)
            }
            return .square("unknown", 1, 128)
        }
    }
}

// MARK: - Sheet Info

struct SpriteSheetInfo {
    let filename: String
    let frames: Int
    let frameWidth: Int
    let frameHeight: Int
    let row: Int             // row to extract (0 = front-facing)
    let subdirectory: String? // e.g. "sprite" for Resources/Sprites/sprite/

    /// Convenience for legacy square-frame sheets with no subdirectory.
    static func square(_ filename: String, _ frames: Int, _ size: Int) -> SpriteSheetInfo {
        SpriteSheetInfo(filename: filename, frames: frames,
                        frameWidth: size, frameHeight: size,
                        row: 0, subdirectory: nil)
    }
}
