import Cocoa
import SwiftUI
import IOKit
import IOKit.ps
import Darwin
import UserNotifications
import ServiceManagement

struct Device {
    let name: String
    let percent: Int
    var charging: Bool? = nil
    var externalPower = false
    var source = "IORegistry"
    var powerLabel: String {
        if charging == true { return "正在充电" }
        if charging == false { return externalPower ? (percent == 100 ? "已充满" : "已接电，未充电") : "电池供电" }
        return "充电状态未知"
    }
    var symbol: String {
        switch label { case "键盘": return "keyboard"; case "触控板": return "rectangle.and.hand.point.up.left"; case "鼠标": return "computermouse"; default: return "battery.100percent" }
    }
    var label: String {
        let s = name.lowercased()
        if s.contains("trackpad") || s.contains("触控") { return "触控板" }
        if s.contains("keyboard") || s.contains("键盘") { return "键盘" }
        if s.contains("mouse") || s.contains("鼠标") { return "鼠标" }
        return name
    }
}
func readRegistryDevices() -> [Device] {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var result: [Device] = []
    while true {
        let entry = IOIteratorNext(iterator)
        if entry == 0 { break }
        defer { IOObjectRelease(entry) }
        func value(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        guard let percent = value("BatteryPercent") as? Int, (0...100).contains(percent) else { continue }
        let name = value("Product") as? String ?? "外设"
        result.append(Device(name: name, percent: percent))
    }
    return result.sorted { $0.label < $1.label }
}

// Apple's accessory-source API is publicly unsupported. Resolve it dynamically;
// if unavailable, retain the battery reading and explicitly mark charging unknown.
enum AccessoryPower {
    typealias CopySources = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    static let copySources: CopySources? = {
        guard let handle = handle, let symbol = dlsym(handle, "IOPSCopyPowerSourcesByType") else { return nil }
        return unsafeBitCast(symbol, to: CopySources.self)
    }()
}
func decodeAccessory(_ data: [String: Any]) -> Device? {
    guard ["Keyboard", "Trackpad", "Mouse"].contains(data["Accessory Category"] as? String ?? ""),
          (data["Is Present"] as? NSNumber)?.boolValue == true,
          let name = data["Name"] as? String,
          let current = data["Current Capacity"] as? Int,
          let maximum = data["Max Capacity"] as? Int,
          maximum > 0, current >= 0, current <= maximum else { return nil }
    let percent = Int((Double(current) / Double(maximum) * 100).rounded())
    let charging = (data["Is Charging"] as? NSNumber)?.boolValue
    return Device(name: name, percent: percent, charging: charging,
                  externalPower: data["Power Source State"] as? String == "AC Power",
                  source: "macOS 外设电源服务")
}
func readDevices() -> [Device] {
    if let copy = AccessoryPower.copySources,
       let snapshot = copy(4)?.takeRetainedValue(),
       let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
        let devices = sources.compactMap { source -> Device? in
            guard let data = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { return nil }
            return decodeAccessory(data)
        }
        // A valid source snapshot is authoritative, including an empty device list.
        return devices.sorted { $0.label < $1.label }
    }
    return readRegistryDevices()
}
func runSelfTests() {
    var data: [String: Any] = ["Accessory Category": "Keyboard", "Is Present": true, "Name": "Test Keyboard", "Current Capacity": 23, "Max Capacity": 100, "Is Charging": false, "Power Source State": "Battery Power"]
    precondition(decodeAccessory(data)?.powerLabel == "电池供电")
    data["Current Capacity"] = 24
    precondition(decodeAccessory(data)?.charging == false, "Increasing capacity must not imply charging")
    data["Is Charging"] = true
    precondition(decodeAccessory(data)?.powerLabel == "正在充电")
    data["Is Charging"] = false
    data["Power Source State"] = "AC Power"
    precondition(decodeAccessory(data)?.powerLabel == "已接电，未充电")
    data["Current Capacity"] = 100
    precondition(decodeAccessory(data)?.powerLabel == "已充满")
    data.removeValue(forKey: "Is Charging")
    precondition(decodeAccessory(data)?.charging == nil)
    data["Max Capacity"] = 0
    precondition(decodeAccessory(data) == nil)
    data["Max Capacity"] = 100
    data["Is Present"] = false
    precondition(decodeAccessory(data) == nil)
    data["Is Present"] = true
    data["Accessory Category"] = "Headset"
    precondition(decodeAccessory(data) == nil)
    print("PASS: power-state decoding, rising percentage, missing state, invalid capacity, absent device, category filtering")
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var item: NSStatusItem!
    var settingsWindow: NSWindow?
    let model = BatteryModel()
    var notificationState = "正在检查通知权限…"
    var notificationDetail = ""
    var notificationRequestInFlight = false
    var style: Int { defaults.integer(forKey: "style") }
    func displayName(_ device: Device) -> String {
        let custom = defaults.string(forKey: "name." + device.name) ?? ""
        return custom.isEmpty ? device.label : custom
    }
    func updateNotificationState() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.notificationState = settings.alertSetting == .enabled ? "通知已允许" : "通知已允许，但横幅未开启"
                case .denied: self.notificationState = "通知未允许，请在系统设置中开启"
                case .notDetermined: self.notificationState = "尚未授权通知，点击下方按钮开启"
                default: self.notificationState = "通知权限状态未知"
                }
                self.syncModel()
            }
        }
    }
    func syncModel() {
        model.devices = devices
        model.lastRead = lastUpdate
        model.notificationState = notificationState
        model.notificationDetail = notificationDetail
        model.threshold = threshold
        model.style = style
        model.loginEnabled = SMAppService.mainApp.status == .enabled
        model.loginPending = SMAppService.mainApp.status == .requiresApproval
    }
    @objc func showSettings() {
        refresh()
        updateNotificationState()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 610), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "外设电量"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BatterySettings(model: model, delegate: self))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func renderStatus() {
        let text = NSMutableAttributedString(string: "")
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        for (index, device) in devices.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
            let color: NSColor = device.charging == true ? .systemGreen : device.percent <= 10 ? .systemRed : device.percent <= threshold ? .systemOrange : .labelColor
            if style == 1 {
                text.append(NSAttributedString(string: displayName(device) + " ", attributes: [.font: font, .foregroundColor: color]))
            } else {
                let symbol = style == 2 ? (device.percent <= 10 ? "battery.0percent" : device.percent <= 30 ? "battery.25percent" : device.percent <= 60 ? "battery.50percent" : device.percent <= 85 ? "battery.75percent" : "battery.100percent") : device.symbol
                if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: device.label)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)) {
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    attachment.bounds = NSRect(x: 0, y: -3, width: 18, height: 15)
                    text.append(NSAttributedString(attachment: attachment))
                    text.append(NSAttributedString(string: " "))
                }
            }
            text.append(NSAttributedString(string: "\(device.charging == true ? "⚡ " : "")\(device.percent)%", attributes: [.font: font, .foregroundColor: color]))
        }
        if devices.isEmpty { text.append(NSAttributedString(string: "外设未连接")) }
        item.button?.attributedTitle = text
        item.button?.toolTip = devices.map { "\(displayName($0))：\($0.percent)% · \($0.powerLabel)" }.joined(separator: "\n") + "\n每 5 秒读取系统数据，设备上报可能延迟"
    }
    var timer: Timer?
    var devices: [Device] = []
    var lastUpdate = Date()
    let defaults = UserDefaults.standard
    var threshold: Int { defaults.object(forKey: "threshold") as? Int ?? 30 }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        UNUserNotificationCenter.current().delegate = self
        refresh()
        let pollingTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        pollingTimer.tolerance = 0.5
        RunLoop.main.add(pollingTimer, forMode: .common)
        timer = pollingTimer
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        updateNotificationState()
        showSettings()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    @objc func refresh() {
        devices = readDevices()
        lastUpdate = Date()
        renderStatus()
        syncModel()
        buildMenu()
        for device in devices {
            let key = "lastAlert.\(device.name)"
            if device.percent > threshold + 5 { defaults.removeObject(forKey: key); continue }
            guard device.percent <= threshold, device.charging != true, !device.externalPower else { continue }
            let last = defaults.object(forKey: key) as? Date ?? .distantPast
            guard Date().timeIntervalSince(last) >= 6 * 3600 else { continue }
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized else { return }
                let content = UNMutableNotificationContent()
                content.title = "\(device.label)需要充电"
                content.body = "\(device.name)剩余电量 \(device.percent)%，请及时充电。"
                content.sound = .default
                let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request) { error in
                    DispatchQueue.main.async {
                        if let error = error { self.notificationDetail = "发送失败：" + error.localizedDescription }
                        else { self.defaults.set(Date(), forKey: key) }
                        self.syncModel()
                    }
                }
            }
        }
    }
    func add(_ menu: NSMenu, _ title: String, _ action: Selector? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
        return entry
    }
    func buildMenu() {
        let menu = NSMenu()
        _ = add(menu, "电量与个性化设置…", #selector(showSettings))
        menu.addItem(.separator())
        if devices.isEmpty { _ = add(menu, "未检测到已连接的苹果外设") }
        for d in devices { _ = add(menu, "\(d.name)：\(d.percent)% · \(d.powerLabel)") }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        _ = add(menu, "读取于 \(formatter.string(from: lastUpdate)) · 每 5 秒检查")
        menu.addItem(.separator())
        _ = add(menu, "立即刷新", #selector(refresh))
        let thresholds = NSMenu()
        for n in [10, 20, 30] {
            let option = add(thresholds, "低于或等于 \(n)% 时提醒", #selector(changeThreshold(_:)))
            option.tag = n; option.state = threshold == n ? .on : .off
        }
        add(menu, "低电量提醒：\(threshold)%").submenu = thresholds
        _ = add(menu, "发送测试通知", #selector(testNotification))
        _ = add(menu, "打开通知设置", #selector(notificationSettings))
        let login = add(menu, "登录后自动启动", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        _ = add(menu, "退出外设电量", #selector(quit))
        item.menu = menu
    }
    @objc func changeThreshold(_ sender: NSMenuItem) { defaults.set(sender.tag, forKey: "threshold"); refresh() }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert(); alert.messageText = "自动启动设置未成功"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
        buildMenu()
        syncModel()
    }
    @objc func notificationSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
    func requestNotifications(test: Bool) {
        guard !notificationRequestInFlight else { return }
        notificationRequestInFlight = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, error in
            DispatchQueue.main.async {
                self.notificationRequestInFlight = false
                if let error = error {
                    self.notificationDetail = "授权请求失败：" + error.localizedDescription
                    self.updateNotificationState()
                    return
                }
                guard allowed else {
                    self.notificationDetail = "macOS 不会重复弹出已拒绝的授权框，请点击“系统通知设置”开启。"
                    self.updateNotificationState()
                    return
                }
                self.updateNotificationState()
                if test {
                    let content = UNMutableNotificationContent()
                    content.title = "外设电量提醒已就绪"
                    content.body = "" + self.devices.map { "\(self.displayName($0)) \($0.percent)%" }.joined(separator: " · ")
                    content.sound = .default
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test", content: content, trigger: trigger)) { error in
                        DispatchQueue.main.async {
                            self.notificationDetail = error.map { "测试发送失败：" + $0.localizedDescription } ?? "测试已提交，约 2 秒后显示；若没有横幅，请检查专注模式和系统通知设置。"
                            self.syncModel()
                        }
                    }
                } else {
                    self.notificationDetail = "通知已开启，低电量时会自动提醒。"
                    self.refresh()
                }
            }
        }
    }
    @objc func testNotification() { requestNotifications(test: true) }
    func setStyle(_ value: Int) { defaults.set(value, forKey: "style"); refresh() }
    func setThreshold(_ value: Int) { defaults.set(value, forKey: "threshold"); refresh() }
    func setName(_ device: Device, _ value: String) { model.objectWillChange.send(); defaults.set(String(value.prefix(16)), forKey: "name." + device.name); renderStatus() }
    @objc func quit() { NSApp.terminate(nil) }
}
class BatteryModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var lastRead = Date()
    @Published var notificationState = "正在检查…"
    @Published var notificationDetail = ""
    @Published var threshold = 30
    @Published var style = 0
    @Published var loginEnabled = false
    @Published var loginPending = false
}
struct BatterySettings: View {
    @ObservedObject var model: BatteryModel
    let delegate: AppDelegate
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("随时知道，还剩多少。").font(.system(size: 23, weight: .semibold))
                        Text("你的键盘与触控板，都在这里。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "bolt.circle.fill").font(.system(size: 34)).foregroundStyle(.teal)
                }
                HStack(spacing: 12) {
                    ForEach(Array(model.devices.enumerated()), id: \.offset) { _, device in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: device.symbol).font(.title2)
                                Spacer()
                                Label(device.powerLabel, systemImage: device.charging == true ? "bolt.fill" : "battery.100percent")
                                    .font(.caption).foregroundStyle(device.charging == true ? .green : .secondary)
                            }
                            Text("\(device.percent)%").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                            ProgressView(value: Double(device.percent), total: 100).tint(device.charging == true ? .green : device.percent <= model.threshold ? .orange : .teal)
                            TextField(device.label, text: Binding(get: { delegate.displayName(device) }, set: { delegate.setName(device, $0) }))
                                .textFieldStyle(.plain).font(.callout)
                                .help("点击修改名称；中文样式会使用这个名字")
                        }
                        .padding(14).frame(maxWidth: .infinity)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                if model.devices.isEmpty { Text("暂无外设电量，请确认蓝牙已连接。").foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("菜单栏外观").font(.headline)
                    Picker("显示方式", selection: Binding(get: { model.style }, set: { delegate.setStyle($0) })) {
                        Text("图标 + 电量").tag(0)
                        Text("名称 + 电量").tag(1)
                        Text("电池 + 电量").tag(2)
                    }.pickerStyle(.segmented).labelsHidden()
                    Text("电量偏低显示橙色，低于或等于 10% 显示红色。").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("充电提醒").font(.headline)
                        Spacer()
                        Picker("提醒阈值", selection: Binding(get: { model.threshold }, set: { delegate.setThreshold($0) })) {
                            Text("10%").tag(10); Text("20%").tag(20); Text("30%").tag(30)
                        }.frame(width: 150)
                    }
                    Label(model.notificationState, systemImage: "bell").font(.callout)
                    HStack {
                        Button("开启通知") { delegate.requestNotifications(test: false) }
                        Button("测试通知") { delegate.testNotification() }
                        Button("系统通知设置") { delegate.notificationSettings() }
                    }
                    if !model.notificationDetail.isEmpty { Text(model.notificationDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Divider()
                Toggle("登录后自动启动", isOn: Binding(get: { model.loginEnabled }, set: { _ in delegate.toggleLogin() }))
                if model.loginPending { Text("请在系统设置 → 通用 → 登录项中允许启动。").font(.caption).foregroundStyle(.orange) }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("系统读取于 " + model.lastRead.formatted(date: .omitted, time: .standard))
                        Text("每 5 秒检查 · 设备上报可能延迟")
                    }.font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新") { delegate.refresh(); delegate.updateNotificationState() }
                }
            }.padding(24)
        }.frame(width: 470, height: 610)
    }
}
if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
} else if CommandLine.arguments.contains("--check") {
    for d in readDevices() { print("\(d.label) | \(d.percent)% | \(d.powerLabel) | \(d.source)") }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
