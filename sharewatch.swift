import Foundation
import AppKit
import Carbon

// CGSIsScreenWatcherPresent() 是 CoreGraphics 的私有函数，签名 @convention(c) () -> Bool。
// 任何程序持续采集屏幕（会议共享、录屏）时返回 true。
typealias BoolFn = @convention(c) () -> Bool

let cgPath = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
// 配置文件：每行一个要隐藏的应用，可写「应用名」（如 微信 / WeChat / 钉钉）或 bundle id
// （如 com.tencent.xinWeChat）。# 开头为注释，空行忽略。没配置就什么都不隐藏，由用户自己添加。
let configPath = NSHomeDirectory() + "/Library/Application Support/ShareHideApps/apps.conf"
let logPath = NSHomeDirectory() + "/Library/Logs/ShareHideApps.log"
let defaultTargets: [String] = []
let debounceCount = 2
let pollInterval: TimeInterval = 1.0
// 设置「共享时隐藏桌面图标」，存在 UserDefaults（com.sharehideapps.app）。
let hideDesktopKey = "hideDesktopIcons"
// 设置「共享时开启勿扰模式」。系统不给普通程序直接开关专注模式的接口，改为运行用户添加的
// 快捷指令（仓库里的 focus.shortcut，由 tools/make-focus-shortcut.py 生成），输入 on / off。
let focusKey = "focusWhileSharing"
let focusShortcutNames = ["共享时隐身 勿扰", "ShareHide Do Not Disturb"]

// 界面语言：系统首选语言是中文就显示中文，否则显示英文。日志始终用中文。
let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
func L(_ zh: String, _ en: String) -> String {
    return isChinese ? zh : en
}

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func timestamp() -> String {
    return timeFormatter.string(from: Date())
}

// 直接追加写日志文件：双击打开时不经过 launchd，没有 stdout 重定向。终端里运行时也打印一份。
func log(_ message: String) {
    let line = "\(timestamp()) \(message)\n"
    print(line, terminator: "")
    fflush(stdout)
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        h.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: false, encoding: .utf8)
    }
}

func fail(_ message: String) -> Never {
    log("错误: \(message)")
    exit(1)
}

func loadScreenWatcher() -> BoolFn {
    guard let handle = dlopen(cgPath, RTLD_NOW) else {
        let reason = String(cString: dlerror())
        fail("无法加载 CoreGraphics: \(reason)")
    }
    guard let symbol = dlsym(handle, "CGSIsScreenWatcherPresent") else {
        fail("CoreGraphics 中找不到 CGSIsScreenWatcherPresent")
    }
    return unsafeBitCast(symbol, to: BoolFn.self)
}

// 每次隐藏前重新读配置，改了配置不用重启。
func readTargets() -> [String] {
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
        return defaultTargets
    }
    // 每行取 # 之前的部分作为目标（bundle id 或应用名都不含 #），# 之后是给人看的注释。
    let items = text.split(whereSeparator: \.isNewline)
        .map { line -> String in
            let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            return code.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
    return items.isEmpty ? defaultTargets : items
}

// 一个条目是否匹配某个运行中的应用。
// bundle id：精确匹配（忽略大小写），最准。
// 显示名 / app 文件名：精确或「包含」匹配（忽略大小写），这样「Chrome」能匹配
// 「Google Chrome」，中文系统写英文名（如 Finder，显示名其实是「访达」）也能命中。
func matches(_ app: NSRunningApplication, _ target: String) -> Bool {
    let t = target.lowercased()
    if t.isEmpty { return false }
    if let bid = app.bundleIdentifier?.lowercased(), bid == t {
        return true
    }
    if let name = app.localizedName?.lowercased(), name == t || name.contains(t) {
        return true
    }
    if let url = app.bundleURL {
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        if base == t || base.contains(t) {
            return true
        }
    }
    return false
}

