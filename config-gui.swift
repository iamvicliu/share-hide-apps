import SwiftUI
import AppKit
import UniformTypeIdentifiers

// 「共享时隐身」配置窗口（SwiftUI，极简风）。三种添加方式，最省事的是从「正在运行的应用」点「添加」。
// 底部开关「共享时隐藏桌面图标」存在 UserDefaults，改了立即生效。
// 配置写入 apps.conf，开始共享时重读，改完即时生效。窗口关掉后界面释放，只留菜单栏图标。

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
        L("# 共享 / 录屏时要隐藏的应用，每行一个。", "# Apps to hide while sharing or recording, one per line."),
        L("# 格式：bundle id 或应用名；# 后面是备注。推荐用「共享时隐身」配置窗口管理。",
          "# Bundle id or app name; text after # is a note. Easiest to manage in the ShareHide window."),
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
    private var observers: [NSObjectProtocol] = []

    init() {
        reloadRunning()
        // 窗口开着时有应用启动或退出，自动刷新「正在运行的应用」列表。
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reloadRunning()
            })
        }
    }

    // 窗口关掉后程序还在跑，要把监听摘掉。
    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func has(_ code: String) -> Bool {
        entries.contains { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }

    func reloadRunning() {
        // 自己开着窗口时也是普通应用，排除掉。
        let selfPID = ProcessInfo.processInfo.processIdentifier
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID }
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
    @AppStorage(hideDesktopKey) private var hideDesktop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(appName).font(.system(size: 18, weight: .bold))
                Text(L("共享或录屏时，下面列表里的应用会自动隐藏；结束后点 Dock 图标即可恢复。",
                       "While you share or record your screen, the apps below are hidden automatically. Click their Dock icons to bring them back."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(L("正在运行的应用（\(store.runningApps.count)）", "Running apps (\(store.runningApps.count))"),
                              L("想隐藏的应用一般都开着，点「添加」就行。", "The apps you want to hide are usually open. Just click Add."))
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.runningApps) { app in
                            appRow(icon: app.icon, name: app.name) {
                                if store.has(app.id) {
                                    Text(L("已添加", "Added")).font(.system(size: 12)).foregroundStyle(.tertiary)
                                } else {
                                    Button(L("添加", "Add")) { store.addCode(app.id, app.name) }.controlSize(.small)
                                }
                            }
                            if app.id != store.runningApps.last?.id { Divider() }
                        }
                    }
                    .padding(.leading, 10).padding(.trailing, 22)
                }
                .listBox(height: 129)
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(L("没在运行的应用", "Apps that aren’t running"),
                              L("把应用从「访达」拖进来，或从「应用程序」里选。", "Drag an app here from Finder, or choose one from Applications."))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(height: 50)
                    .overlay(Text(dropTargeted ? L("松手添加", "Drop to add") : L("把应用拖到这里 ⬇", "Drag apps here ⬇"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(dropTargeted ? Color.accentColor : .secondary))
                    .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { handleDrop($0) }
                Button(L("从「应用程序」文件夹选择…", "Choose from Applications…")) { pick() }
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(L("已添加（\(store.entries.count)）", "Added (\(store.entries.count))"),
                              L("共享时会隐藏这些应用。", "These apps are hidden while you share."))
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if store.entries.isEmpty {
                            Text(L("还没添加。从上面选一个应用吧。", "Nothing added yet. Pick an app above."))
                                .font(.system(size: 12)).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                        }
                        ForEach(store.entries) { e in
                            appRow(icon: store.iconFor(e.code), name: e.name) {
                                Button(L("移除", "Remove")) { store.remove(e) }.controlSize(.small)
                            }
                            if e.id != store.entries.last?.id { Divider() }
                        }
                    }
                    .padding(.leading, 10).padding(.trailing, 22)
                }
                .listBox(height: 129)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle(L("共享时隐藏桌面图标", "Hide desktop icons while sharing"), isOn: $hideDesktop)
                    .font(.system(size: 13))
                    .onChange(of: hideDesktop) { _ in updateDesktopCover() }
                Text(L("用壁纸盖住桌面上的文件和小组件，共享结束后自动恢复。",
                       "Covers desktop files and widgets with your wallpaper. They come back when sharing ends."))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
        panel.prompt = L("添加", "Add")
        if panel.runModal() == .OK { store.addURLs(panel.urls) }
    }
}

// 列表框：圆角底框 + 描边；高度取 3.5 行，最后一行露一半，提示还能往下滚。
// 内边距加在内容上而不是 ScrollView 外面，右边多留出滚动条的宽度，免得压住按钮。
extension View {
    func listBox(height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return alwaysShowScroller()
            .frame(height: height)
            .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder func alwaysShowScroller() -> some View {
        if #available(macOS 13, *) { scrollIndicators(.visible) } else { self }
    }
}
