import XCTest
@testable import SnorOhSwift

/// Guards the invariant that Epic 02's `.carrying` status must not leak into
/// sprite I/O. `.snoroh` files and `custom-ohhs.json` payloads produced by
/// older builds have no `carrying` key — forcing one would break every
/// existing import and every upgraded install.
final class Epic02BackwardCompatTests: XCTestCase {

    // MARK: - Scope contract

    func testSpriteStatusesExcludesCarrying() {
        XCTAssertFalse(Status.spriteStatuses.contains(.carrying),
                       ".carrying is a runtime display promotion — must not require sprite assets")
    }

    func testSpriteStatusesCoversEveryLegacyStatus() {
        // Every status that existed before Epic 02 still needs a sprite.
        let legacy: [Status] = [
            .initializing, .searching, .idle, .busy,
            .service, .disconnected, .visiting,
        ]
        for s in legacy {
            XCTAssertTrue(Status.spriteStatuses.contains(s),
                          "\(s) still requires a per-pet sprite sheet")
        }
    }

    func testAllCasesStillExhaustive() {
        // `Status.allCases` stays the full set so `switch status` is exhaustive
        // — we split the iteration surface, not the type.
        XCTAssertTrue(Status.allCases.contains(.carrying))
    }

    // MARK: - v1 import — legacy payload without `carrying`

    func testV1FileDecodesWithoutCarryingKey() throws {
        // An older snor-oh or ani-mime `.snoroh` file has exactly the 7
        // legacy sprite keys. Decoding must succeed and leave carrying unset.
        let json = """
        {
          "version": 1,
          "name": "Legacy",
          "sprites": {
            "idle":         {"frames": 4, "data": "aGVsbG8="},
            "busy":         {"frames": 4, "data": "aGVsbG8="},
            "service":      {"frames": 4, "data": "aGVsbG8="},
            "searching":    {"frames": 4, "data": "aGVsbG8="},
            "initializing": {"frames": 4, "data": "aGVsbG8="},
            "disconnected": {"frames": 4, "data": "aGVsbG8="},
            "visiting":     {"frames": 4, "data": "aGVsbG8="}
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OhhExporter.SnorohFile.self, from: json)
        XCTAssertEqual(decoded.sprites?.count, 7)
        XCTAssertNil(decoded.sprites?["carrying"],
                     "legacy payload must not synthesize a carrying key")
    }

    // MARK: - v2 import — legacy frameInputs map without `carrying`

    func testV2FrameInputsSurviveMissingCarrying() throws {
        let json = """
        {
          "version": 2,
          "name": "LegacyV2",
          "smartImportMeta": {
            "sourceSheet": "aGVsbG8=",
            "frameInputs": {
              "idle": "1-4",
              "busy": "5-12",
              "service": "1-4",
              "searching": "1",
              "initializing": "1",
              "disconnected": "1",
              "visiting": "1-2"
            }
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OhhExporter.SnorohFile.self, from: json)
        let inputs = decoded.smartImportMeta?.frameInputs
        XCTAssertEqual(inputs?.count, 7)
        XCTAssertNil(inputs?["carrying"])
    }

    // MARK: - CustomOhhData lookup resilience

    func testCustomOhhSpriteLookupNilForCarrying() {
        // Old `custom-ohhs.json` has sprites keyed by the legacy 7 statuses.
        // `sprite(for: .carrying)` returns nil → SpriteConfig is responsible
        // for falling back to the idle sheet (see SpriteConfig default case).
        let legacySprites: [String: CustomOhhData.SpriteEntry] = [
            "idle":         .init(fileName: "x-idle.png", frames: 4),
            "busy":         .init(fileName: "x-busy.png", frames: 4),
            "service":      .init(fileName: "x-service.png", frames: 4),
            "searching":    .init(fileName: "x-searching.png", frames: 4),
            "initializing": .init(fileName: "x-initializing.png", frames: 4),
            "disconnected": .init(fileName: "x-disconnected.png", frames: 4),
            "visiting":     .init(fileName: "x-visiting.png", frames: 4),
        ]
        let ohh = CustomOhhData(id: "custom-legacy", name: "Legacy", sprites: legacySprites)

        XCTAssertNil(ohh.sprite(for: .carrying))
        XCTAssertNotNil(ohh.sprite(for: .idle),
                        "idle sprite stays resolvable — SpriteConfig falls back to it for carrying")
    }

    // MARK: - Built-in pets keep working

    func testBuiltInPetsResolveCarryingToIdleSheet() {
        // Built-ins don't go through CustomOhhManager so this also catches
        // any future regression where the sprite map drops `.carrying`.
        for pet in ["sprite", "samurai", "hancock"] {
            let idle = SpriteConfig.sheet(pet: pet, status: .idle)
            let carrying = SpriteConfig.sheet(pet: pet, status: .carrying)
            XCTAssertEqual(carrying.filename, idle.filename,
                           "\(pet) must reuse idle sheet for carrying")
            XCTAssertEqual(carrying.frames, idle.frames)
        }
    }
}
