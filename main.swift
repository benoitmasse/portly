import SwiftUI
import AppKit
import ServiceManagement
import Combine

// MARK: - Model

enum Kind: Int { case website, background, system }

enum Advice {
    case safe(String), ifUnused(String), keep(String)

    var label: String {
        switch self {
        case .safe: "Safe to stop"
        case .ifUnused: "Stop if you don't need it"
        case .keep: "Best to keep running"
        }
    }
    var detail: String {
        switch self { case .safe(let s), .ifUnused(let s), .keep(let s): s }
    }
    var color: Color {
        switch self { case .safe: .green; case .ifUnused: .orange; case .keep: .secondary }
    }
    var symbol: String {
        switch self { case .safe: "checkmark.circle.fill"; case .ifUnused: "questionmark.circle.fill"; case .keep: "lock.circle.fill" }
    }
}

struct ServiceInfo {
    let title: String
    let text: String
    let advice: Advice
}

/// One "server" = the command that was launched (e.g. `pnpm dev`) plus every child process under it.
struct ServerGroup: Identifiable {
    let rootPid: Int32
    let ports: [Int]
    let webPorts: [Int]
    let command: String
    let cwd: String?
    let project: String
    let uptime: String
    let kind: Kind
    let info: ServiceInfo
    let startedBy: String
    let launchdLabel: String?
    let orphan: Bool
    /// Programs connected to this server right now (e.g. "Google Chrome", "design-vention").
    let usedBy: [String]
    /// True when the working folder is a real project folder (not "/" or a Homebrew data folder).
    var hasProject: Bool { cwd?.hasPrefix(NSHomeDirectory() + "/") ?? false }

    var id: Int32 { rootPid }
    var key: String { (cwd ?? "") + "|" + command }
    var isMCP: Bool { command.lowercased().contains("mcp") }
    var brewFormula: String? {
        guard let l = launchdLabel, l.hasPrefix("homebrew.mxcl.") else { return nil }
        return String(l.dropFirst("homebrew.mxcl.".count))
    }
    /// macOS relaunches launchd jobs we kill, so only Homebrew ones (via `brew services`) can really be stopped.
    var canStop: Bool { kind != .system && (launchdLabel == nil || brewFormula != nil) }
    var canRestart: Bool { canStop && brewFormula == nil && !isMCP && cwd != nil }
}

/// Something the app stopped, kept so it can be started again with one click.
struct StoppedItem: Codable, Identifiable {
    var id = UUID()
    let title: String
    let project: String
    let command: String
    let cwd: String?
    let brewFormula: String?
    let date: Date
}

struct ProcInfo {
    let pid: Int32
    let ppid: Int32
    let etime: String
    let exe: String
    var command = ""
}

// MARK: - Scanning

func runTool(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

let brewPath = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }

