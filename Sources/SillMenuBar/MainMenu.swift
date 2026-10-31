import AppKit

/// The main menu of an app that never shows one. An accessory app (LSUIElement) has no menu bar,
/// but AppKit still routes key equivalents through the main menu, so without this ⌘C, ⌘A, ⌘F,
/// ⌘W and ⌘Q would do nothing in the Settings and Log windows.
enum MainMenu {
    @MainActor
    static func make() -> NSMenu {
        let main = NSMenu()

        let sill = submenu(in: main, title: "Sill")
        sill.addItem(withTitle: "Sill 정보", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        sill.addItem(.separator())
        sill.addItem(withTitle: "설정…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        sill.addItem(.separator())
        sill.addItem(withTitle: "Sill 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = submenu(in: main, title: "편집")
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "다시 실행", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let findItem = edit.addItem(withTitle: "찾기", action: nil, keyEquivalent: "")
        let find = NSMenu(title: "찾기")
        // performFindPanelAction: with the NSFindPanelAction tags, which a text view with a find
        // bar (the Log window) answers.
        let actions: [(String, String, NSFindPanelAction)] = [("찾기…", "f", .showFindPanel), ("다음 찾기", "g", .next),
                                                              ("이전 찾기", "G", .previous)]
        for (title, key, tag) in actions {
            let item = find.addItem(withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            item.tag = Int(tag.rawValue)
        }
        findItem.submenu = find

        let window = submenu(in: main, title: "윈도우")
        window.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        return main
    }

    @MainActor
    private static func submenu(in main: NSMenu, title: String) -> NSMenu {
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }
}
