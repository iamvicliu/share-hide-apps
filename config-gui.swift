import SwiftUI
import AppKit
import Carbon
import UniformTypeIdentifiers

// 「共享时隐身」配置窗口（SwiftUI，左右两栏）：左边是要隐藏的应用（可拖入、可从「应用程序」选），
// 右边是正在运行的应用（点「添加」）；底部是共享时的开关和快捷键，开关存在 UserDefaults，改了立即生效。
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
    @AppStorage(focusKey) private var focus = false
    // 勿扰快捷指令是否已添加；nil 表示还在检查
    @State private var focusShortcutInstalled: Bool?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(appName).font(.system(size: 18, weight: .bold))
                Text(L("共享或录屏时，左边的应用会自动隐藏。",
                       "While you share or record your screen, the apps on the left are hidden."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)

            HStack(alignment: .top, spacing: 20) {
                hiddenColumn
                runningColumn
            }
            .padding(.horizontal, 24).padding(.bottom, 20)

            Divider()

            // 和上面两栏同宽同间距，「快捷键」与「正在运行」左边对齐
            HStack(alignment: .top, spacing: 20) {
                sharingOptions.frame(maxWidth: .infinity, alignment: .leading)
                HotKeyRecorder().frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24).padding(.vertical, 18)
        }
        .frame(width: 780, height: 560)
        .onAppear { checkFocusShortcut() }
        // 提示「还没添加」期间每 2 秒查一次，在「快捷指令」里添加完提示自己消失
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if focus && focusShortcutInstalled == false { checkFocusShortcut() }
        }
    }

    // 左栏：要隐藏的应用。整栏都能把应用从「访达」拖进来，右上角按钮从「应用程序」里选。
    private var hiddenColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                sectionHeader(L("要隐藏的应用（\(store.entries.count)）", "Apps to hide (\(store.entries.count))"),
                              L("没在运行的应用，从「访达」拖进来。", "For apps that aren’t running, drag them in from Finder."))
                Spacer(minLength: 8)
                Button(L("从「应用程序」选择…", "Choose from Applications…")) { pick() }.controlSize(.small)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.entries) { e in
                        appRow(icon: store.iconFor(e.code), name: e.name) {
                            Button(L("移除", "Remove")) { store.remove(e) }.controlSize(.small)
                        }
                        if e.id != store.entries.last?.id { Divider() }
                    }
                }
                .padding(.leading, 10).padding(.trailing, 22)
            }
            .overlay {
                if store.entries.isEmpty {
                    Text(L("还没添加。\n从右边点「添加」，或把应用拖到这里。", "Nothing added yet.\nClick Add on the right, or drag an app here."))
                        .font(.system(size: 12)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
            }
            .listBox()
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 2).opacity(dropTargeted ? 1 : 0))
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { handleDrop($0) }
        }
        .frame(maxWidth: .infinity)
    }

    // 右栏：正在运行的应用，点「添加」就进左栏。
    private var runningColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("正在运行（\(store.runningApps.count)）", "Running (\(store.runningApps.count))"),
                          L("点「添加」放到左边。", "Click Add to move an app to the left."))
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
            .listBox()
        }
        .frame(maxWidth: .infinity)
    }

    private var sharingOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("共享时", "While sharing"), nil)
            VStack(alignment: .leading, spacing: 3) {
                Toggle(L("隐藏桌面图标", "Hide desktop icons"), isOn: $hideDesktop)
                    .font(.system(size: 13))
                    .onChange(of: hideDesktop) { _ in updateDesktopCover() }
                Text(L("用壁纸盖住桌面上的文件和小组件，共享结束后自动恢复。",
                       "Covers desktop files and widgets with your wallpaper. They come back when sharing ends."))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle(L("开启勿扰模式", "Turn on Do Not Disturb"), isOn: $focus)
                    .font(.system(size: 13))
                    .onChange(of: focus) { on in if on { checkFocusShortcut() } }
                Text(L("共享期间不弹通知，结束后自动关闭。",
                       "Keeps notifications quiet while you share and turns Do Not Disturb off afterwards."))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if focus && focusShortcutInstalled == false {
                    HStack(spacing: 8) {
                        Text(L("⚠️ 还没添加快捷指令", "⚠️ Shortcut not added yet"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Button(L("添加快捷指令…", "Add Shortcut…")) { addFocusShortcut() }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func checkFocusShortcut() {
        DispatchQueue.global().async {
            let installed = installedFocusShortcut() != nil
            DispatchQueue.main.async { focusShortcutInstalled = installed }
        }
    }

    // 把程序里带的快捷指令按界面语言改名后交给「快捷指令」导入，用户在弹出的窗口里点「添加快捷指令」
    private func addFocusShortcut() {
        guard let bundled = Bundle.main.url(forResource: "focus", withExtension: "shortcut") else {
            log("程序里没有 focus.shortcut，可能安装时下载失败")
            let alert = NSAlert()
            alert.messageText = L("找不到快捷指令文件", "Shortcut file not found")
            alert.informativeText = L("可能是安装时下载失败了。重新运行一次安装命令即可补上。",
                                      "It may have failed to download during install. Run the install command again to add it.")
            alert.runModal()
            return
        }
        let name = L(focusShortcutNames[0], focusShortcutNames[1])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("com.sharehideapps.shortcut")
        let dest = dir.appendingPathComponent(name + ".shortcut")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: bundled, to: dest)
        } catch {
            log("复制快捷指令失败：\(error)")
            return
        }
        NSWorkspace.shared.open(dest)
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

// 列表框：圆角底框 + 描边，撑满所在栏的剩余高度。
// 内边距加在内容上而不是 ScrollView 外面，右边多留出滚动条的宽度，免得压住按钮。
extension View {
    func listBox() -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return alwaysShowScroller()
            .frame(maxHeight: .infinity)
            .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder func alwaysShowScroller() -> some View {
        if #available(macOS 13, *) { scrollIndicators(.visible) } else { self }
    }
}

// 「立即隐藏」快捷键的录制框，仿系统设置里键盘快捷键的样子：
// 点一下框开始录，按下组合就保存；按住修饰键时框里实时显示；Esc 或点别处取消；✕ 清除。
// 组合必须带 ⌃ 或 ⌥，免得占掉 ⌘C、⌘Q 这类常用快捷键；被别的程序占用时保留原来的，不存坏设置。
struct HotKeyRecorder: View {
    @State private var hotKey = HotKey.current
    @State private var recording = false
    @State private var liveModifiers: NSEvent.ModifierFlags = []
    @State private var message: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("快捷键", "Shortcut")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.bottom, 6)
            HStack(spacing: 8) {
                Text(L("立即隐藏", "Hide apps now")).font(.system(size: 13))
                Spacer()
                field
            }
            Text(message ?? caption)
                .font(.system(size: 11))
                .foregroundStyle(message == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                .fixedSize(horizontal: false, vertical: true)
            if hotKey != .standard && !recording {
                Button(L("恢复默认（\(HotKey.standard.display)）", "Reset to \(HotKey.standard.display)")) { save(.standard) }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
        .onDisappear { if recording { stop() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if recording { stop() }
        }
    }

    private var caption: String {
        if recording {
            return L("按下新的组合，需包含 ⌃ 或 ⌥。按 Esc 取消。", "Press the new combination; include ⌃ or ⌥. Press Esc to cancel.")
        }
        if hotKey.code < 0 {
            return L("没有快捷键。点右边的框录一个。", "No shortcut. Click the box to record one.")
        }
        return L("按一下立刻隐藏左边的应用，不用等检测到共享。",
                 "Hides the apps on the left right away, without waiting for sharing to be detected.")
    }

    private var field: some View {
        HStack(spacing: 4) {
            Text(fieldText)
                .font(.system(size: 12, weight: recording || hotKey.code < 0 ? .regular : .medium))
                .foregroundStyle(recording && liveModifiers.isEmpty || hotKey.code < 0 && !recording ? .secondary : .primary)
                .frame(maxWidth: .infinity)
            if !recording && hotKey.code >= 0 {
                Button { save(.none) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L("清除快捷键", "Clear shortcut"))
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 140, height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(recording ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: recording ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { recording ? stop() : start() }
    }

    private var fieldText: String {
        if recording {
            return liveModifiers.isEmpty ? L("按下快捷键", "Type shortcut")
                                         : HotKey(code: 0, modifiers: liveModifiers, key: "").display
        }
        return hotKey.code < 0 ? L("点此录制", "Click to record") : hotKey.display
    }

    private func start() {
        unregisterHideHotKey()  // 录的时候旧快捷键先停用，免得按下去就触发隐藏
        message = nil
        liveModifiers = []
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
            if event.type == .flagsChanged {
                liveModifiers = mods
                return event
            }
            if mods.isEmpty && Int(event.keyCode) == kVK_Escape {
                stop()
            } else if mods.contains(.control) || mods.contains(.option) {
                save(HotKey(event: event))
            } else {
                message = L("要带上 ⌃ 或 ⌥，比如 ⌃⌥H。", "Include ⌃ or ⌥, such as ⌃⌥H.")
            }
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        liveModifiers = []
        if !registerHideHotKey() {
            message = L("⚠️ \(hotKey.display) 被别的程序占用了，换一个吧。", "⚠️ \(hotKey.display) is taken by another app. Try another one.")
        }
    }

    private func save(_ new: HotKey) {
        if recording {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
            recording = false
            liveModifiers = []
        }
        let old = HotKey.current
        new.save()
        if registerHideHotKey() {
            hotKey = new
            message = nil
            log("快捷键改为 \(new.display)")
        } else {
            old.save()
            registerHideHotKey()
            message = L("⚠️ \(new.display) 被别的程序占用了，没有更改。", "⚠️ \(new.display) is taken by another app, so nothing changed.")
        }
    }
}
