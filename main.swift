import Foundation
import AppKit
import SwiftUI

// 「共享时隐身」入口：一个程序同时负责菜单栏图标、共享检测和配置窗口。
// 平时只有菜单栏图标；打开配置窗口时才出现 Dock 图标，关窗口（X）后回到只有菜单栏图标。
// 菜单栏「退出」或窗口里 ⌘Q 才真正退出。
//
// 参数：
//   --background  开机自启时用，只启动菜单栏图标，不弹窗口
//   --once        只打印一次当前是否在共享（sharing / not-sharing）然后退出
//   --dry-run     只记录会隐藏哪些应用，不真的隐藏

let arguments = Set(CommandLine.arguments.dropFirst())
let showWindowNotification = Notification.Name("com.sharehideapps.show")

if arguments.contains("--once") {
    print(isScreenWatcherPresent() ? "sharing" : "not-sharing")
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        didLaunch = true

        NSApp.setActivationPolicy(.accessory)
        setupMenu()

        log("启动（每 \(Int(pollInterval)) 秒检查一次\(dryRun ? "，dry-run 模式" : "")）")
        log("配置文件：\(configPath)")
        let targets = readTargets()
        log("当前目标：\(targets.isEmpty ? "(未配置，用配置窗口添加)" : targets.joined(separator: "、"))")

        statusController = StatusController()
        statusController.update(idleStatus())
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in tick() }
        timer.tolerance = pollInterval * 0.3
        pollTimer = timer

        // 共享中接上或拔掉显示器、改分辨率时，按新的屏幕重新盖一遍桌面。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            if desktopCover.isShown {
                desktopCover.hide()
                desktopCover.show()
            }
        }

        if wantsWindow {
            showWindow()
        }
    }

    // 程序已在运行时再双击 app（或从启动台打开），系统会走到这里。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("退出")
    }

    func showWindow() {
        if window == nil {
            let hosting = NSHostingView(rootView: ContentView())
            hosting.layoutSubtreeIfNeeded()
            let size = hosting.fittingSize
            let w = NSWindow(
                contentRect: NSRect(origin: .zero, size: size.height > 0 ? size : NSSize(width: 400, height: 660)),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = appName
            w.contentView = hosting
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // 关窗口只是收起界面：释放窗口（连同列表监听），Dock 图标消失，检测照常运行。
    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // 自己建主菜单（中文或英文），否则菜单项会显示可执行名 ShareHideApps
    private func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("隐藏「共享时隐身」", "Hide ShareHide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L("关闭窗口", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("退出「共享时隐身」", "Quit ShareHide"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}

setvbuf(stdout, nil, _IONBF, 0)

// 先听「弹窗口」通知，再抢单实例锁：抢不到锁的那份只会在别人拿到锁之后才发通知，
// 拿到锁的那份此时一定已经在听了。
var wantsWindow = !arguments.contains("--background")
var didLaunch = false
DistributedNotificationCenter.default().addObserver(
    forName: showWindowNotification, object: nil, queue: .main) { _ in
    if didLaunch {
        (NSApp.delegate as? AppDelegate)?.showWindow()
    } else {
        wantsWindow = true
    }
}

// 单实例：用文件锁判断，不靠系统的应用列表（launchd 拉起的那份登记得晚，开机自启和双击撞在一起时
// 两边可能互相看不到或都看到对方）。进程退出时系统自动释放锁。
// 已经有一份在运行（比如开机自启的那份）时，通知它弹窗口，自己退出。
let lockPath = NSTemporaryDirectory() + "com.sharehideapps.lock"
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
if lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    if wantsWindow {
        DistributedNotificationCenter.default().postNotificationName(
            showWindowNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
    exit(0)
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
