import SwiftUI
import AppKit
import UniformTypeIdentifiers

// 「共享时隐身」配置窗口（SwiftUI，极简风）。三种添加方式，最省事的是从「正在运行的应用」点「添加」。
// 配置写入 apps.conf，后台 sharewatch 每秒重读，改完即时生效。关窗即退出，不常驻内存。

let configPath = NSHomeDirectory() + "/Library/Application Support/ShareHideApps/apps.conf"

struct Entry: Equatable, Identifiable {
    var code: String   // bundle id 或应用名，写进配置、后台据此匹配
    var name: String   // 给人看的显示名
    var id: String { code }
}

func ensureConfigDir() {
    let dir = (configPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
}

func loadEntries() -> [Entry] {
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
        return []
    }
    var result: [Entry] = []
    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let parts = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = parts[0].trimmingCharacters(in: .whitespaces)
        if code.isEmpty { continue }
        let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        result.append(Entry(code: code, name: name.isEmpty ? code : name))
    }
    return result
}

func saveEntries(_ entries: [Entry]) {
    ensureConfigDir()
    var lines = [
        "# 共享 / 录屏 / 截图时要隐藏的应用，每行一个。",
        "# 格式：bundle id 或应用名；# 后面是备注。推荐用「共享时隐身」配置窗口管理。",
        "",
    ]
    for e in entries {
        if !e.name.isEmpty && e.name != e.code {
            lines.append("\(e.code)   # \(e.name)")
        } else {
            lines.append(e.code)
        }
    }
    try? (lines.joined(separator: "\n") + "\n").write(toFile: configPath, atomically: true, encoding: .utf8)
}

func entryFromApp(_ url: URL) -> Entry? {
    guard url.pathExtension.lowercased() == "app" else { return nil }
    let bundle = Bundle(url: url)
    // 优先本地化显示名（和访达一致），回退到文件名
    var name = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
        ?? (bundle?.localizedInfoDictionary?["CFBundleName"] as? String)
        ?? FileManager.default.displayName(atPath: url.path)
    if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
    let code = bundle?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
    return Entry(code: code, name: name)
}

struct RunningApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
}

final class Store: ObservableObject {
    @Published var entries: [Entry] = loadEntries()
    @Published var runningApps: [RunningApp] = []

    init() { reloadRunning() }

    func has(_ code: String) -> Bool {
        entries.contains { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }

    func reloadRunning() {
        let selfBID = Bundle.main.bundleIdentifier ?? ""
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && ($0.bundleIdentifier ?? "") != selfBID }
            .map { app in
                // localizedName 是 Dock / 访达 显示的本地化名（访达、钉钉、微信），和 Mac 一致
                RunningApp(id: app.bundleIdentifier ?? (app.localizedName ?? ""),
                           name: app.localizedName ?? app.bundleIdentifier ?? "?",
                           icon: app.icon)
            }
            .sorted { $0.name < $1.name }
    }

    func iconFor(_ code: String) -> NSImage? {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.caseInsensitiveCompare(code) == .orderedSame
        }) {
            return running.icon
        }
        if code.contains("."),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: code) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    func addCode(_ code: String, _ name: String) {
        guard !code.isEmpty, !has(code) else { return }
        entries.append(Entry(code: code, name: name))
        persist()
    }

    func addURLs(_ urls: [URL]) {
        var changed = false
        for u in urls {
            if let e = entryFromApp(u), !has(e.code) { entries.append(e); changed = true }
        }
        if changed { persist() }
    }

    func remove(_ e: Entry) {
        entries.removeAll { $0.code == e.code }
        persist()
    }

    private func persist() {
        saveEntries(entries)
        reloadRunning()
    }
}

struct ContentView: View {
    @StateObject private var store = Store()
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("共享时隐身").font(.system(size: 18, weight: .bold))
                Text("共享、录屏或截图时，下面列表里的应用会自动隐藏；结束后点 Dock 图标即可恢复。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("正在运行的应用", "想隐藏的应用一般都开着，点「添加」就行。")
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.runningApps) { app in
                            appRow(icon: app.icon, name: app.name) {
                                if store.has(app.id) {
                                    Text("已添加").font(.system(size: 12)).foregroundStyle(.tertiary)
                                } else {
                                    Button("添加") { store.addCode(app.id, app.name) }.controlSize(.small)
                                }
                            }
                            if app.id != store.runningApps.last?.id { Divider() }
                        }
                    }
                }
                .frame(height: 148)
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("没在运行的应用", "把应用从「访达」拖进来，或从「应用程序」里选。")
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(height: 50)
                    .overlay(Text(dropTargeted ? "松手添加" : "把应用拖到这里 ⬇")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(dropTargeted ? Color.accentColor : .secondary))
                    .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { handleDrop($0) }
                Button("从「应用程序」文件夹选择…") { pick() }
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("已添加（共享时会隐藏这些）", nil)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if store.entries.isEmpty {
                            Text("还没添加。从上面选一个应用吧。")
                                .font(.system(size: 12)).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                        }
                        ForEach(store.entries) { e in
                            appRow(icon: store.iconFor(e.code), name: e.name) {
                                Button("移除") { store.remove(e) }.controlSize(.small)
                            }
                            if e.id != store.entries.last?.id { Divider() }
                        }
                    }
                }
                .frame(height: 108)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 400)
    }

    private func sectionHeader(_ title: String, _ desc: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            if let desc = desc {
                Text(desc).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    private func appRow<T: View>(icon: NSImage?, name: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 10) {
            if let icon = icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.dashed").resizable().frame(width: 18, height: 18)
                    .foregroundStyle(.tertiary).frame(width: 22, height: 22)
            }
            Text(name).font(.system(size: 13)).lineLimit(1)
            Spacer()
            trailing()
        }
        .padding(.vertical, 7)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                if let u = url { lock.lock(); urls.append(u); lock.unlock() }
            }
        }
        group.notify(queue: .main) { self.store.addURLs(urls) }
        return true
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "添加"
        if panel.runModal() == .OK { store.addURLs(panel.urls) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        let hosting = NSHostingView(rootView: ContentView())
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size.height > 0 ? size : NSSize(width: 400, height: 660)),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "共享时隐身"
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // 建中文主菜单，否则菜单栏会显示可执行名（英文）
    private func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "隐藏「共享时隐身」", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出「共享时隐身」", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