// 状态栏图标：菜单栏右上角，显示当前状态，并提供「打开配置」「退出」。
// 共享中且开了「隐藏桌面图标」时，多一项可以临时显示 / 重新隐藏桌面图标。
final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let desktopItem = NSMenuItem(title: "", action: #selector(toggleDesktop), keyEquivalent: "")
    private let desktopSeparator = NSMenuItem.separator()
    private let hideNowItem = NSMenuItem(title: "", action: #selector(hideNowFromMenu), keyEquivalent: "")

    override init() {
        super.init()
        if let button = item.button {
            let image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: appName)
            image?.isTemplate = true
            button.image = image
            button.toolTip = appName
        }
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        hideNowItem.target = self
        menu.addItem(hideNowItem)
        menu.addItem(.separator())
        desktopItem.target = self
        menu.addItem(desktopItem)
        menu.addItem(desktopSeparator)
        let open = NSMenuItem(title: L("打开配置…", "Settings…"), action: #selector(openConfig), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("退出「共享时隐身」", "Quit ShareHide"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self
        item.menu = menu
    }

    // 每次点开菜单都按当前配置刷新待命文字，否则启动后才添加应用，这里还会显示「还没添加应用」。
    // 共享中的文字（已隐藏哪些应用）不动。
    func menuWillOpen(_ menu: NSMenu) {
        if !isSharing {
            update(idleStatus())
        }
        // 快捷键真正由 registerHideHotKey 注册，这里只是在菜单里显示出来。
        // 菜单的快捷键位只能放单个字符，F5、空格这类直接写进标题。
        let hotKey = HotKey.current
        hideNowItem.title = L("立即隐藏", "Hide Apps Now")
        hideNowItem.keyEquivalent = ""
        hideNowItem.keyEquivalentModifierMask = []
        if hotKey.code >= 0 {
            if hotKey.key.count == 1 {
                hideNowItem.keyEquivalent = hotKey.key.lowercased()
                hideNowItem.keyEquivalentModifierMask = hotKey.modifiers
            } else {
                hideNowItem.title += "  " + hotKey.display
            }
        }
        let covering = isSharing && UserDefaults.standard.bool(forKey: hideDesktopKey)
        desktopItem.isHidden = !covering
        desktopSeparator.isHidden = !covering
        desktopItem.title = desktopRevealed
            ? L("重新隐藏桌面图标", "Hide Desktop Icons Again")
            : L("显示桌面图标", "Show Desktop Icons")
    }

    func update(_ text: String) {
        statusLine.title = text
    }

    @objc func hideNowFromMenu() {
        hideNow()
    }

    @objc func toggleDesktop() {
        desktopRevealed ? coverDesktopAgain() : revealDesktop()
    }

    @objc func revealFromCover() {
        revealDesktop()
    }

    // 关掉设置里的开关，配置窗口里的勾选会跟着变。
    @objc func stopHidingDesktop() {
        UserDefaults.standard.set(false, forKey: hideDesktopKey)
        updateDesktopCover()
    }

    @objc func openConfig() {
        (NSApp.delegate as? AppDelegate)?.showWindow()
    }

    // 和配置窗口里按 ⌘Q 一样，整个程序退出。正常退出不会被 launchd 立刻拉起，
    // 下次登录或手动打开「共享时隐身」时再启动。
    @objc func quit() {
        NSApp.terminate(nil)
    }
}

let appName = L("共享时隐身", "ShareHide")
let isScreenWatcherPresent = loadScreenWatcher()
let dryRun = CommandLine.arguments.contains("--dry-run")

// 状态栏控制器在 NSApplication 启动后创建。
var statusController: StatusController!

func idleStatus() -> String {
    return readTargets().isEmpty
        ? L("还没添加应用，点「打开配置…」添加", "No apps added yet. Choose “Settings…” to add some.")
        : L("待命（共享时自动隐藏）", "Ready (hides apps while sharing)")
}

// 通过 System Events 把进程的 visible 设为 false。需要「自动化」权限。
func hideViaSystemEvents(_ app: NSRunningApplication) -> Bool {
    guard let bid = app.bundleIdentifier, !bid.contains("\"") else { return false }
    let source = "tell application \"System Events\" to set visible of (first process whose bundle identifier is \"\(bid)\") to false"
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error = error {
        log("System Events 隐藏失败：\(error[NSAppleScript.errorMessage] ?? "未知错误")")
        return false
    }
    return true
}

// 菜单里的状态只在共享中显示隐藏结果；没在共享时（按快捷键隐藏）点开菜单会显示待命文字。
func hideTargets() {
    let targets = readTargets()
    if targets.isEmpty {
        log("还没配置要隐藏的应用，跳过")
        statusController.update(isSharing ? L("正在共享（还没添加应用）", "Sharing (no apps added yet)") : idleStatus())
        return
    }
    // 只看正常的前台应用（有 Dock 图标的），排除输入法、各类 helper 和 Finder 扩展，
    // 避免「包含」匹配误伤后台进程。
    let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    var hitApps: [NSRunningApplication] = []
    for target in targets {
        for app in running where matches(app, target) && !hitApps.contains(app) {
            hitApps.append(app)
        }
    }
    if hitApps.isEmpty {
        log("目标应用都没在运行（配置：\(targets.joined(separator: "、"))）")
        if isSharing {
            statusController.update(L("正在共享（配置的应用都没在运行）", "Sharing (none of your apps are running)"))
        }
        return
    }
    let names = hitApps.map { $0.localizedName ?? $0.bundleIdentifier ?? "?" }.joined(separator: L("、", ", "))
    if dryRun {
        log("[dry-run] 将隐藏：\(names)")
        return
    }
    // hide() 的返回值不可靠（实测返回 false 但随后确实隐藏），改为稍等后看 isHidden。
    for app in hitApps {
        _ = app.hide()
    }
    Thread.sleep(forTimeInterval: 0.5)
    // 部分应用（如 Telegram）对 hide() 无效，用 System Events 的 visible=false 兜底。
    for app in hitApps where app.isHidden == false {
        _ = hideViaSystemEvents(app)
    }
    Thread.sleep(forTimeInterval: 0.5)
    let stillVisible = hitApps.filter { !$0.isHidden }.compactMap { $0.localizedName }
    if stillVisible.isEmpty {
        log("已隐藏：\(names)")
        if isSharing {
            statusController.update(L("正在共享，已隐藏：\(names)", "Sharing, hidden: \(names)"))
        }
    } else {
        log("已隐藏：\(names)（未确认隐藏：\(stillVisible.joined(separator: "、"))）")
        if isSharing {
            statusController.update(L("正在共享，已隐藏：\(names)（部分未确认）", "Sharing, hidden: \(names) (some unconfirmed)"))
        }
    }
}

// 全局快捷键（默认 ⌃⌥H，可在配置窗口改）：不等检测，立刻隐藏列表里的应用，可以在开始共享前先按一下。
// 检测要连续两次（约 2 秒）才确认在共享，这段时间里窗口可能被看到。
// 用 Carbon 的 RegisterEventHotKey，不需要「辅助功能」权限。
struct HotKey: Equatable {
    var code: Int                     // 虚拟键码；-1 表示不用快捷键
    var modifiers: NSEvent.ModifierFlags
    var key: String                   // 显示用的键名，如 H、F5、空格

    static let standard = HotKey(code: kVK_ANSI_H, modifiers: [.control, .option], key: "H")
    static let none = HotKey(code: -1, modifiers: [], key: "")

    static var current: HotKey {
        let d = UserDefaults.standard
        guard d.object(forKey: "hotKeyCode") != nil else { return .standard }
        return HotKey(code: d.integer(forKey: "hotKeyCode"),
                      modifiers: NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: "hotKeyModifiers"))),
                      key: d.string(forKey: "hotKeyKey") ?? "")
    }

    func save() {
        let d = UserDefaults.standard
        if self == .standard {
            ["hotKeyCode", "hotKeyModifiers", "hotKeyKey"].forEach { d.removeObject(forKey: $0) }
            return
        }
        d.set(code, forKey: "hotKeyCode")
        d.set(Int(modifiers.rawValue), forKey: "hotKeyModifiers")
        d.set(key, forKey: "hotKeyKey")
    }

    var display: String {
        if code < 0 { return L("无", "None") }
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key
    }

    var carbonModifiers: UInt32 {
        var m = 0
        if modifiers.contains(.control) { m |= controlKey }
        if modifiers.contains(.option) { m |= optionKey }
        if modifiers.contains(.shift) { m |= shiftKey }
        if modifiers.contains(.command) { m |= cmdKey }
        return UInt32(m)
    }

    // 从按键事件生成；键名用不带修饰键时的字符，这样 ⌥ 和 ⇧ 组合也显示成键帽上的字母
    init(event: NSEvent) {
        let special: [Int: String] = [
            kVK_Space: L("空格", "Space"), kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        let code = Int(event.keyCode)
        self.init(code: code,
                  modifiers: event.modifierFlags.intersection([.control, .option, .shift, .command]),
                  key: special[code] ?? (event.characters(byApplyingModifiers: [])?.uppercased() ?? "?"))
    }

    init(code: Int, modifiers: NSEvent.ModifierFlags, key: String) {
        self.code = code
        self.modifiers = modifiers
        self.key = key
    }
}