enum Scanner {
    static let shells: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "sh", "-sh", "fish", "-fish", "dash", "tcsh", "csh",
        "login", "tmux", "screen", "sshd", "su", "sudo", "launchd",
    ]

    static func isSystemPath(_ exe: String) -> Bool {
        // Python.framework ships its interpreter inside a Python.app bundle; that is still a dev tool.
        (exe.contains(".app/") && !exe.contains("/Python.app/")) || exe.hasPrefix("/System/")
            || exe.hasPrefix("/usr/libexec/") || exe.hasPrefix("/usr/sbin/") || exe.hasPrefix("/sbin/")
            || exe.hasPrefix("/Library/Apple/")
    }

    /// Where we stop walking up the parent chain: shells, terminals, apps.
    static func isBoundary(_ exe: String) -> Bool {
        shells.contains((exe as NSString).lastPathComponent) || isSystemPath(exe)
    }

    /// "/Applications/Visual Studio Code.app/Contents/.../Code Helper" -> "Visual Studio Code"
    static func appName(_ exe: String) -> String? {
        guard let r = exe.range(of: ".app/") else { return nil }
        return (String(exe[..<r.lowerBound]) as NSString).lastPathComponent
    }

    static func processTable() -> [Int32: ProcInfo] {
        var procs: [Int32: ProcInfo] = [:]
        for raw in runTool("/bin/ps", ["-A", "-o", "pid=,ppid=,etime=,comm="]).split(separator: "\n") {
            let line = raw.drop(while: { $0 == " " })
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            procs[pid] = ProcInfo(pid: pid, ppid: ppid, etime: String(parts[2]),
                                  exe: String(parts[3]).trimmingCharacters(in: .whitespaces))
        }
        for raw in runTool("/bin/ps", ["-A", "-o", "pid=,command="]).split(separator: "\n") {
            let line = raw.drop(while: { $0 == " " })
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            procs[pid]?.command = String(parts[1])
        }
        return procs
    }

    static func listeningPorts() -> [Int32: Set<Int>] {
        var result: [Int32: Set<Int>] = [:]
        var current: Int32 = 0
        for line in runTool("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]).split(separator: "\n") {
            if line.hasPrefix("p") {
                current = Int32(line.dropFirst()) ?? 0
            } else if line.hasPrefix("n"), let colon = line.lastIndex(of: ":"),
                      let port = Int(line[line.index(after: colon)...]) {
                result[current, default: []].insert(port)
            }
        }
        return result
    }

    static func workingDirs(_ pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        var result: [Int32: String] = [:]
        var current: Int32 = 0
        let list = pids.map(String.init).joined(separator: ",")
        for line in runTool("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", list]).split(separator: "\n") {
            if line.hasPrefix("p") { current = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n") { result[current] = String(line.dropFirst()) }
        }
        return result
    }

    /// pid -> label for jobs that launchd (login items, Homebrew services) runs for this user.
    static func launchdJobs() -> [Int32: String] {
        var result: [Int32: String] = [:]
        for line in runTool("/bin/launchctl", ["list"]).split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t")
            if parts.count == 3, let pid = Int32(parts[0]) { result[pid] = String(parts[2]) }
        }
        return result
    }

    static func root(of pid: Int32, in procs: [Int32: ProcInfo]) -> Int32 {
        var cur = pid
        var seen: Set<Int32> = [pid]
        while let parent = procs[cur]?.ppid, parent > 1, !seen.contains(parent),
              let info = procs[parent], !isBoundary(info.exe) {
            seen.insert(parent)
            cur = parent
        }
        return cur
    }

    static func tree(of root: Int32, in procs: [Int32: ProcInfo]) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for p in procs.values { children[p.ppid, default: []].append(p.pid) }
        var out: [Int32] = []
        var stack = [root]
        while let p = stack.popLast() {
            out.append(p)
            stack.append(contentsOf: children[p] ?? [])
        }
        return out
    }

    static func startedBy(_ root: Int32, procs: [Int32: ProcInfo], label: String?) -> String {
        if let label { return label.hasPrefix("homebrew.mxcl.") ? "Started at login by Homebrew" : "Started by macOS" }
        var cur = procs[root]?.ppid ?? 1
        var seen: Set<Int32> = []
        while cur > 1, !seen.contains(cur), let p = procs[cur] {
            seen.insert(cur)
            let exe = p.exe
            if exe.contains("/claude-code/") { return "Started by a Claude Code session" }
            if exe.contains("/Claude.app/") { return "Started by the Claude app" }
            if let app = appName(exe) {
                switch app {
                case "Terminal": return "Started in Terminal"
                case "iTerm", "iTerm2": return "Started in iTerm"
                case "Visual Studio Code": return "Started in VS Code"
                default: return "Started by \(app)"
                }
            }
            cur = p.ppid
        }
        return "Started from a terminal"
    }

    static func projectName(cwd: String?, fallback: String) -> String {
        guard let cwd, cwd.hasPrefix(NSHomeDirectory() + "/") else { return fallback }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd)
        let home = NSHomeDirectory()
        while dir.path != "/" && dir.path != home {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir.lastPathComponent }
            dir.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    static func formatUptime(_ etime: String) -> String {
        // ps etime: [[dd-]hh:]mm:ss
        var days = 0
        var rest = Substring(etime)
        if let dash = rest.firstIndex(of: "-") {
            days = Int(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let nums = rest.split(separator: ":").map { Int($0) ?? 0 }
        let (h, m) = nums.count == 3 ? (nums[0], nums[1]) : (0, nums.first ?? 0)
        if days > 0 { return "\(days)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    // MARK: Website detection

    private static var webCache: [String: Bool] = [:]
    private static let webLock = NSLock()

    /// A port is a "website" if it answers an HTTP request with an HTML page.
    static func servesHTML(port: Int, pid: Int32) -> Bool {
        let key = "\(pid):\(port)"
        webLock.lock()
        let cached = webCache[key]
        webLock.unlock()
        if let cached { return cached }

        var request = URLRequest(url: URL(string: "http://localhost:\(port)/")!, timeoutInterval: 1)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("close", forHTTPHeaderField: "Connection")
        let done = DispatchSemaphore(value: 0)
        var answer: Bool? = nil
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                answer = (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/html")
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 1.5)
        // Only remember real answers: a server that is still starting gets asked again next time.
        if let answer {
            webLock.lock()
            webCache[key] = answer
            webLock.unlock()
        }
        return answer ?? false
    }

    // MARK: Descriptions

    static func has(_ command: String, _ word: String) -> Bool {
        command.split(separator: " ").contains { ($0 as NSString).lastPathComponent.lowercased() == word }
    }

    /// Plain-language name and description for well-known programs.
    static func describe(command: String, exe: String) -> (title: String, text: String)? {
        let c = command.lowercased()
        if c.contains("figma-console-mcp") { return ("Figma link for Claude", "Lets a Claude session read and edit your Figma files.") }
        if c.contains("postgres") { return ("PostgreSQL database", "Stores data for apps you run on this Mac. It has no page to open.") }
        if c.contains("redis-server") { return ("Redis cache", "Keeps short-lived data in memory (logins, queues) for app backends.") }
        if c.contains("mysqld") { return ("MySQL database", "Stores data for apps you run on this Mac. It has no page to open.") }
        if c.contains("mongod") { return ("MongoDB database", "Stores data for apps you run on this Mac. It has no page to open.") }
        if c.contains("ollama") { return ("Ollama", "Runs AI models on this Mac.") }
        if c.contains("storybook") { return ("Storybook", "A page that shows the UI components one by one.") }
        if has(command, "vite") { return ("Vite dev server", "Live preview of a site. It reloads when the code changes.") }
        if has(command, "next") { return ("Next.js dev server", "Live preview of a site. It reloads when the code changes.") }
        if has(command, "astro") { return ("Astro dev server", "Live preview of a site. It reloads when the code changes.") }
        if c.contains("webpack") { return ("Webpack dev server", "Live preview of a site. It reloads when the code changes.") }
        if c.contains("http.server") { return ("Simple file server", "Shows the files of a folder as a web page.") }
        if c.contains("mcp") { return ("Claude tool helper (MCP)", "Gives a Claude session extra tools.") }
        return nil
    }

    static func info(for g: (command: String, exe: String, kind: Kind, orphan: Bool, label: String?, app: String?, usedBy: [String])) -> ServiceInfo {
        let known = describe(command: g.command, exe: g.exe)
        switch g.kind {
        case .system:
            let app = g.app ?? (g.exe as NSString).lastPathComponent
            return ServiceInfo(title: app, text: "Part of the \(app) app.",
                               advice: .keep("Quit \(app) to close it."))
        case .website:
            return ServiceInfo(title: known?.title ?? "Website", text: known?.text ?? "A page you can open in your browser.",
                               advice: g.orphan ? .safe("The window that started it is closed. Nothing uses it any more.")
                                                : .safe("Stop it when you are done. You can start it again from the Stopped list."))
        case .background:
            let title = known?.title ?? "Background program"
            let text = known?.text ?? "It runs without a page to open, probably an API or a tool that a project uses."
            let advice: Advice
            let users = g.usedBy.joined(separator: ", ")
            if g.orphan {
                advice = .safe("The window that started it is closed. Nothing uses it any more.")
            } else if g.command.lowercased().contains("mcp") {
                advice = .keep("It closes by itself when its Claude session closes. Stop it only if Claude does not need it now.")
            } else if !g.usedBy.isEmpty {
                advice = .keep("\(users) is using it now. Stopping it would break that.")
            } else if let label = g.label, label.hasPrefix("homebrew.mxcl.") {
                advice = .safe("No app is connected to it now, so nothing needs it. It stays off after a restart of the Mac. If an app needs it later, start it again from the Stopped list.")
            } else if g.label != nil {
                advice = .keep("macOS starts it again if you stop it.")
            } else {
                advice = .ifUnused("No app is connected to it now. If you don't know what it is, check its folder before you stop it.")
            }
            return ServiceInfo(title: title, text: text, advice: advice)
        }
    }

    /// (pid, remote port) for every open TCP connection: which process talks to which port.
    static func connections() -> [(pid: Int32, remotePort: Int)] {
        var result: [(Int32, Int)] = []
        var current: Int32 = 0
        for line in runTool("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-Fpn"]).split(separator: "\n") {
            if line.hasPrefix("p") {
                current = Int32(line.dropFirst()) ?? 0
            } else if line.hasPrefix("n"), let arrow = line.range(of: "->") {
                let remote = line[arrow.upperBound...]
                if let colon = remote.lastIndex(of: ":"), let port = Int(remote[remote.index(after: colon)...]) {
                    result.append((current, port))
                }
            }
        }
        return result
    }

    static func scan(showAll: Bool) -> [ServerGroup] {
        let ports = listeningPorts()
        guard !ports.isEmpty else { return [] }
        let procs = processTable()
        let jobs = launchdJobs()
        let me = ProcessInfo.processInfo.processIdentifier

        var listenersByRoot: [Int32: [Int32]] = [:]
        for pid in ports.keys where pid != me && procs[pid] != nil {
            listenersByRoot[root(of: pid, in: procs), default: []].append(pid)
        }
        let cwds = workingDirs(Array(listenersByRoot.keys))

        struct Candidate { let root: Int32; let info: ProcInfo; let listeners: [Int32]; let ports: [Int]; let command: String; let system: Bool }
        var candidates: [Candidate] = []
        for (rootPid, listeners) in listenersByRoot {
            guard let info = procs[rootPid] else { continue }
            let system = isSystemPath(info.exe) || listeners.contains { isSystemPath(procs[$0]?.exe ?? "") }
            if system && !showAll { continue }
            let allPorts = listeners.reduce(into: Set<Int>()) { $0.formUnion(ports[$1] ?? []) }.sorted()
            let command = (info.command.isEmpty ? info.exe : info.command).trimmingCharacters(in: .whitespaces)
            candidates.append(Candidate(root: rootPid, info: info, listeners: listeners, ports: allPorts, command: command, system: system))
        }

        // Ask each non-system, non-launchd port whether it serves a web page (in parallel, cached).
        var webPorts = [[Int]](repeating: [], count: candidates.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            let c = candidates[i]
            guard !c.system, jobs[c.root] == nil, !c.command.lowercased().contains("mcp") else { return }
            let found = c.ports.filter { servesHTML(port: $0, pid: c.root) }
            lock.lock(); webPorts[i] = found; lock.unlock()
        }

        // Who is connected to each server, named by app ("Google Chrome") or project folder.
        let conns = connections()
        var clientRoots: [Int32: Int32] = [:]
        for (pid, _) in conns where clientRoots[pid] == nil { clientRoots[pid] = root(of: pid, in: procs) }
        let clientCwds = workingDirs(Array(Set(clientRoots.values)))
        func clientName(_ pid: Int32) -> String {
            if let app = appName(procs[pid]?.exe ?? "") { return app }
            let r = clientRoots[pid] ?? pid
            let exe = String(((procs[r]?.exe ?? "?") as NSString).lastPathComponent.split(separator: " ").first ?? "?")
            return projectName(cwd: clientCwds[r], fallback: exe)
        }

        var groups: [ServerGroup] = []
        for (i, c) in candidates.enumerated() {
            let own = Set(tree(of: c.root, in: procs))
            let portSet = Set(c.ports)
            // Ignore this app's own page checks.
            let clients = Set(conns.filter {
                portSet.contains($0.remotePort) && !own.contains($0.pid) && !(procs[$0.pid]?.exe.hasPrefix(Bundle.main.bundlePath) ?? false)
            }.map(\.pid))
            let usedBy = Array(Set(clients.map(clientName))).sorted()
            let label = jobs[c.root]
            let orphan = !c.system && label == nil && c.info.ppid == 1
            let kind: Kind = c.system ? .system : (webPorts[i].isEmpty ? .background : .website)
            let app = appName(c.info.exe) ?? c.listeners.compactMap { appName(procs[$0]?.exe ?? "") }.first
            let exeName = String((c.info.exe as NSString).lastPathComponent.split(separator: " ").first ?? "?")
            groups.append(ServerGroup(
                rootPid: c.root,
                ports: c.ports,
                webPorts: webPorts[i],
                command: c.command,
                cwd: cwds[c.root],
                project: projectName(cwd: cwds[c.root], fallback: app ?? exeName),
                uptime: formatUptime(c.info.etime),
                kind: kind,
                info: info(for: (([c.command] + c.listeners.compactMap { procs[$0]?.command }).joined(separator: " "),
                                 c.info.exe, kind, orphan, label, app, usedBy)),
                startedBy: c.system ? "Part of \(app ?? "macOS")"
                    : orphan ? "Left running: the window that started it is closed"
                    : startedBy(c.root, procs: procs, label: label),
                launchdLabel: label,
                orphan: orphan,
                usedBy: usedBy))
        }
        return groups.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return ($0.ports.first ?? 0) < ($1.ports.first ?? 0)
        }
    }
}

// MARK: - Actions

enum Control {
    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// SIGTERM the whole tree, then SIGKILL whatever is still there after a few seconds.
    static func stopTree(_ root: Int32) {
        guard root > 1, root != ProcessInfo.processInfo.processIdentifier else { return }
        let pids = Scanner.tree(of: root, in: Scanner.processTable())
        for p in pids { kill(p, SIGTERM) }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, pids.contains(where: isAlive) { usleep(200_000) }
        for p in pids where isAlive(p) { kill(p, SIGKILL) }
    }

    static func stop(_ g: ServerGroup) {
        if let formula = g.brewFormula, let brewPath {
            _ = runTool(brewPath, ["services", "stop", formula])
        } else {
            stopTree(g.rootPid)
        }
    }

    static func waitForPortsFree(_ ports: [Int]) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let busy = Set(Scanner.listeningPorts().values.flatMap { $0 })
            if ports.allSatisfy({ !busy.contains($0) }) { return }
            usleep(250_000)
        }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Relaunch the command in its folder, detached, with output going to a log file.
    static func launch(command: String, cwd: String, project: String) -> URL? {
        let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Portly")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logURL = logDir.appendingPathComponent("\(project)-\(stamp).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: logURL) else { return nil }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -l -i so PATH from .zprofile/.zshrc (nvm, pnpm, brew...) is loaded.
        p.arguments = ["-l", "-i", "-c", "cd \(shellQuote(cwd)) && exec \(command)"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log
        p.standardError = log
        do { try p.run() } catch { return nil }
        return logURL
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var groups: [ServerGroup] = []
    @Published var busy: [Int32: String] = [:]
    @Published var logs: [String: URL] = [:]
    @Published var stopped: [StoppedItem] = Store.loadStopped() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(stopped), forKey: "stopped") }
    }
    /// Cards the user opened, by server key (kept across refreshes).
    @Published var expanded: Set<String> = []
    /// Cards whose details are visible. Lags behind `expanded` so text fades in once the card has mostly grown.
    @Published var revealed: Set<String> = []

    /// Height curve for opening and closing a card. It reaches 85% of its height at 46% of its time.
    static let cardCurve = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.34)
    static let revealDelay = 0.34 * 0.458

    func toggle(_ key: String) {
        if expanded.contains(key) {
            // Close: fade the text out quickly, then shrink the card.
            withAnimation(.easeOut(duration: 0.1)) { _ = revealed.remove(key) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard !self.revealed.contains(key) else { return }
                withAnimation(Store.cardCurve) { _ = self.expanded.remove(key) }
            }
        } else {
            // Open: grow the card, then fade the text in when the height is at 85%.
            withAnimation(Store.cardCurve) { _ = expanded.insert(key) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Store.revealDelay) {
                guard self.expanded.contains(key) else { return }
                withAnimation(.easeOut(duration: 0.2)) { _ = self.revealed.insert(key) }
            }
        }
    }
    @Published var showAll = UserDefaults.standard.bool(forKey: "showAll") {
        didSet { UserDefaults.standard.set(showAll, forKey: "showAll"); refresh() }
    }
    private var scanning = false
    private var timer: Timer?

    var websites: [ServerGroup] { groups.filter { $0.kind == .website } }
    var background: [ServerGroup] { groups.filter { $0.kind == .background } }
    var system: [ServerGroup] { groups.filter { $0.kind == .system } }
    var orphans: [ServerGroup] { groups.filter(\.orphan) }

    static func loadStopped() -> [StoppedItem] {
        guard let data = UserDefaults.standard.data(forKey: "stopped") else { return [] }
        return (try? JSONDecoder().decode([StoppedItem].self, from: data)) ?? []
    }

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let all = showAll
        Task.detached {
            let result = Scanner.scan(showAll: all)
            await MainActor.run {
                self.groups = result
                self.scanning = false
                // A stopped item that is running again (started elsewhere) leaves the Stopped list.
                let running = Set(result.map(\.key))
                let runningFormulas = Set(result.compactMap(\.brewFormula))
                self.stopped.removeAll { item in
                    running.contains((item.cwd ?? "") + "|" + item.command)
                        || (item.brewFormula.map(runningFormulas.contains) ?? false)
                }
            }
        }
    }

    func stop(_ g: ServerGroup) {
        busy[g.id] = "Stopping…"
        // MCP helpers belong to a Claude session, so there is nothing sensible to start again later.
        if !g.isMCP && !g.orphan {
            let item = StoppedItem(title: g.info.title, project: g.project, command: g.command,
                                   cwd: g.cwd, brewFormula: g.brewFormula, date: Date())
            stopped.removeAll { $0.command == item.command && $0.cwd == item.cwd }
            stopped.insert(item, at: 0)
            if stopped.count > 12 { stopped.removeLast(stopped.count - 12) }
        }
        Task.detached {
            Control.stop(g)
            await MainActor.run { self.busy[g.id] = nil; self.refresh() }
        }
    }

    func restart(_ g: ServerGroup) {
        guard let cwd = g.cwd else { return }
        busy[g.id] = "Restarting…"
        Task.detached {
            Control.stopTree(g.rootPid)
            Control.waitForPortsFree(g.ports)
            let log = Control.launch(command: g.command, cwd: cwd, project: g.project)
            await MainActor.run {
                if let log { self.logs[g.key] = log }
                self.busy[g.id] = nil
                self.refresh()
            }
        }
    }

    func start(_ item: StoppedItem) {
        stopped.removeAll { $0.id == item.id }
        Task.detached {
            if let formula = item.brewFormula, let brewPath {
                _ = runTool(brewPath, ["services", "start", formula])
            } else if let cwd = item.cwd,
                      let log = Control.launch(command: item.command, cwd: cwd, project: item.project) {
                await MainActor.run { self.logs[cwd + "|" + item.command] = log }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { self.refresh() }
        }
    }

    func forget(_ item: StoppedItem) { stopped.removeAll { $0.id == item.id } }

    func cleanUp() { for g in orphans { stop(g) } }
}

