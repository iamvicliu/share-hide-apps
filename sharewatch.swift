import Foundation
import AppKit

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
final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        if let button = item.button {
            let image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "共享时隐身")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "共享时隐身"
        }
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "打开配置…", action: #selector(openConfig), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出共享时隐身", action: #selector(quit), keyEquivalent: "q")
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
    }

    func update(_ text: String) {
        statusLine.title = text
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

let isScreenWatcherPresent = loadScreenWatcher()
let dryRun = CommandLine.arguments.contains("--dry-run")

// 状态栏控制器在 NSApplication 启动后创建。
var statusController: StatusController!

func idleStatus() -> String {
    return readTargets().isEmpty ? "还没添加应用，点「打开配置…」添加" : "待命（共享时自动隐藏）"
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

func hideTargets() {
    let targets = readTargets()
    if targets.isEmpty {
        log("还没配置要隐藏的应用，跳过")
        statusController.update("正在共享（还没添加应用）")
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
        statusController.update("正在共享（配置的应用都没在运行）")
        return
    }
    let names = hitApps.map { $0.localizedName ?? $0.bundleIdentifier ?? "?" }.joined(separator: "、")
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
        statusController.update("正在共享，已隐藏：\(names)")
    } else {
        log("已隐藏：\(names)（未确认隐藏：\(stillVisible.joined(separator: "、"))）")
        statusController.update("正在共享，已隐藏：\(names)（部分未确认）")
    }
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
        log("开始共享")
        hideTargets()
    } else if isSharing && falseStreak >= debounceCount {
        isSharing = false
        log("共享结束")
        statusController.update(idleStatus())
    }
}