var hideHotKey: EventHotKeyRef?
var hotKeyHandlerInstalled = false

// 按当前设置重新注册；返回是否成功（不用快捷键也算成功）
@discardableResult
func registerHideHotKey() -> Bool {
    if !hotKeyHandlerInstalled {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            hideNow()
            return noErr
        }, 1, &spec, nil, nil)
        hotKeyHandlerInstalled = true
    }
    unregisterHideHotKey()
    let hotKey = HotKey.current
    guard hotKey.code >= 0 else { return true }
    let id = EventHotKeyID(signature: OSType(0x5348_4944), id: 1)  // 'SHID'
    let status = RegisterEventHotKey(UInt32(hotKey.code), hotKey.carbonModifiers, id,
                                     GetApplicationEventTarget(), 0, &hideHotKey)
    if status != noErr {
        log("快捷键 \(hotKey.display) 注册失败（\(status)），可能被别的程序占用")
        return false
    }
    return true
}

// 录新快捷键时先停用旧的，免得按下去就触发隐藏
func unregisterHideHotKey() {
    if let ref = hideHotKey {
        UnregisterEventHotKey(ref)
        hideHotKey = nil
    }
}

func hideNow() {
    log("手动立即隐藏")
    hideTargets()
}

// 快捷指令在后台串行运行（每次约 1 秒），不卡菜单栏；开、关按顺序执行。
let focusQueue = DispatchQueue(label: "com.sharehideapps.focus")
// 这次共享是不是我们开的勿扰：结束时只关自己开的（共享中途才打开设置的，结束时不去关）。
var focusTurnedOn = false