// MARK: - Views

/// Small view-local state holder (avoids the @State macro, so the app builds with Command Line Tools only).
final class Flag: ObservableObject {
    @Published var on: Bool
    init(_ on: Bool = false) { self.on = on }
}

final class Measure: ObservableObject {
    @Published var height: CGFloat = 0
}

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: Buttons with hover and press states

enum ButtonLook { case plain, destructive, prominent(Color) }

struct PanelButtonStyle: ButtonStyle {
    var look: ButtonLook = .plain
    var circle = false
    func makeBody(configuration: Configuration) -> some View {
        PanelButtonBody(configuration: configuration, look: look, circle: circle)
    }
}

struct PanelButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let look: ButtonLook
    let circle: Bool
    @StateObject private var hover = Flag()
    @Environment(\.isEnabled) private var isEnabled

    private var fill: Color {
        let pressed = configuration.isPressed
        switch look {
        case .plain: return Color.primary.opacity(pressed ? 0.22 : hover.on ? 0.14 : 0.07)
        case .destructive: return Color.red.opacity(pressed ? 0.32 : hover.on ? 0.2 : 0.08)
        case .prominent(let c): return c.opacity(pressed ? 0.65 : hover.on ? 1 : 0.85)
        }
    }
    private var foreground: Color {
        switch look {
        case .plain: return .primary
        case .destructive: return .red
        case .prominent: return .white
        }
    }

    var body: some View {
        let shape = circle ? AnyShape(Circle()) : AnyShape(Capsule())
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, circle ? 0 : 10)
            .frame(width: circle ? 26 : nil, height: 26)
            .background(shape.fill(fill))
            .overlay(shape.stroke(Color.white.opacity(hover.on ? 0.45 : 0.18), lineWidth: 0.5))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hover.on)
            .onHover { hover.on = $0 }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var look: ButtonLook = .plain
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(PanelButtonStyle(look: look, circle: true))
        .help(help)
    }
}

