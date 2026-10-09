import Foundation
import ObjectiveC
import Observation
import SwiftUI

/// The interface language chosen from the app menu. English stays the default so an existing
/// install keeps the copy it has always shown; Chinese applies only after it is chosen.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh-Hans"

    var id: String { rawValue }
    /// Language names stay in their own language, in every interface language.
    var menuTitle: String { self == .english ? "English" : "中文" }
    static let storageKey = "app.language"

    static func resolved() -> AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let language = AppLanguage(rawValue: raw) else { return .english }
        return language
    }
}

/// Applies the chosen language to every lookup, including SwiftUI's, and publishes a change
/// so the open window and menus are built again.
@MainActor
@Observable
final class AppLanguageController {
    static let shared = AppLanguageController()
    private(set) var language: AppLanguage

    private init() {
        language = AppLanguage.resolved()
        AppLanguageBundle.use(language)
    }

    func select(_ language: AppLanguage) {
        guard language != self.language else { return }
        UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.storageKey)
        AppLanguageBundle.use(language)
        self.language = language
        // SwiftUI rebuilds the menu bar from the Mac's language after this returns.
        DispatchQueue.main.async { self.applyStandardMenuTitles() }
    }

    /// File, Edit, View, Window and Help are drawn from the language AppKit read at launch
    /// (`AppleLanguages`). Titles are updated here as well; a relaunch is what changes those five.
    func applyStandardMenuTitles() {
        let chinese = language == .chinese
        let names = [("File", "文件"), ("Edit", "编辑"), ("View", "显示"), ("Window", "窗口"), ("Help", "帮助")]
        for item in NSApp.mainMenu?.items ?? [] {
            for (english, translated) in names {
                let isViewAlias = english == "View" && item.title == "视图"
                guard item.title == english || item.title == translated || isViewAlias else { continue }
                let title = chinese ? translated : english
                item.title = title
                item.attributedTitle = NSAttributedString(string: title)
                break
            }
        }
    }
}

/// `Bundle.main` follows the Mac's language. The menu has to be able to show Chinese on an
/// English Mac, and English on a Chinese one, without restarting, so lookups on the main
/// bundle are answered from the chosen language instead.
nonisolated enum AppLanguageBundle {
    private static let lock = NSLock()
    private static var installed = false
    private static var code = AppLanguage.english.rawValue
    private static var chinese: Bundle?

    static var currentCode: String {
        lock.lock()
        defer { lock.unlock() }
        return code
    }

    static func use(_ language: AppLanguage) {
        // Resolve the lproj before the swizzle. Afterwards this call can re-enter
        // `preferredLocalizations`, which takes the same lock.
        let bundle = language == .chinese
            ? Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap { Bundle(path: $0) }
            : nil
        lock.lock()
        if !installed {
            installSystemLanguageBypass()
            object_setClass(Bundle.main, LocalizedBundle.self)
            installed = true
        }
        code = language.rawValue
        chinese = bundle
        lock.unlock()
        // AppKit names File, Edit, View, Window and Help from this, read when the process starts.
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }

    /// SwiftUI asks for a string with the Mac's language list (`zh-Hans` on this machine) and
    /// never calls the three-argument lookup. Those selectors have to ignore that list.
    private static func installSystemLanguageBypass() {
        let stringMethod = unsafeBitCast(interfaceStringIMP, to: IMP.self)
        for name in ["localizedStringForKey:value:table:localizations:", "localizedStringForKey:value:table:localization:"] {
            class_addMethod(LocalizedBundle.self, NSSelectorFromString(name), stringMethod, "@@:@@@@")
        }
        class_addMethod(LocalizedBundle.self, NSSelectorFromString("localizedAttributedStringForKey:value:table:"),
                        unsafeBitCast(interfaceAttributedIMP, to: IMP.self), "@@:@@@")
        class_addMethod(LocalizedBundle.self, NSSelectorFromString("localizedAttributedStringForKey:value:table:localization:"),
                        unsafeBitCast(interfaceAttributedLocalizationIMP, to: IMP.self), "@@:@@@@")
    }

    fileprivate static func translation(for key: String, table: String?) -> String {
        lock.lock()
        let language = code
        let bundle = chinese
        lock.unlock()
        guard language == AppLanguage.chinese.rawValue, let bundle else { return key }
        return bundle.localizedString(forKey: key, value: key, table: table)
    }
}

/// Subclass swapped onto `Bundle.main`. The Chinese `lproj` bundle is a different instance,
/// so asking it for a string does not come back through this override.
private final class LocalizedBundle: Bundle, @unchecked Sendable {
    override var preferredLocalizations: [String] {
        [AppLanguageBundle.currentCode]
    }

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        AppLanguageBundle.translation(for: key, table: tableName)
    }
}

nonisolated(unsafe) private let interfaceStringIMP: @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, AnyObject?) -> NSString = { _, _, key, _, table, _ in
    AppLanguageBundle.translation(for: String(key), table: table.map { String($0) }) as NSString
}

nonisolated(unsafe) private let interfaceAttributedIMP: @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?) -> NSAttributedString = { _, _, key, _, table in
    NSAttributedString(string: AppLanguageBundle.translation(for: String(key), table: table.map { String($0) }))
}

nonisolated(unsafe) private let interfaceAttributedLocalizationIMP: @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, NSString?) -> NSAttributedString = { _, _, key, _, table, _ in
    NSAttributedString(string: AppLanguageBundle.translation(for: String(key), table: table.map { String($0) }))
}

extension String {
    /// This English interface string in the language chosen in the app menu.
    var localized: String {
        guard UserDefaults.standard.string(forKey: AppLanguage.storageKey) == AppLanguage.chinese.rawValue else { return self }
        return Bundle.main.localizedString(forKey: self, value: self, table: nil)
    }
}

extension LocalizedStringKey {
    /// Resolved when the control is shown. A `String` title is fixed while the menu is built, so items
    /// assembled from a name (Black & White…, the filter list) stayed English after the language changed.
    init(interface key: String) {
        self.init(stringLiteral: key)
    }
}