func runShortcuts(_ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

// 用户已添加的勿扰快捷指令名（中文或英文名都认），没有就返回 nil。会运行几百毫秒，别在主线程调。
func installedFocusShortcut() -> String? {
    let result = runShortcuts(["list"])
    guard result.status == 0 else { return nil }
    let names = Set(result.output.split(separator: "\n").map(String.init))
    return focusShortcutNames.first { names.contains($0) }
}

func setFocus(_ on: Bool) {
    if dryRun {
        log("[dry-run] 将\(on ? "开启" : "关闭")勿扰")
        return
    }
    focusQueue.async {
        guard let name = installedFocusShortcut() else {
            log("没找到勿扰快捷指令，跳过（在配置窗口里点「添加快捷指令…」）")
            return
        }
        let input = NSTemporaryDirectory() + "com.sharehideapps.focus.txt"
        try? (on ? "on" : "off").write(toFile: input, atomically: true, encoding: .utf8)
        let result = runShortcuts(["run", name, "-i", input])
        if result.status == 0 {
            log(on ? "已开启勿扰" : "已关闭勿扰")
        } else {
            log("运行快捷指令「\(name)」失败（\(result.status)）：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

// 盖板上右键弹出的菜单。盖板吃掉了桌面的点击和右键，这里给出临时显示桌面的入口。
final class CoverView: NSView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let reveal = NSMenuItem(title: L("显示桌面图标（仅本次）", "Show Desktop Icons (This Time Only)"),
                                action: #selector(StatusController.revealFromCover), keyEquivalent: "")
        reveal.target = statusController
        menu.addItem(reveal)
        let stop = NSMenuItem(title: L("以后共享时不再隐藏桌面图标", "Stop Hiding Desktop Icons"),
                              action: #selector(StatusController.stopHidingDesktop), keyEquivalent: "")
        stop.target = statusController
        menu.addItem(stop)
        return menu
    }
}

// 共享时用壁纸盖住桌面：每块屏幕放一个铺满壁纸的窗口，层级比桌面图标高一层、比普通窗口低，
// 所以只挡住桌面图标和小组件，不挡应用窗口。不改访达设置，也不用重启访达，共享画面不会闪。
final class DesktopCover {
    private var panels: [NSPanel] = []
    var isShown: Bool { !panels.isEmpty }

    func show() {
        guard panels.isEmpty else { return }
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        for screen in NSScreen.screens {
            // 不接收点击会让点击落到下面看不见的图标上（可能误开文件），所以盖板自己吃掉点击；
            // nonactivatingPanel 让点它时不会把本程序切到前台。
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = level
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.hasShadow = false
            panel.setFrame(screen.frame, display: false)
            panel.contentView = wallpaperView(for: screen)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    // 按系统的壁纸缩放方式摆放图片，空出来的地方用壁纸设置里的填充色。
    private func wallpaperView(for screen: NSScreen) -> NSView {
        let view = CoverView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let fill = (options[.fillColor] as? NSColor) ?? .black
        view.layer?.backgroundColor = fill.cgColor
        if let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) {
            view.layer?.contents = image
            view.layer?.contentsScale = screen.backingScaleFactor
            let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
                ?? .scaleProportionallyUpOrDown
            let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
            switch scaling {
            case .scaleAxesIndependently: view.layer?.contentsGravity = .resize
            case .scaleNone: view.layer?.contentsGravity = .center
            default: view.layer?.contentsGravity = clipping ? .resizeAspectFill : .resizeAspect
            }
        }
        return view
    }
}

let desktopCover = DesktopCover()

// 用户在这次共享里选了「显示桌面图标」。只管这一次，开始和结束共享时都清掉。
var desktopRevealed = false

// 共享中、开了设置、这次没选显示，就盖住桌面，否则拿掉。开始 / 结束共享、改设置、屏幕变化时调用。
func updateDesktopCover() {
    let want = isSharing && UserDefaults.standard.bool(forKey: hideDesktopKey) && !desktopRevealed
    if want && !desktopCover.isShown {
        desktopCover.show()
        log("已盖住桌面图标")
    } else if !want && desktopCover.isShown {
        desktopCover.hide()
        log("已恢复桌面图标")
    }
}

func revealDesktop() {
    desktopRevealed = true
    log("用户选择显示桌面图标（仅本次）")
    updateDesktopCover()
}

func coverDesktopAgain() {
    desktopRevealed = false
    log("用户选择重新隐藏桌面图标")
    updateDesktopCover()
}

var isSharing = false
var trueStreak = 0
var falseStreak = 0

func tick() {
    let present = isScreenWatcherPresent()

    if present {
        trueStreak += 1
        falseStreak = 0
    } else {
        falseStreak += 1
        trueStreak = 0
    }

    if !isSharing && trueStreak >= debounceCount {
        isSharing = true
        desktopRevealed = false
        log("开始共享")
        if UserDefaults.standard.bool(forKey: focusKey) {
            focusTurnedOn = true
            setFocus(true)
        }
        updateDesktopCover()
        hideTargets()
    } else if isSharing && falseStreak >= debounceCount {
        isSharing = false
        desktopRevealed = false
        log("共享结束")
        if focusTurnedOn {
            focusTurnedOn = false
            setFocus(false)
        }
        updateDesktopCover()
        statusController.update(idleStatus())
    }
}