// MARK: Building blocks

struct SectionTitle: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(verbatim: String(count))
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .textCase(.uppercase)
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }
}

struct BusyLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AdviceLine: View {
    let advice: Advice
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: advice.symbol).foregroundStyle(advice.color)
            (Text(advice.label).fontWeight(.semibold).foregroundColor(advice.color)
             + Text("  " + advice.detail).foregroundColor(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
    }
}

/// One line of detail: a small icon and some text.
struct DetailLine: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A card that shows only its header until you click it.
struct Card<Header: View, Details: View>: View {
    let key: String
    var tint: Color? = nil
    @ViewBuilder let header: () -> Header
    @ViewBuilder let details: () -> Details
    @EnvironmentObject var store: Store
    @StateObject private var hover = Flag()

    var body: some View {
        let open = store.expanded.contains(key)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                header()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture { store.toggle(key) }

            if open {
                VStack(alignment: .leading, spacing: 6) { details() }
                    .padding(.leading, 29)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                    .opacity(store.revealed.contains(key) ? 1 : 0)
                    .offset(y: store.revealed.contains(key) ? 0 : -4)
                    .transition(.identity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill((tint ?? Color.primary).opacity((tint == nil ? 0.06 : 0.13) + (hover.on ? 0.04 : 0)))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: hover.on)
        .onHover { hover.on = $0 }
    }
}

struct Dot: View {
    let color: Color
    var glow = false
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .shadow(color: glow ? color.opacity(0.6) : .clear, radius: 3)
    }
}

