import CoreGraphics
import XCTest
@testable import StudioCore

/// "Catch the eggs" rules: falling eggs, catches by the nearest player's hand, misses, rising speed, players.
final class EggGameTests: XCTestCase {
    /// A person with only the right wrist (and elbow, straight below it) seen, the palm at `hand`.
    private func person(_ id: Int?, hand: CGPoint, tall: Double = 300) -> BodyPose {
        var k = Array(repeating: BodyPoint(0, 0, 0), count: 17)
        k[BodyPose.nose] = BodyPoint(hand.x, 700 - tall, 0.9)
        k[BodyPose.leftAnkle] = BodyPoint(hand.x, 700, 0.9)
        // Elbow 70 px below the wrist: the palm is 0.35 * 70 above the wrist.
        k[BodyPose.rightWrist] = BodyPoint(hand.x, hand.y + 24.5, 0.9)
        k[BodyPose.rightElbow] = BodyPoint(hand.x, hand.y + 94.5, 0.9)
        return BodyPose(points: k, width: EggGame.width, height: 750, id: id)
    }

    func testPalmIsPastTheWrist() {
        let palm = EggGame.palms(person(1, hand: CGPoint(x: 100, y: 200)))
        XCTAssertEqual(palm.count, 1)
        XCTAssertEqual(palm[0].y, 200, accuracy: 0.01)
    }

    func testAnEggIsCaughtOrMissed() {
        let game = EggGame(random: { 0.5 })   // not golden, middle of the field
        game.start(now: 0)
        game.update([], now: 0.6, dt: 0)
        XCTAssertEqual(game.eggs.count, 1)
        let egg = game.eggs[0]
        XCTAssertEqual(egg.x, EggGame.width / 2, accuracy: 1)
        // A hand far away catches nothing; the egg keeps falling.
        game.update([person(7, hand: CGPoint(x: 100, y: 100))], now: 0.7, dt: 0.1)
        XCTAssertEqual(game.eggs.count, 1)
        XCTAssertGreaterThan(game.eggs[0].y, egg.y)
        // A hand under it catches it: player 1 (slot 0) scores.
        let events = game.update([person(7, hand: CGPoint(x: game.eggs[0].x, y: game.eggs[0].y + 40))], now: 0.75, dt: 0.05)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(game.scores[0], 1)
        XCTAssertEqual(game.pops.first?.text, "+1")
        XCTAssertTrue(game.eggs.isEmpty)
        // Nobody there: the next egg falls through the bottom.
        var missed = 0
        var t = 0.8
        while missed == 0 && t < 20 {
            t += 0.05
            missed += game.update([], now: t, dt: 0.05).filter { if case .missed = $0 { return true } else { return false } }.count
        }
        XCTAssertEqual(game.misses, 1)
        XCTAssertEqual(game.scores[0], 1)
    }

    func testItGetsFasterAndEnds() {
        let game = EggGame(seconds: 60, random: { 0.5 })
        game.start(now: 0)
        XCTAssertGreaterThan(game.fallSpeed(now: 59), game.fallSpeed(now: 1) * 2)
        XCTAssertLessThan(game.spawnGap(now: 59), game.spawnGap(now: 1) / 2)
        game.playerCount = 2
        XCTAssertLessThan(game.spawnGap(now: 1), 1.1 / 1.5)   // more eggs for two
        game.update([], now: 61, dt: 0.03)
        XCTAssertEqual(game.phase, .over)
    }

    func testPlayersArePickedBetweenRounds() {
        let game = EggGame()
        game.playerCount = 2
        let far = CGPoint(x: 500, y: 600)   // the hands low, inside each body's height
        // Between rounds the players are the two biggest people, picked again every frame.
        game.update([person(3, hand: far, tall: 450), person(5, hand: far, tall: 400)], now: -2, dt: 0)
        XCTAssertEqual(Set(game.players.keys), [3, 5])
        game.update([person(3, hand: far, tall: 450), person(5, hand: far, tall: 400), person(9, hand: far, tall: 500)], now: -1, dt: 0)
        XCTAssertEqual(Set(game.players.keys), [3, 9])
        // In a round they stay players even when someone else is bigger.
        game.start(now: 0)
        game.update([person(3, hand: far, tall: 200), person(5, hand: far, tall: 400), person(9, hand: far, tall: 500)], now: 0.1, dt: 0)
        XCTAssertEqual(Set(game.players.keys), [3, 9])
    }

    func testPlayersSlotsAfterLeaving() {
        let game = EggGame()
        game.playerCount = 2
        game.start(now: -0.5)
        let far = CGPoint(x: 500, y: 600)
        game.update([person(3, hand: far, tall: 200), person(5, hand: far, tall: 400), person(9, hand: far, tall: 300)], now: 0, dt: 0)
        // The two biggest people play; the third waits.
        XCTAssertEqual(game.players, [5: 0, 9: 1])
        // Person 5 walks away: after 1.5 s their slot goes to person 3.
        game.update([person(3, hand: far), person(9, hand: far)], now: 1, dt: 0)
        XCTAssertEqual(game.players, [5: 0, 9: 1])
        game.update([person(3, hand: far), person(9, hand: far)], now: 2, dt: 0)
        XCTAssertEqual(game.players, [3: 0, 9: 1])
        // Untracked poses never play; back to one player keeps only slot 0.
        game.playerCount = 1
        game.update([person(nil, hand: far), person(3, hand: far), person(9, hand: far)], now: 2.1, dt: 0)
        XCTAssertEqual(game.players, [3: 0])
        XCTAssertEqual(game.hands.count, 1)
    }

    func testCatchesGoToTheNearestHand() {
        let game = EggGame(random: { 0.5 })
        game.playerCount = 2
        game.start(now: 0)
        game.update([], now: 0.6, dt: 0)
        let egg = game.eggs[0]
        game.update([person(1, hand: CGPoint(x: egg.x - 50, y: egg.y), tall: 400), person(2, hand: CGPoint(x: egg.x + 10, y: egg.y))],
                    now: 0.6, dt: 0)
        XCTAssertEqual(game.scores, [0, 1])
    }
}
