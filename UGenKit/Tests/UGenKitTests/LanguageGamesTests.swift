import XCTest
@testable import StudioCore

/// Language examples. Nutrition and code-block cases are the demos' own (Calories/test_nutrition.py,
/// OfflineCode/test_codeblocks.py), ported.
final class LanguageGamesTests: XCTestCase {
    func testCleanJSON() {
        XCTAssertEqual(Nutrition.parseItems(#"[{"item":"炸雞腿便當","portion":"1 份","kcal":850,"protein_g":35}]"#),
                       [Nutrition.Item(item: "炸雞腿便當", portion: "1 份", kcal: 850, proteinGrams: 35)])
    }

    func testWrappedInTextAndFence() {
        let t = "好的,以下是估算:\n```json\n[{\"item\":\"珍珠奶茶\",\"portion\":\"700ml\",\"kcal\":\"約 500 大卡\",\"protein_g\":7.6}]\n```\n希望有幫助。"
        let r = Nutrition.parseItems(t)
        XCTAssertEqual(r.first?.item, "珍珠奶茶"); XCTAssertEqual(r.first?.kcal, 500); XCTAssertEqual(r.first?.proteinGrams, 8)
    }

    func testSingleQuotesAndTrailingComma() {
        let r = Nutrition.parseItems("[{'item': '白飯', 'portion': '一碗', 'kcal': 280, 'protein_g': 5,},]")
        XCTAssertEqual(r.first?.item, "白飯"); XCTAssertEqual(r.first?.kcal, 280)
    }

    func testGarbageReturnsEmpty() {
        XCTAssertEqual(Nutrition.parseItems("這張照片沒有食物。"), [])
        XCTAssertEqual(Nutrition.parseItems(""), [])
        XCTAssertEqual(Nutrition.parseItems("["), [])
    }

    func testUnquotedKeysAndTruncatedArray() {
        let t = "```json\n[\n  {\n    \"item\":\"茶包\",\n    portion:\"一包\",\n    kcal:0,\n    protein_g:0\n  },\n  {\n    \"item\":\"牛奶\",\n    portion:\"一杯(250ml)\",\n    kcal:367,\n    protein_g:+14."
        let r = Nutrition.parseItems(t)
        XCTAssertEqual(r.map(\.item), ["茶包"])
        XCTAssertEqual(r.first?.portion, "一包")
    }

    func testChineseKeyAliasesAndSpaceInKey() {
        let t = "[\n  {\"品名\":\"牛奶\",\"portion\":\"一杯\",\"kcal\":210,\" protein_g\":3.5},\n  {\"品名\":\"巧克力棒\",\"份量\":\"一包\",\"熱量\":486,\"蛋白質\":7.9}\n]"
        let r = Nutrition.parseItems(t)
        XCTAssertEqual(r.map(\.item), ["牛奶", "巧克力棒"])
        XCTAssertEqual(r[0].proteinGrams, 4); XCTAssertEqual(r[1].kcal, 486); XCTAssertEqual(r[1].portion, "一包")
    }

    func testOneCalorieIsNotABoolean() {
        XCTAssertEqual(Nutrition.parseItems(#"[{"item":"gum","kcal":1,"protein_g":true}]"#).first?.kcal, 1)
        XCTAssertEqual(Nutrition.parseItems(#"[{"item":"gum","kcal":1,"protein_g":true}]"#).first?.proteinGrams, 0)
    }

    func testTotalsAndDailyLog() throws {
        let items = [Nutrition.Item(item: "a", kcal: 100, proteinGrams: 3), Nutrition.Item(item: "b", kcal: 50, proteinGrams: 2)]
        XCTAssertTrue(Nutrition.totals(items) == (150, 5))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("today-\(UUID().uuidString).json")
        var log = Nutrition.DailyLog.load(url)
        log.add([Nutrition.Item(item: "x", kcal: 300, proteinGrams: 1)], saveTo: url)
        let again = Nutrition.DailyLog.load(url)
        XCTAssertEqual(again.kcal, 300); XCTAssertEqual(again.meals.count, 1)
        let tomorrow = Date().addingTimeInterval(86_400 * 1.5)
        XCTAssertEqual(Nutrition.DailyLog.load(url, now: tomorrow).kcal, 0)   // a new day starts empty
    }

    func testSplitTextAndCode() {
        XCTAssertEqual(CodeBlocks.split("說明一下\n```python\nprint(1)\n```\n結尾"),
                       [.text("說明一下\n"), .code(language: "python", code: "print(1)"), .text("\n結尾")])
    }

    func testLanguageAliasEmptyAndCRLF() {
        XCTAssertTrue(CodeBlocks.blocks("```py\nx=1\n```").elementsEqual([("python", "x=1")], by: ==))
        XCTAssertTrue(CodeBlocks.blocks("```\nplain\n```").elementsEqual([("text", "plain")], by: ==))
        XCTAssertTrue(CodeBlocks.blocks("```python\r\nx=1\r\ny=2\r\n```").elementsEqual([("python", "x=1\ny=2")], by: ==))
        XCTAssertTrue(CodeBlocks.blocks("```js\nconsole.log(1)\n```").elementsEqual([("javascript", "console.log(1)")], by: ==))
    }

    func testUnclosedFenceWhileStreaming() {
        XCTAssertTrue(CodeBlocks.blocks("開頭\n```python\nfor i in range(3):\n    pri").elementsEqual([("python", "for i in range(3):\n    pri")], by: ==))
        XCTAssertEqual(CodeBlocks.textOnly("開頭\n```python\nx"), "開頭\n[python code → shown on the right]")
        XCTAssertEqual(CodeBlocks.textOnly("先說明\n```python"), "先說明")
        XCTAssertEqual(CodeBlocks.textOnly("先說明\n```"), "先說明")
    }

    func testLastCodePrefersAndSkipsEmpty() {
        let t = "```bash\npip install x\n```\n```javascript\nlet x = 1\n```\n```bash\nls\n```"
        XCTAssertTrue(CodeBlocks.last(t)! == ("javascript", "let x = 1"))
        XCTAssertTrue(CodeBlocks.last("```javascript\n\n```\n```bash\nls\n```")! == ("bash", "ls"))
        XCTAssertNil(CodeBlocks.last("no code"))
    }

    func testMeetingSummaryCheck() {
        XCTAssertTrue(MeetingNotes.looksValid(MeetingNotes.exampleOutput))
        XCTAssertFalse(MeetingNotes.looksValid("Key Points: nothing"))
        XCTAssertTrue(MeetingNotes.userMessage("hello").contains("----- Transcript -----\nhello"))
    }

    func testThinkingRemoved() {
        XCTAssertEqual(ModelText.withoutThinking("<think>hmm</think>\nAnswer"), "Answer")
        XCTAssertEqual(ModelText.withoutThinking("Answer <think>still going"), "Answer")
    }
}