// MARK: Cards

struct WebsiteCard: View {
    let group: ServerGroup
    @EnvironmentObject var store: Store

    var body: some View {
        Card(key: group.key, tint: group.orphan ? .orange : nil) {
            Dot(color: .green, glow: true)
            Text(group.project).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 6)
            if let status = store.busy[group.id] {
                BusyLabel(text: status)
            } else {
                HStack(spacing: 5) {
                    if let port = group.webPorts.first {
                        IconButton(symbol: "safari", help: "Open localhost:\(port) in your browser", look: .prominent(.green)) {
                            NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!)
                        }
                    }
                    if group.canRestart {
                        IconButton(symbol: "arrow.clockwise", help: "Restart") { store.restart(group) }
                    }
                    IconButton(symbol: "stop.fill", help: "Stop", look: .destructive) { store.stop(group) }
                }
            }
        } details: {
            DetailLine(symbol: "info.circle", text: "\(group.info.title): \(group.info.text)")
            HStack(spacing: 6) {
                ForEach(group.webPorts, id: \.self) { port in
                    Button("localhost:" + String(port)) {
                        NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!)
                    }
                    .buttonStyle(PanelButtonStyle())
                    .font(.system(size: 11, design: .monospaced))
                }
                if let cwd = group.cwd, cwd != "/" {
                    Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) } label: {
                        Label("Show folder", systemImage: "folder")
                    }
                    .buttonStyle(PanelButtonStyle())
                }
                if let log = store.logs[group.key] {
                    Button { NSWorkspace.shared.open(log) } label: { Label("Log", systemImage: "doc.text") }
                        .buttonStyle(PanelButtonStyle())
                }
            }
            .padding(.vertical, 2)
            DetailLine(symbol: "person.crop.circle", text: "\(group.startedBy) · up \(group.uptime)")
            DetailLine(symbol: "eye", text: group.usedBy.isEmpty ? "Not open anywhere right now"
                                                                  : "Open now in \(group.usedBy.joined(separator: ", "))")
            AdviceLine(advice: group.info.advice).padding(.top, 2)
        }
        .help("\(group.command)\n\(group.cwd ?? "")\npid \(group.rootPid)")
    }
}

struct BackgroundCard: View {
    let group: ServerGroup
    @EnvironmentObject var store: Store

    private var dotColor: Color {
        if group.kind == .system { return .secondary }
        switch group.info.advice {
        case .safe: return .green
        case .ifUnused: return .orange
        case .keep: return .teal
        }
    }

    var body: some View {
        Card(key: group.key, tint: group.orphan ? .orange : nil) {
            Dot(color: dotColor)
            Text(group.info.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if group.hasProject {
                Text(group.project).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let status = store.busy[group.id] {
                BusyLabel(text: status)
            } else if group.canStop {
                IconButton(symbol: "stop.fill", help: group.brewFormula != nil ? "Turn off" : "Stop", look: .destructive) {
                    store.stop(group)
                }
            }
        } details: {
            DetailLine(symbol: "info.circle", text: group.info.text)
            DetailLine(symbol: "person.crop.circle",
                       text: ([group.startedBy] + (group.kind == .system ? [] : ["up \(group.uptime)"])).joined(separator: " · "))
            if group.kind != .system {
                DetailLine(symbol: "link", text: group.usedBy.isEmpty ? "No app is connected to it right now"
                                                                      : "Connected now: \(group.usedBy.joined(separator: ", "))")
            }
            AdviceLine(advice: group.info.advice).padding(.top, 2)
        }
        .help("\(group.command)\n\(group.cwd ?? "")\nport \(group.ports.map(String.init).joined(separator: ", ")) · pid \(group.rootPid)")
    }
}

/// Several copies of the same Claude helper, one per Claude session that loaded it.
struct HelperGroupCard: View {
    let copies: [ServerGroup]
    @EnvironmentObject var store: Store

    static func sessionName(_ g: ServerGroup) -> String {
        if g.cwd?.contains("/scratch-workspaces/") == true { return "Claude session with no folder" }
        if g.hasProject { return g.project }
        return g.startedBy == "Started by the Claude app" ? "Claude app chat" : "Unknown session"
    }

    var body: some View {
        let first = copies[0]
        Card(key: "helpers|" + first.info.title) {
            Dot(color: .teal)
            Text(first.info.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(verbatim: "×\(copies.count)")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.teal.opacity(0.18)))
            Spacer(minLength: 6)
        } details: {
            DetailLine(symbol: "info.circle", text: first.info.text)
            DetailLine(symbol: "square.stack", text: "Each Claude session that uses it starts its own copy. \(copies.count) open sessions use it now:")
            VStack(spacing: 4) {
                ForEach(copies) { g in
                    HStack(spacing: 8) {
                        Text(Self.sessionName(g)).font(.system(size: 11, weight: .medium))
                        Text("up \(g.uptime)").font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        if let status = store.busy[g.id] { BusyLabel(text: status) } else {
                            IconButton(symbol: "stop.fill", help: "Stop this copy", look: .destructive) { store.stop(g) }
                        }
                    }
                    .help("\(g.command)\n\(g.cwd ?? "")\npid \(g.rootPid)")
                }
            }
            .padding(.leading, 20)
            AdviceLine(advice: first.info.advice).padding(.top, 2)
        }
    }
}

struct StoppedRow: View {
    let item: StoppedItem
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 8) {
            Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 8, height: 8)
            Text(item.brewFormula != nil ? item.title : item.project)
                .font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(item.brewFormula != nil ? "Turned off" : item.title)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Start") { store.start(item) }
                .buttonStyle(PanelButtonStyle())
                .disabled(item.brewFormula == nil && item.cwd == nil)
            IconButton(symbol: "xmark", help: "Remove from this list") { store.forget(item) }
        }
        .padding(.leading, 29)
        .padding(.trailing, 12)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .help(item.command + "\n" + (item.cwd ?? ""))
    }
}

// MARK: Panel

struct ContentView: View {
    @EnvironmentObject var store: Store
    @StateObject private var login = Flag(SMAppService.mainApp.status == .enabled)
    @StateObject private var measure = Measure()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)

            ScrollView {
                content
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: HeightKey.self, value: geo.size.height)
                    })
            }
            .scrollIndicators(.never)
            .frame(height: min(max(measure.height, 60), 620))
            .onPreferenceChange(HeightKey.self) { h in
                Task { @MainActor in measure.height = h }
            }

            Divider().opacity(0.5)
            footer.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 440)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Servers").font(.system(size: 17, weight: .bold))
                Text("\(store.websites.count) website\(store.websites.count == 1 ? "" : "s") · \(store.background.count) in the background")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !store.orphans.isEmpty {
                Button { store.cleanUp() } label: {
                    Label("Clean up \(store.orphans.count)", systemImage: "sparkles")
                }
                .buttonStyle(PanelButtonStyle(look: .prominent(.orange)))
                .help("Stop servers whose window or session is already closed")
            }
            IconButton(symbol: "arrow.clockwise", help: "Refresh") { store.refresh() }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.groups.isEmpty && store.stopped.isEmpty {
                Text("Nothing is running")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            }
            if !store.websites.isEmpty {
                SectionTitle(title: "Websites", count: store.websites.count)
                ForEach(store.websites) { WebsiteCard(group: $0) }
            }
            if !store.background.isEmpty {
                SectionTitle(title: "Background", count: store.background.count)
                let helpers = Dictionary(grouping: store.background.filter(\.isMCP), by: \.info.title)
                ForEach(store.background.filter { !$0.isMCP }) { BackgroundCard(group: $0) }
                ForEach(helpers.keys.sorted(), id: \.self) { title in
                    let copies = helpers[title]!
                    if copies.count == 1 { BackgroundCard(group: copies[0]) } else { HelperGroupCard(copies: copies) }
                }
            }
            if !store.stopped.isEmpty {
                SectionTitle(title: "Stopped", count: store.stopped.count)
                ForEach(store.stopped) { StoppedRow(item: $0) }
            }
            if !store.system.isEmpty {
                SectionTitle(title: "Apps & system", count: store.system.count)
                ForEach(store.system) { BackgroundCard(group: $0) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Show apps", isOn: $store.showAll)
                .help("Also show ports opened by apps like Spotify or Figma")
            Toggle("Open at login", isOn: $login.on)
                .onChange(of: login.on) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        login.on = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(PanelButtonStyle())
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }
}

/// Borderless panel that can take keyboard focus without activating the app.
final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Tells us when SwiftUI content changes size, so the panel can follow it.
final class SizingHostingView<V: View>: NSHostingView<V> {
    var onResize: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onResize?() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    private var statusItem: NSStatusItem!
    private var panel: GlassPanel!
    private var host: SizingHostingView<AnyView>!
    private var storeChanges: AnyCancellable?
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.imagePosition = .imageLeading
        storeChanges = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
        updateStatusItem()

        host = SizingHostingView(rootView: AnyView(ContentView().environmentObject(store)))
        host.onResize = { [weak self] in self?.fitPanel() }

        // Native Liquid Glass surface (the same material as the Dock and Control Center).
        let glass = NSGlassEffectView()
        glass.cornerRadius = 24
        glass.style = .regular
        glass.contentView = host

        panel = GlassPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.contentView = glass
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        // The gentleman server (icon/MenuIcon*.png, exported from Figma). A warning sign when something needs cleaning up.
        let image = store.orphans.isEmpty
            ? (NSImage(named: "MenuIcon") ?? NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil))
            : NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        image?.isTemplate = true
        image?.accessibilityDescription = "Portly"
        button.image = image
        button.title = store.websites.isEmpty ? "" : " \(store.websites.count)"
    }

    @objc private func togglePanel() {
        panel.isVisible ? closePanel() : openPanel()
    }

    private func openPanel() {
        store.refresh()
        fitPanel(force: true)
        panel.makeKeyAndOrderFront(nil)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.closePanel() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.closePanel(); return nil }  // Esc
            return event
        }
    }

    private func closePanel() {
        panel.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// Size the panel to its content and hang it under the menu bar icon.
    private func fitPanel(force: Bool = false) {
        guard force || panel.isVisible, let button = statusItem.button, let buttonWindow = button.window else { return }
        let size = host.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        let frame = NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

// MARK: - Entry point

// `Portly --list` prints what the app sees, handy from a terminal.
if CommandLine.arguments.contains("--list") {
    for g in Scanner.scan(showAll: CommandLine.arguments.contains("--all")) {
        let ports = g.ports.map { ":\($0)" }.joined(separator: " ")
        print("[\(["web", "bg", "sys"][g.kind.rawValue])] \(g.project) — \(g.info.title)  \(ports)  pid \(g.rootPid)\(g.orphan ? "  ORPHAN" : "")")
        print("    \(g.info.text)")
        print("    used by: \(g.usedBy.joined(separator: ", ")) | \(g.startedBy) | \(g.info.advice.label): \(g.info.advice.detail)")
    }
    exit(0)
}

// `Portly --snapshot out.png` renders the panel into a normal window and saves it (for checking the layout).
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let out = CommandLine.arguments[i + 1]
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let store = MainActor.assumeIsolated { Store() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        MainActor.assumeIsolated {
            let host = NSHostingView(rootView: ContentView().environmentObject(store))
            host.frame.size = host.fittingSize
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: size.width, height: size.height),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.contentView = host
            window.level = .floating
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                // cacheDisplay does not draw glass or SF Symbols, so this only checks layout and text.
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                exit(0)
            }
        }
    }
    app.run()
}

if let i = CommandLine.arguments.firstIndex(where: { $0 == "--stop" || $0 == "--restart" }),
   i + 1 < CommandLine.arguments.count, let pid = Int32(CommandLine.arguments[i + 1]) {
    guard let g = Scanner.scan(showAll: true).first(where: { $0.rootPid == pid }) else {
        print("No server with root pid \(pid)"); exit(1)
    }
    if CommandLine.arguments[i] == "--restart", let cwd = g.cwd {
        Control.stopTree(g.rootPid)
        Control.waitForPortsFree(g.ports)
        print("Log: \(Control.launch(command: g.command, cwd: cwd, project: g.project)?.path ?? "launch failed")")
        sleep(1)
    } else {
        Control.stop(g)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
