import AppKit
import ApplicationServices
import Carbon
import Foundation
import ServiceManagement
import Vision

private struct FocusConfig {
    var taskName: String
    var focusMinutes: Int
    var breakMinutes: Int
    var rounds: Int
    var taskForgeFile: String?
    var taskForgeLine: Int?
    var taskForgeList: String?
    var taskNotesPath: String?
    var sessionId: String
    var markTaskInProgressOnStart: Bool = true
}

private struct TaskEvaluationInput: Codable {
    var taskTitle: String
    var focusMinutes: Int
    var breakMinutes: Int
    var rounds: Int
}

private struct TaskEvaluationResult: Decodable {
    var decision: String
    var reason: String
    var proposedTask: TaskEvaluationProposedTask?

    var shouldStartNow: Bool {
        decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "now"
    }
}

private struct TaskEvaluationProposedTask: Decodable {
    var title: String?
    var list: String?
    var tags: [String]?
    var estimateMinutes: Int?
    var due: String?
    var scheduled: String?

    private enum CodingKeys: String, CodingKey {
        case title
        case list
        case tags
        case estimateMinutes
        case due
        case scheduled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        list = try container.decodeIfPresent(String.self, forKey: .list)
        if let tagArray = try? container.decodeIfPresent([String].self, forKey: .tags) {
            tags = tagArray
        } else if let tagString = try? container.decodeIfPresent(String.self, forKey: .tags) {
            tags = tagString.split(separator: " ").map(String.init)
        } else {
            tags = nil
        }
        if let estimate = try? container.decodeIfPresent(Int.self, forKey: .estimateMinutes) {
            estimateMinutes = estimate
        } else if let estimateString = try? container.decodeIfPresent(String.self, forKey: .estimateMinutes) {
            estimateMinutes = Int(estimateString.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            estimateMinutes = nil
        }
        due = try container.decodeIfPresent(String.self, forKey: .due)
        scheduled = try container.decodeIfPresent(String.self, forKey: .scheduled)
    }
}

private struct ValidatedTaskProposal {
    var title: String
    var list: String
    var fileURL: URL
    var tags: [String]
    var estimateMinutes: Int
    var due: String?
    var scheduled: String?

    var summary: String {
        var parts = ["List: \(list)", "Estimate: \(estimateMinutes)m"]
        if !tags.isEmpty {
            parts.append("Tags: \(tags.joined(separator: " "))")
        }
        if let due {
            parts.append("Due: \(due)")
        }
        if let scheduled {
            parts.append("Scheduled: \(scheduled)")
        }
        return parts.joined(separator: "\n")
    }
}

private struct SessionSnapshot: Codable {
    var taskName: String
    var focusMinutes: Int
    var breakMinutes: Int
    var rounds: Int
    var taskForgeFile: String?
    var taskForgeLine: Int?
    var taskForgeList: String?
    var taskNotesPath: String?
    var sessionId: String?
    var loggedFocusRounds: [Int]?
    var round: Int
    var phase: String
    var savedAt: Date
}

private struct TaskForgeTask {
    let title: String
    let list: String
    let filePath: String
    let lineNumber: Int
    var isCompleted: Bool
    let estimate: String?
    let progress: String?
    let status: String?
    let dueDate: String?
    let dueTime: String?
    let scheduled: String?
    let scheduledAt: String?
    let endDate: String?
    let endAt: String?
    let taskNotesPath: String?

    var detail: String {
        var parts: [String] = []
        if let estimate, !estimate.isEmpty {
            parts.append("estimate \(estimate)")
        }
        if let progress, !progress.isEmpty {
            parts.append("progress \(progress)")
        }
        if let status, !status.isEmpty {
            parts.append(status)
        }
        if let scheduled, !scheduled.isEmpty {
            let time = scheduledAt.map { " \($0)" } ?? ""
            parts.append("scheduled \(scheduled)\(time)")
        }
        return parts.joined(separator: " | ")
    }

    var urgencyLabel: String {
        let time = TaskForgeStore.earliestTime(endAt: endAt, dueTime: dueTime, fallbackTime: scheduledAt)
        if isScheduledToday {
            return time ?? "-"
        }
        if let dueDate, !dueDate.isEmpty {
            return TaskForgeStore.relativeDayLabel(for: dueDate, time: time)
        }
        if let scheduled, !scheduled.isEmpty {
            return TaskForgeStore.relativeDayLabel(for: scheduled, time: time)
        }
        return "-"
    }

    var isScheduledToday: Bool {
        scheduled == TaskForgeStore.localTodayString()
    }

    var urgencyDate: Date? {
        let time = TaskForgeStore.earliestTime(endAt: endAt, dueTime: dueTime, fallbackTime: scheduledAt)
        if isScheduledToday, let scheduled {
            return TaskForgeStore.date(from: scheduled, time: time)
        }
        if let dueDate {
            return TaskForgeStore.date(from: dueDate, time: time)
        }
        if let scheduled {
            return TaskForgeStore.date(from: scheduled, time: time)
        }
        return nil
    }
}

private final class TaskForgeStore {
    static let wikiPath = ProcessInfo.processInfo.environment["TASKFORGE_WIKI_PATH"]
        ?? "\(NSHomeDirectory())/Documents/wiki"
    static let tasksURL = URL(fileURLWithPath: "\(wikiPath)/10_journal/TaskForge")
    static let pomodoroLogURL = URL(fileURLWithPath: "\(wikiPath)/99_meta/tasks/pomodoro-sessions.jsonl")
    static let impromptuTasksURL = URL(fileURLWithPath: "\(wikiPath)/10_journal/TaskForge/inbox.md")
    static let evaluateTaskDecisionScriptURL = URL(fileURLWithPath: "\(wikiPath)/99_meta/scripts/taskforge/run_evaluate_task_decision_shortcut.sh")

    private static let metadataPattern = try! NSRegularExpression(pattern: #"\[([A-Za-z0-9_-]+)::\s*([^\]]+)\]"#)
    private static let taskNotesPattern = try! NSRegularExpression(pattern: #"\[\[(10_journal/TaskNotes/[^\]|]+)"#)
    private static let dueDatePattern = try! NSRegularExpression(pattern: #"📅\s*(\d{4}-\d{2}-\d{2})"#)
    private static let dueTimePattern = try! NSRegularExpression(pattern: #"⏰\s*(\d{1,2})(?::(\d{2}))?\s*(AM|PM)"#, options: .caseInsensitive)
    private static let tagPattern = try! NSRegularExpression(pattern: #"^#?[A-Za-z0-9][A-Za-z0-9_/-]*$"#)

    static func loadOpenTasks() -> [TaskForgeTask] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tasksURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .flatMap(loadOpenTasks(from:))
            .sorted(by: isMoreUrgent)
    }

    private static func loadOpenTasks(from fileURL: URL) -> [TaskForgeTask] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let list = fileURL.deletingPathExtension().lastPathComponent
        return text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            parseTask(line: line, list: list, fileURL: fileURL, lineNumber: index + 1)
        }
    }

    private static func parseTask(line: String, list: String, fileURL: URL, lineNumber: Int) -> TaskForgeTask? {
        guard line.hasPrefix("- [ ] ") else { return nil }
        let metadata = metadataValues(in: line)
        let rawTitle = String(line.dropFirst(6))
        let title = cleanTitle(rawTitle)
        guard !title.isEmpty else { return nil }

        return TaskForgeTask(
            title: title,
            list: list,
            filePath: fileURL.path,
            lineNumber: lineNumber,
            isCompleted: false,
            estimate: metadata["estimate"],
            progress: metadata["progress"],
            status: metadata["status"],
            dueDate: firstCapture(dueDatePattern, in: line),
            dueTime: dueTime(in: line),
            scheduled: metadata["scheduled"],
            scheduledAt: metadata["scheduledat"],
            endDate: metadata["end"],
            endAt: metadata["endat"],
            taskNotesPath: firstCapture(taskNotesPattern, in: line)
        )
    }

    static func markInProgress(_ task: TaskForgeTask) throws {
        let fileURL = URL(fileURLWithPath: task.filePath)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        var lines = text.components(separatedBy: .newlines)
        let index = task.lineNumber - 1
        guard lines.indices.contains(index), lines[index].hasPrefix("- [ ] ") else { return }

        if lines[index].range(of: #"\[status::\s*[^\]]+\]"#, options: .regularExpression) != nil {
            lines[index] = lines[index].replacingOccurrences(
                of: #"\[status::\s*[^\]]+\]"#,
                with: "[status:: In Progress]",
                options: .regularExpression
            )
        } else {
            lines[index] += " [status:: In Progress]"
        }

        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func setCompleted(_ task: TaskForgeTask, completed: Bool) throws {
        let fileURL = URL(fileURLWithPath: task.filePath)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        var lines = text.components(separatedBy: .newlines)
        let index = task.lineNumber - 1
        guard lines.indices.contains(index) else { return }

        if lines[index].hasPrefix("- [ ] ") || lines[index].hasPrefix("- [x] ") || lines[index].hasPrefix("- [X] ") {
            lines[index].replaceSubrange(lines[index].startIndex..<lines[index].index(lines[index].startIndex, offsetBy: 6), with: completed ? "- [x] " : "- [ ] ")
        }

        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func createImpromptuTask(title rawTitle: String, estimateMinutes: Int, inProgress: Bool) throws -> TaskForgeTask {
        let proposal = validatedTaskProposal(from: nil, fallbackTitle: rawTitle, fallbackEstimateMinutes: estimateMinutes, forceInbox: true)
        return try createTask(from: proposal, inProgress: inProgress)
    }

    static func validatedTaskProposal(
        from proposedTask: TaskEvaluationProposedTask?,
        fallbackTitle: String,
        fallbackEstimateMinutes: Int,
        forceInbox: Bool = false
    ) -> ValidatedTaskProposal {
        let title = normalizedTaskTitle(proposedTask?.title ?? fallbackTitle)
        let fallback = normalizedTaskTitle(fallbackTitle)
        let finalTitle = title.isEmpty ? fallback : title
        let fileURL = forceInbox ? impromptuTasksURL : taskFileURL(for: proposedTask?.list)
        let list = fileURL.deletingPathExtension().lastPathComponent
        let estimate = min(240, max(5, proposedTask?.estimateMinutes ?? fallbackEstimateMinutes))
        return ValidatedTaskProposal(
            title: finalTitle,
            list: list,
            fileURL: fileURL,
            tags: normalizedTags(proposedTask?.tags ?? []),
            estimateMinutes: estimate,
            due: validDateString(proposedTask?.due),
            scheduled: validDateString(proposedTask?.scheduled)
        )
    }

    static func createTask(from proposal: ValidatedTaskProposal, inProgress: Bool) throws -> TaskForgeTask {
        let title = normalizedTaskTitle(proposal.title)
        guard !title.isEmpty else {
            throw NSError(
                domain: "TaskForgeStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Task title is required."]
            )
        }

        let targetURL = proposal.fileURL
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let taskLine = taskLine(title: title, proposal: proposal, inProgress: inProgress)
        var lines: [String]
        if FileManager.default.fileExists(atPath: targetURL.path) {
            let text = try String(contentsOf: targetURL, encoding: .utf8)
            lines = text.isEmpty ? [] : text.components(separatedBy: .newlines)
        } else {
            lines = []
        }

        let insertionIndex = taskInsertionIndex(in: lines, preferUndated: !inProgress)
        lines.insert(taskLine, at: insertionIndex)
        try lines.joined(separator: "\n").write(to: targetURL, atomically: true, encoding: .utf8)

        guard let task = parseTask(
            line: taskLine,
            list: targetURL.deletingPathExtension().lastPathComponent,
            fileURL: targetURL,
            lineNumber: insertionIndex + 1
        ) else {
            throw NSError(
                domain: "TaskForgeStore",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Created task could not be parsed."]
            )
        }
        return task
    }

    private static func taskFileURL(for proposedList: String?) -> URL {
        guard let proposedList else { return impromptuTasksURL }
        let normalized = proposedList
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".md", with: "")
        guard !normalized.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(
                at: tasksURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return impromptuTasksURL
        }
        return files.first {
            $0.pathExtension.lowercased() == "md" &&
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(normalized) == .orderedSame
        } ?? impromptuTasksURL
    }

    private static func taskLine(title: String, proposal: ValidatedTaskProposal, inProgress: Bool) -> String {
        var parts = ["- [ ] \(title)"]
        parts.append(contentsOf: proposal.tags)
        if inProgress {
            parts.append("[status:: In Progress]")
        }
        parts.append("[estimate:: \(proposal.estimateMinutes)m]")
        if let due = proposal.due {
            parts.append("📅 \(due)")
        }
        if let scheduled = proposal.scheduled {
            parts.append("[scheduled:: \(scheduled)]")
        }
        return parts.joined(separator: " ")
    }

    private static func taskInsertionIndex(in lines: [String], preferUndated: Bool) -> Int {
        guard preferUndated,
              let undatedIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Undated" }) else {
            return lines.endIndex
        }
        let nextHeading = lines[(undatedIndex + 1)...].firstIndex {
            $0.hasPrefix("## ") || $0.hasPrefix("# ")
        }
        return nextHeading ?? lines.endIndex
    }

    private static func impromptuInsertionIndex(in lines: [String]) -> Int {
        lines.endIndex
    }

    private static func normalizedTaskTitle(_ rawTitle: String) -> String {
        rawTitle
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizedTags(_ rawTags: [String]) -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for rawTag in rawTags {
            var tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            if tag.isEmpty { continue }
            if !tag.hasPrefix("#") {
                tag = "#\(tag)"
            }
            guard tagPattern.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) != nil else {
                continue
            }
            let key = tag.lowercased()
            if seen.insert(key).inserted {
                tags.append(tag)
            }
        }
        return tags
    }

    private static func validDateString(_ rawDate: String?) -> String? {
        guard let rawDate else { return nil }
        let dateString = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard dateString.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return nil }
        return formatter.string(from: date) == dateString ? dateString : nil
    }

    private static func metadataValues(in line: String) -> [String: String] {
        let ns = line as NSString
        var values: [String: String] = [:]
        for match in metadataPattern.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard match.numberOfRanges == 3 else { continue }
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let value = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }
        return values
    }

    private static func firstCapture(_ pattern: NSRegularExpression, in string: String) -> String? {
        let ns = string as NSString
        guard let match = pattern.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges > 1 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }

    static func localTodayString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func date(from dateString: String, time: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(dateString) \(normalizedTime(time) ?? "23:59")")
    }

    static func relativeDayLabel(for dateString: String, time: String?) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString),
              let today = formatter.date(from: localTodayString()),
              let days = Calendar.current.dateComponents([.day], from: today, to: date).day else {
            return dateString
        }
        return days > 0 ? "+\(days)D" : "\(days)D"
    }

    static func earliestTime(endAt: String?, dueTime: String?, fallbackTime: String?) -> String? {
        let candidates = [normalizedTime(endAt), normalizedTime(dueTime)].compactMap { $0 }
        if let earliest = candidates.min() {
            return earliest
        }
        return normalizedTime(fallbackTime)
    }

    static func isPastToday(time: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = formatter.date(from: "\(localTodayString()) \(time)") else {
            return false
        }
        return date < Date()
    }

    private static func normalizedTime(_ time: String?) -> String? {
        guard let time, !time.isEmpty else { return nil }
        let parts = time.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    private static func dueTime(in line: String) -> String? {
        let ns = line as NSString
        guard let match = dueTimePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges == 4,
              let rawHour = Int(ns.substring(with: match.range(at: 1))) else {
            return nil
        }
        let rawMinute = match.range(at: 2).location == NSNotFound ? "00" : ns.substring(with: match.range(at: 2))
        let meridiem = ns.substring(with: match.range(at: 3)).uppercased()
        var hour = rawHour % 12
        if meridiem == "PM" {
            hour += 12
        }
        return String(format: "%02d:%@", hour, rawMinute)
    }

    private static func isMoreUrgent(_ lhs: TaskForgeTask, _ rhs: TaskForgeTask) -> Bool {
        switch (lhs.urgencyDate, rhs.urgencyDate) {
        case let (left?, right?):
            if left != right {
                return left < right
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        if lhs.list != rhs.list {
            return lhs.list.localizedCaseInsensitiveCompare(rhs.list) == .orderedAscending
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private static func cleanTitle(_ raw: String) -> String {
        var title = raw
        title = title.replacingOccurrences(of: #"%%\[ticktick_id:: [^\]]+\]%%"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"%%[^%]+%%"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\[\[(?:10_journal/TaskNotes/[^\]|]+)(?:\|[^\]]+)?\]\]"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\[(?:scheduled|scheduledat|start|startat|end|endat|duration|schedulemode|firstscheduled|firstscheduledat|firststart|firststartat|firstend|firstendat|firstseen|firstseenat|created|createdat|estimate|progress|status|difficulty|priority_reason)::\s*[^\]]+\]"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"[📅⏳✅]\s*\d{4}-\d{2}-\d{2}"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"⏰\s*\d{1,2}(?::\d{2})?\s*(?:AM|PM)"#, with: "", options: [.regularExpression, .caseInsensitive])
        title = title.replacingOccurrences(of: #"🎯\s*\d{1,2}(?::\d{2})?\s*(?:AM|PM)"#, with: "", options: [.regularExpression, .caseInsensitive])
        title = title.replacingOccurrences(of: #"#remind-at-scheduled\b"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"[🔺⏫🔼🔽⏬]"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"^\[?\d{2}:\d{2}(?:\s*-\s*\d{2}:\d{2})?\]?\s*"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "^[\u{2600}-\u{26FF}\u{FE0F}\u{1F300}-\u{1F5FF}\u{2700}-\u{27BF}]+\\s*", with: "", options: .regularExpression)
        return title.split(separator: " ").joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum TimerPhase: String {
    case idle = "Idle"
    case focus = "Focus"
    case rest = "Break"
    case done = "Done"
}

private struct PomodoroLogEntry: Codable {
    var completedAt: String
    var taskTitle: String
    var taskForgeFile: String?
    var taskForgeLine: Int?
    var taskForgeList: String?
    var taskNotesPath: String?
    var plannedMinutes: Int
    var actualMinutes: Int
    var round: Int
    var totalRounds: Int
    var sessionId: String
    var source: String
}

private let globalHotKeyHandler: EventHandlerUPP = { _, _, userData in
    guard let userData else { return noErr }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        delegate.handleGlobalHotKey()
    }
    return noErr
}

private final class PromptController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static let evaluationTimeoutSeconds = 45.0
    private static let urgencyColumnSample = "23:59"
    private let queryField = NSTextField(string: "")
    private let tableView = NSTableView()
    private let taskField = NSTextField(string: "")
    private let focusField = NSTextField(string: "25")
    private let breakField = NSTextField(string: "10")
    private let roundsField = NSTextField(string: "2")
    private let inboxButton = NSButton(title: "Inbox Task", target: nil, action: nil)
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var allTasks: [TaskForgeTask]
    private var filteredTasks: [TaskForgeTask]
    private var selectedTask: TaskForgeTask?
    private var isEvaluating = false
    private var completion: ((FocusConfig?) -> Void)?

    convenience init(tasks: [TaskForgeTask], completion: @escaping (FocusConfig?) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 510),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Start Flow Focus Timer"
        window.center()
        self.init(window: window, tasks: tasks)
        self.completion = completion
        buildUI()
    }

    init(window: NSWindow, tasks: [TaskForgeTask]) {
        self.allTasks = tasks
        self.filteredTasks = tasks
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])

        queryField.placeholderString = "Search TaskForge tasks or type a new Inbox task"
        queryField.delegate = self
        queryField.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let searchStack = NSStackView()
        searchStack.orientation = .horizontal
        searchStack.alignment = .centerY
        searchStack.spacing = 10
        searchStack.addArrangedSubview(queryField)

        inboxButton.target = self
        inboxButton.action = #selector(useImpromptuTask)
        inboxButton.widthAnchor.constraint(equalToConstant: 130).isActive = true
        searchStack.addArrangedSubview(inboxButton)
        stack.addArrangedSubview(searchStack)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView
        scrollView.heightAnchor.constraint(equalToConstant: 250).isActive = true

        let doneColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("done"))
        doneColumn.title = ""
        doneColumn.width = 28
        let taskColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("task"))
        taskColumn.title = "Task"
        taskColumn.width = 332
        let whenColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("when"))
        whenColumn.title = "When"
        let whenColumnWidth = Self.urgencyColumnWidth()
        whenColumn.width = whenColumnWidth
        whenColumn.minWidth = whenColumnWidth
        whenColumn.maxWidth = whenColumnWidth
        let sourceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        sourceColumn.title = "Source"
        sourceColumn.width = 130
        tableView.addTableColumn(doneColumn)
        tableView.addTableColumn(taskColumn)
        tableView.addTableColumn(whenColumn)
        tableView.addTableColumn(sourceColumn)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(start)
        stack.addArrangedSubview(scrollView)

        taskField.delegate = self
        stack.addArrangedSubview(row(label: "Task", field: taskField))
        stack.addArrangedSubview(row(label: "Focus min", field: focusField))
        stack.addArrangedSubview(row(label: "Break min", field: breakField))
        stack.addArrangedSubview(row(label: "Sessions", field: roundsField))

        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 10

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true
        stack.addArrangedSubview(statusLabel)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        startButton.target = self
        startButton.action = #selector(start)
        startButton.keyEquivalent = "\r"
        buttonStack.addArrangedSubview(cancelButton)
        buttonStack.addArrangedSubview(startButton)
        stack.addArrangedSubview(buttonStack)

        tableView.reloadData()
        if !filteredTasks.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            selectTask(filteredTasks[0])
        }
        window?.makeFirstResponder(queryField)
    }

    private func row(label: String, field: NSTextField) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.widthAnchor.constraint(equalToConstant: 90).isActive = true
        field.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let stack = NSStackView(views: [labelView, field])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private static func urgencyColumnWidth() -> CGFloat {
        ceil(urgencyColumnSample.size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ]).width) + 12
    }

    @objc private func cancel() {
        guard !isEvaluating else { return }
        completion?(nil)
        close()
    }

    @objc private func useImpromptuTask() {
        guard !isEvaluating else { return }
        let task = queryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !task.isEmpty,
            let focus = Int(focusField.stringValue), focus > 0,
            let rest = Int(breakField.stringValue), rest >= 0,
            let rounds = Int(roundsField.stringValue), rounds > 0
        else {
            NSSound.beep()
            window?.makeFirstResponder(queryField)
            return
        }

        selectedTask = nil
        tableView.deselectAll(nil)
        startInboxTask(taskName: task, focus: focus, rest: rest, rounds: rounds)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isEvaluating else { return }
        if obj.object as? NSTextField === queryField {
            applyFilter()
        } else if obj.object as? NSTextField === taskField,
                  taskField.stringValue != selectedTask?.title {
            selectedTask = nil
            tableView.deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredTasks.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredTasks.indices.contains(row) else { return nil }
        let task = filteredTasks[row]
        let columnId = tableColumn?.identifier.rawValue ?? "task"
        if columnId == "done" {
            let identifier = NSUserInterfaceItemIdentifier("doneCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = identifier

            let checkbox: NSButton
            if let existing = cell.subviews.first(where: { $0 is NSButton }) as? NSButton {
                checkbox = existing
            } else {
                checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleTaskCompleted(_:)))
                checkbox.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(checkbox)
                NSLayoutConstraint.activate([
                    checkbox.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                    checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            checkbox.target = self
            checkbox.action = #selector(toggleTaskCompleted(_:))
            checkbox.tag = row
            checkbox.state = task.isCompleted ? .on : .off
            return cell
        }

        let identifier = "\(columnId)Cell"
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(identifier), owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier(identifier)

        let textField = cell.textField ?? NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        if cell.textField == nil {
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        if columnId == "when" {
            textField.stringValue = task.urgencyLabel
            textField.textColor = .secondaryLabelColor
            textField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            textField.alignment = .right
        } else if columnId == "source" {
            textField.stringValue = task.list
            textField.textColor = .secondaryLabelColor
            textField.font = .systemFont(ofSize: NSFont.systemFontSize)
            textField.alignment = .left
        } else {
            textField.stringValue = task.title
            textField.textColor = task.isCompleted ? .secondaryLabelColor : .labelColor
            textField.font = .systemFont(ofSize: NSFont.systemFontSize)
            textField.alignment = .left
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isEvaluating else { return }
        let row = tableView.selectedRow
        guard filteredTasks.indices.contains(row) else { return }
        selectTask(filteredTasks[row])
    }

    @objc private func start() {
        guard !isEvaluating else { return }
        let task = taskField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !task.isEmpty,
            let focus = Int(focusField.stringValue), focus > 0,
            let rest = Int(breakField.stringValue), rest >= 0,
            let rounds = Int(roundsField.stringValue), rounds > 0
        else {
            NSSound.beep()
            return
        }

        if let selectedTask {
            guard !selectedTask.isCompleted else {
                NSSound.beep()
                return
            }
            completeStart(taskName: task, focus: focus, rest: rest, rounds: rounds, taskForgeTask: selectedTask, markTaskInProgressOnStart: true)
        } else {
            startInboxTask(taskName: task, focus: focus, rest: rest, rounds: rounds)
        }
    }

    @objc private func toggleTaskCompleted(_ sender: NSButton) {
        guard !isEvaluating, filteredTasks.indices.contains(sender.tag) else { return }
        var task = filteredTasks[sender.tag]
        let completed = sender.state == .on

        do {
            try TaskForgeStore.setCompleted(task, completed: completed)
        } catch {
            sender.state = task.isCompleted ? .on : .off
            showMessage(title: "Could not update TaskForge task", message: error.localizedDescription)
            return
        }

        task.isCompleted = completed
        if let filteredIndex = filteredTasks.firstIndex(where: { $0.filePath == task.filePath && $0.lineNumber == task.lineNumber }) {
            filteredTasks[filteredIndex] = task
        }
        if let allIndex = allTasks.firstIndex(where: { $0.filePath == task.filePath && $0.lineNumber == task.lineNumber }) {
            allTasks[allIndex] = task
        }
        if selectedTask?.filePath == task.filePath && selectedTask?.lineNumber == task.lineNumber {
            selectedTask = task
            if completed {
                taskField.stringValue = ""
            } else {
                selectTask(task)
            }
        }
        tableView.reloadData()
    }

    private func startInboxTask(taskName: String, focus: Int, rest: Int, rounds: Int) {
        setEvaluating(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let evaluation = Result {
                try self?.evaluateInboxTask(taskName: taskName, focus: focus, rest: rest, rounds: rounds)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.isEvaluating else { return }
                self.setEvaluating(false)

                switch evaluation {
                case .success(let result?):
                    self.handleInboxEvaluationResult(result, taskName: taskName, focus: focus, rest: rest, rounds: rounds)
                case .success(nil):
                    return
                case .failure(let error):
                    self.handleInboxEvaluationFailure(error, taskName: taskName, focus: focus, rest: rest, rounds: rounds)
                }
            }
        }
    }

    private func handleInboxEvaluationResult(_ result: TaskEvaluationResult, taskName: String, focus: Int, rest: Int, rounds: Int) {
        let activeProposal = TaskForgeStore.validatedTaskProposal(
            from: result.proposedTask,
            fallbackTitle: taskName,
            fallbackEstimateMinutes: focus,
            forceInbox: true
        )
        let laterProposal = TaskForgeStore.validatedTaskProposal(
            from: result.proposedTask,
            fallbackTitle: taskName,
            fallbackEstimateMinutes: focus
        )

        if result.shouldStartNow {
            createTaskAndCompleteStart(proposal: activeProposal, focus: focus, rest: rest, rounds: rounds, inProgress: true)
            return
        }

        switch askLaterDecision(reason: result.reason, proposal: laterProposal) {
        case .alertFirstButtonReturn:
            createTaskAndCompleteStart(proposal: activeProposal, focus: focus, rest: rest, rounds: rounds, inProgress: true)
        default:
            createTaskAndClose(proposal: laterProposal, inProgress: false)
        }
    }

    private func handleInboxEvaluationFailure(_ error: Error, taskName: String, focus: Int, rest: Int, rounds: Int) {
        switch askEvaluationFailure(error: error) {
        case .alertFirstButtonReturn:
            let proposal = TaskForgeStore.validatedTaskProposal(
                from: nil,
                fallbackTitle: taskName,
                fallbackEstimateMinutes: focus,
                forceInbox: true
            )
            createTaskAndCompleteStart(proposal: proposal, focus: focus, rest: rest, rounds: rounds, inProgress: true)
        default:
            return
        }
    }

    private func setEvaluating(_ evaluating: Bool) {
        isEvaluating = evaluating
        queryField.isEnabled = !evaluating
        tableView.isEnabled = !evaluating
        taskField.isEnabled = !evaluating
        focusField.isEnabled = !evaluating
        breakField.isEnabled = !evaluating
        roundsField.isEnabled = !evaluating
        inboxButton.isEnabled = !evaluating
        startButton.isEnabled = !evaluating
        statusLabel.stringValue = evaluating ? "Evaluating task..." : ""
        statusLabel.isHidden = !evaluating
    }

    private func createTaskAndCompleteStart(proposal: ValidatedTaskProposal, focus: Int, rest: Int, rounds: Int, inProgress: Bool) {
        do {
            let taskForgeTask = try TaskForgeStore.createTask(from: proposal, inProgress: inProgress)
            completeStart(
                taskName: proposal.title,
                focus: focus,
                rest: rest,
                rounds: rounds,
                taskForgeTask: taskForgeTask,
                markTaskInProgressOnStart: false
            )
        } catch {
            showMessage(title: "Could not create TaskForge task", message: error.localizedDescription)
        }
    }

    private func createTaskAndClose(proposal: ValidatedTaskProposal, inProgress: Bool) {
        do {
            _ = try TaskForgeStore.createTask(from: proposal, inProgress: inProgress)
            close()
        } catch {
            showMessage(title: "Could not create TaskForge task", message: error.localizedDescription)
        }
    }

    private func completeStart(
        taskName: String,
        focus: Int,
        rest: Int,
        rounds: Int,
        taskForgeTask: TaskForgeTask,
        markTaskInProgressOnStart: Bool
    ) {
        completion?(FocusConfig(
            taskName: taskName,
            focusMinutes: focus,
            breakMinutes: rest,
            rounds: rounds,
            taskForgeFile: taskForgeTask.filePath,
            taskForgeLine: taskForgeTask.lineNumber,
            taskForgeList: taskForgeTask.list,
            taskNotesPath: taskForgeTask.taskNotesPath,
            sessionId: UUID().uuidString,
            markTaskInProgressOnStart: markTaskInProgressOnStart
        ))
        close()
    }

    private func evaluateInboxTask(taskName: String, focus: Int, rest: Int, rounds: Int) throws -> TaskEvaluationResult {
        let input = TaskEvaluationInput(taskTitle: taskName, focusMinutes: focus, breakMinutes: rest, rounds: rounds)
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EvaluateTaskDecision-\(UUID().uuidString)-input.json")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EvaluateTaskDecision-\(UUID().uuidString)-output.json")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(input).write(to: inputURL, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [TaskForgeStore.evaluateTaskDecisionScriptURL.path, "--input-path", inputURL.path, "--output-path", outputURL.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + Self.evaluationTimeoutSeconds) == .timedOut {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            throw NSError(
                domain: "TaskEvaluation",
                code: 124,
                userInfo: [NSLocalizedDescriptionKey: "Evaluate Task Decision timed out after \(Int(Self.evaluationTimeoutSeconds)) seconds."]
            )
        }
        process.terminationHandler = nil

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "TaskEvaluation",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "Evaluate Task Decision failed."]
            )
        }

        let output = try Data(contentsOf: outputURL)
        return try JSONDecoder().decode(TaskEvaluationResult.self, from: output)
    }

    private func askLaterDecision(reason: String, proposal: ValidatedTaskProposal) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Do this task later?"
        let recommendation = reason.isEmpty ? "The evaluator recommended doing this later." : reason
        alert.informativeText = "\(recommendation)\n\n\(proposal.summary)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start Anyway")
        alert.addButton(withTitle: "Do Later")
        return alert.runModal()
    }

    private func askEvaluationFailure(error: Error) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Could not evaluate task"
        alert.informativeText = "\(error.localizedDescription)\n\nStart anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Start Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal()
    }

    private func applyFilter() {
        let query = queryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            filteredTasks = allTasks
        } else {
            let tokens = query.split(separator: " ").map(String.init)
            filteredTasks = allTasks.filter { task in
                let haystack = "\(task.title) \(task.list) \(task.estimate ?? "") \(task.progress ?? "") \(task.status ?? "") \(task.dueDate ?? "") \(task.dueTime ?? "") \(task.scheduled ?? "") \(task.scheduledAt ?? "") \(task.endAt ?? "")".lowercased()
                return tokens.allSatisfy { haystack.contains($0) }
            }
        }

        tableView.reloadData()
        if let selectedTask,
           let index = filteredTasks.firstIndex(where: { $0.filePath == selectedTask.filePath && $0.lineNumber == selectedTask.lineNumber }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !filteredTasks.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            selectTask(filteredTasks[0])
        }
    }

    private func selectTask(_ task: TaskForgeTask) {
        selectedTask = task
        taskField.stringValue = task.title
        if let estimateMinutes = estimateMinutes(from: task.estimate), estimateMinutes > 0 {
            focusField.stringValue = "\(min(max(estimateMinutes, 5), 60))"
        }
    }

    private func estimateMinutes(from estimate: String?) -> Int? {
        guard let estimate else { return nil }
        let pattern = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*(h|hr|hrs|hour|hours|m|min|mins|minute|minutes)"#, options: .caseInsensitive)
        let ns = estimate as NSString
        var total = 0.0
        for match in pattern.matches(in: estimate, range: NSRange(estimate.startIndex..., in: estimate)) {
            guard match.numberOfRanges >= 3,
                  let amount = Double(ns.substring(with: match.range(at: 1))) else {
                continue
            }
            let unit = ns.substring(with: match.range(at: 2)).lowercased()
            total += unit.hasPrefix("h") ? amount * 60 : amount
        }
        return total > 0 ? Int(total.rounded()) : Int(estimate)
    }

    private func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private final class AccessibilityPermissionController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Accessibility Permission Required"
        window.center()
        self.init(window: window)
        buildUI()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22)
        ])

        let title = NSTextField(labelWithString: "Allow this helper to control Flow")
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString: "The helper can use macOS Accessibility automation for fallback timer controls. Add this Swift process or Terminal to Accessibility, then start the timer again.")
        body.textColor = .secondaryLabelColor

        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        buttonStack.distribution = .fillEqually

        let openButton = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openSettings))
        let doneButton = NSButton(title: "Done", target: self, action: #selector(done))
        buttonStack.addArrangedSubview(openButton)
        buttonStack.addArrangedSubview(doneButton)

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(body)
        stack.addArrangedSubview(buttonStack)
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func done() {
        close()
    }
}

private final class SessionProgressController: NSWindowController {
    private let currentRoundField: NSTextField
    private let totalRoundsField: NSTextField
    private var completion: ((Int, Int) -> Void)?

    convenience init(currentRound: Int, totalRounds: Int, completion: @escaping (Int, Int) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 145),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Session Progress"
        window.center()
        self.init(
            window: window,
            currentRoundField: NSTextField(string: "\(currentRound)"),
            totalRoundsField: NSTextField(string: "\(totalRounds)")
        )
        self.completion = completion
        buildUI()
    }

    init(window: NSWindow, currentRoundField: NSTextField, totalRoundsField: NSTextField) {
        self.currentRoundField = currentRoundField
        self.totalRoundsField = totalRoundsField
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20)
        ])

        stack.addArrangedSubview(row(label: "Current", field: currentRoundField))
        stack.addArrangedSubview(row(label: "Total", field: totalRoundsField))

        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 10
        buttonStack.addArrangedSubview(NSButton(title: "Cancel", target: self, action: #selector(cancel)))
        let applyButton = NSButton(title: "Apply", target: self, action: #selector(apply))
        applyButton.keyEquivalent = "\r"
        buttonStack.addArrangedSubview(applyButton)
        stack.addArrangedSubview(buttonStack)
    }

    private func row(label: String, field: NSTextField) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.widthAnchor.constraint(equalToConstant: 75).isActive = true
        field.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let stack = NSStackView(views: [labelView, field])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    @objc private func cancel() {
        close()
    }

    @objc private func apply() {
        guard
            let current = Int(currentRoundField.stringValue), current > 0,
            let total = Int(totalRoundsField.stringValue), total > 0,
            current <= total
        else {
            NSSound.beep()
            return
        }
        completion?(current, total)
        close()
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let flowBundleIdentifier = "design.yugen.Flow"
    private let statusItem = NSStatusBar.system.statusItem(withLength: 112)
    private var promptController: PromptController?
    private var accessibilityController: AccessibilityPermissionController?
    private var sessionProgressController: SessionProgressController?
    private var config: FocusConfig?
    private var phase: TimerPhase = .idle
    private var round = 1
    private var remainingSeconds = 0
    private var phaseTotalSeconds = 0
    private var timer: Timer?
    private var permissionPollTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var lastKnownTaskName = ""
    private var lastRefreshAtZero: Date?
    private var loggedFocusRounds = Set<Int>()
    private var showRing = UserDefaults.standard.object(forKey: "showRing") as? Bool ?? true
    private var showTaskName = UserDefaults.standard.object(forKey: "showTaskName") as? Bool ?? false
    private var showTime = UserDefaults.standard.object(forKey: "showTime") as? Bool ?? true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        log("launch: Endel Focus Menu Bar started")
        setupStandardEditMenu()
        restoreSessionSnapshot()
        statusItem.button?.title = ""
        updateStatusTitle()
        rebuildMenu()
        registerGlobalHotKey()
        if requestAccessibilityPermissionIfNeeded(showPane: true) {
            log("launch: accessibility trusted; refreshing Flow state")
            refreshStateFromFlow()
        } else {
            log("launch: accessibility not trusted; waiting for permission")
        }
    }

    private func setupStandardEditMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let editMenuItem = NSMenuItem()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        appMenu.items.forEach { $0.target = self }
        appMenuItem.submenu = appMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        closeFlowIfRunning(reason: "helper terminating")
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Start Flow Session...", action: #selector(openPrompt), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Refresh State", action: #selector(refreshStateFromFlow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Set Session Progress...", action: #selector(openSessionProgress), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset Menu Countdown", action: #selector(stopCountdown), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "Pause Flow Session", action: #selector(pauseFlowSession), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset Flow Cycle", action: #selector(resetFlowCycle), keyEquivalent: ""))
        let shortcutItem = NSMenuItem(title: "Global Shortcut: Ctrl Option Cmd F", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)
        menu.addItem(.separator())
        menu.addItem(displayMenuItem(title: "Show Ring", action: #selector(toggleShowRing), state: showRing))
        menu.addItem(displayMenuItem(title: "Show Task Name", action: #selector(toggleShowTaskName), state: showTaskName))
        menu.addItem(displayMenuItem(title: "Show Time", action: #selector(toggleShowTime), state: showTime))
        menu.addItem(.separator())
        menu.addItem(displayMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), state: isStartAtLoginEnabled()))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Flow", action: #selector(openFlow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func displayMenuItem(title: String, action: Selector, state: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.state = state ? .on : .off
        return item
    }

    fileprivate func handleGlobalHotKey() {
        if config == nil || phase == .idle || phase == .done {
            openPrompt()
        } else {
            pauseFlowSessionIfAvailable()
            statusItem.button?.performClick(nil)
        }
    }

    private func registerGlobalHotKey() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotKeyHandlerRef
        )
        guard handlerStatus == noErr else {
            log("hotkey: failed to install handler status=\(handlerStatus)")
            return
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x45464D42), id: 1)
        let modifierFlags = UInt32(controlKey | optionKey | cmdKey)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_F),
            modifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus == noErr {
            log("hotkey: registered Ctrl+Option+Command+F")
        } else {
            log("hotkey: failed to register Ctrl+Option+Command+F status=\(registerStatus)")
            if let hotKeyHandlerRef {
                RemoveEventHandler(hotKeyHandlerRef)
                self.hotKeyHandlerRef = nil
            }
        }
    }

    @objc private func openPrompt() {
        guard requestAccessibilityPermissionIfNeeded(showPane: true) else { return }

        let tasks = TaskForgeStore.loadOpenTasks()
        promptController = PromptController(tasks: tasks) { [weak self] config in
            guard let self, let config else { return }
            self.config = config
            self.round = 1
            self.phase = .focus
            self.lastKnownTaskName = config.taskName
            self.loggedFocusRounds = []
            if config.markTaskInProgressOnStart {
                self.markSelectedTaskInProgress(config)
            }
            self.remainingSeconds = config.focusMinutes * 60
            self.phaseTotalSeconds = self.remainingSeconds
            self.persistSessionSnapshot()
            self.updateStatusTitle()
            self.startLocalCountdown()
            self.startFlow(config)
        }
        promptController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openFlow() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Flow.app"))
    }

    @objc private func stopCountdown() {
        timer?.invalidate()
        timer = nil
        phase = .idle
        remainingSeconds = 0
        phaseTotalSeconds = 0
        loggedFocusRounds = []
        updateStatusTitle()
        clearSessionSnapshot()
    }

    @objc private func openSessionProgress() {
        let totalRounds = config?.rounds ?? max(round, 1)
        sessionProgressController = SessionProgressController(currentRound: round, totalRounds: totalRounds) { [weak self] current, total in
            guard let self else { return }
            let existing = self.config ?? FocusConfig(
                taskName: self.lastKnownTaskName,
                focusMinutes: 25,
                breakMinutes: 10,
                rounds: total,
                taskForgeFile: nil,
                taskForgeLine: nil,
                taskForgeList: nil,
                taskNotesPath: nil,
                sessionId: UUID().uuidString
            )
            self.config = FocusConfig(
                taskName: existing.taskName,
                focusMinutes: existing.focusMinutes,
                breakMinutes: existing.breakMinutes,
                rounds: total,
                taskForgeFile: existing.taskForgeFile,
                taskForgeLine: existing.taskForgeLine,
                taskForgeList: existing.taskForgeList,
                taskNotesPath: existing.taskNotesPath,
                sessionId: existing.sessionId
            )
            self.round = current
            self.persistSessionSnapshot()
            self.updateStatusTitle()
            self.log("session-progress: set current=\(current) total=\(total)")
        }
        sessionProgressController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func pauseFlowSession() {
        if pauseFlowSessionIfAvailable() {
            timer?.invalidate()
            timer = nil
            updateStatusTitle()
        } else {
            showMessage(title: "Could not pause Flow", message: "The helper could not send Flow's Pause Session command.")
        }
    }

    @objc private func resetFlowCycle() {
        if runFlowCommand("reset") != nil {
            log("flow: reset cycle")
            stopCountdown()
        } else {
            showMessage(title: "Could not reset Flow", message: "The helper could not send Flow's Reset Cycle command.")
        }
    }

    @discardableResult
    private func pauseFlowSessionIfAvailable() -> Bool {
        guard runFlowCommand("stop") != nil else {
            log("flow: could not pause session")
            return false
        }
        log("flow: paused session")
        return true
    }

    @objc private func toggleShowRing() {
        setDisplayOption(\.showRing, key: "showRing", value: !showRing)
    }

    @objc private func toggleShowTaskName() {
        setDisplayOption(\.showTaskName, key: "showTaskName", value: !showTaskName)
    }

    @objc private func toggleShowTime() {
        setDisplayOption(\.showTime, key: "showTime", value: !showTime)
    }

    private func setDisplayOption(_ keyPath: ReferenceWritableKeyPath<AppDelegate, Bool>, key: String, value: Bool) {
        let enabledCount = [showRing, showTaskName, showTime].filter { $0 }.count
        if !value, self[keyPath: keyPath], enabledCount <= 1 {
            NSSound.beep()
            return
        }

        self[keyPath: keyPath] = value
        UserDefaults.standard.set(value, forKey: key)
        rebuildMenu()
        updateStatusTitle()
    }

    @objc private func toggleStartAtLogin() {
        do {
            if isStartAtLoginEnabled() {
                try SMAppService.mainApp.unregister()
                log("login-item: disabled")
            } else {
                try SMAppService.mainApp.register()
                log("login-item: enabled")
            }
            rebuildMenu()
        } catch {
            log("login-item: \(error)")
            showMessage(title: "Could not update login item", message: error.localizedDescription)
        }
    }

    private func isStartAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func refreshStateFromFlow() {
        guard runningFlowApplication() != nil else {
            log("refresh: Flow is not running")
            stopCountdown()
            return
        }

        guard
            let title = runFlowCommand("getTitle"),
            let phaseText = runFlowCommand("getPhase"),
            let timeText = runFlowCommand("getTime")
        else {
            log("refresh: could not read Flow state")
            return
        }

        applyFlowState(title: title, phaseText: phaseText, timeText: timeText)
    }

    @objc private func quit() {
        closeFlowIfRunning(reason: "quit menu")
        NSApp.terminate(nil)
    }

    private func closeFlowIfRunning(reason: String) {
        guard let flow = runningFlowApplication() else {
            log("quit: Flow is not running (\(reason))")
            return
        }

        log("quit: closing Flow (\(reason))")
        if !flow.terminate() {
            log("quit: Flow did not accept terminate request")
        }

        let deadline = Date().addingTimeInterval(2.0)
        while !flow.isTerminated && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        guard !flow.isTerminated else { return }
        log("quit: force terminating Flow")
        flow.forceTerminate()
    }

    private func runningFlowApplication() -> NSRunningApplication? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: flowBundleIdentifier).first {
            return app
        }
        return NSWorkspace.shared.runningApplications.first { app in
            app.localizedName == "Flow" || app.bundleURL?.lastPathComponent == "Flow.app"
        }
    }

    private func startLocalCountdown() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard config != nil else { return }
        remainingSeconds -= 1

        if remainingSeconds <= 0 {
            remainingSeconds = 0
            updateStatusTitle()
            refreshAtTimerBoundary()
            return
        }

        updateStatusTitle()
    }

    private func refreshAtTimerBoundary() {
        let now = Date()
        if let lastRefreshAtZero, now.timeIntervalSince(lastRefreshAtZero) < 3 {
            return
        }

        lastRefreshAtZero = now
        log("timer: reached 00:00; refreshing Flow state")
        timer?.invalidate()
        timer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.refreshStateFromFlow()
        }
    }

    private func advanceRound(_ config: FocusConfig) {
        if round < config.rounds {
            round += 1
            phase = .focus
            remainingSeconds = config.focusMinutes * 60
            phaseTotalSeconds = remainingSeconds
        } else {
            phase = .done
            remainingSeconds = 0
            phaseTotalSeconds = 0
            timer?.invalidate()
            timer = nil
        }
    }

    private func updateStatusTitle() {
        let minutes = max(remainingSeconds, 0) / 60
        let seconds = max(remainingSeconds, 0) % 60
        let time = String(format: "%02d:%02d", minutes, seconds)
        let roundText = config.map { " \(round)/\($0.rounds)" } ?? ""
        let label = phase == .idle ? "--:--" : time
        let taskText = lastKnownTaskName.isEmpty ? "" : " - \(lastKnownTaskName)"
        let tooltip = "Flow \(phase.rawValue)\(roundText) \(time)\(taskText)"
        statusItem.button?.image = statusImage(label: label, progress: progressFraction())
        statusItem.length = statusItemLength()
        statusItem.button?.toolTip = tooltip
    }

    private func statusItemLength() -> CGFloat {
        let text = statusText(label: "00:00")
        let textWidth = text.isEmpty ? 0 : min(180, max(46, text.size(withAttributes: statusTextAttributes()).width + 8))
        let ringWidth: CGFloat = showRing ? 24 : 0
        return max(24, ringWidth + textWidth + 4)
    }

    private func applyEndelStateText(_ text: String) {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let timerIndex = lines.firstIndex(where: isPhaseLine) else {
            log("refresh: no active Endel phase found; resetting menu countdown")
            if phase == .focus, remainingSeconds == 0 {
                logCompletedFocusRound(round)
            }
            stopCountdown()
            return
        }

        let previousPhase = phase
        let previousRound = round
        let previousConfig = config
        phase = phaseFromLine(lines[timerIndex])
        if lines.indices.contains(timerIndex + 1), !isTimerString(lines[timerIndex + 1]) {
            lastKnownTaskName = lines[timerIndex + 1]
        }

        guard let timeLine = lines.first(where: isTimerString), let seconds = secondsFromTimerString(timeLine) else {
            log("refresh: phase found but no timer string found")
            updateStatusTitle()
            return
        }

        remainingSeconds = seconds
        let markerCount = sessionMarkerCount(in: lines)
        let expectedTotal = phase == .rest ? (config?.breakMinutes ?? 10) * 60 : (config?.focusMinutes ?? 25) * 60
        phaseTotalSeconds = max(expectedTotal, seconds)
        if config == nil {
            if let snapshot = loadSessionSnapshot(), snapshot.taskName == lastKnownTaskName {
                config = FocusConfig(
                    taskName: snapshot.taskName,
                    focusMinutes: snapshot.focusMinutes,
                    breakMinutes: snapshot.breakMinutes,
                    rounds: max(snapshot.rounds, markerCount),
                    taskForgeFile: snapshot.taskForgeFile,
                    taskForgeLine: snapshot.taskForgeLine,
                    taskForgeList: snapshot.taskForgeList,
                    taskNotesPath: snapshot.taskNotesPath,
                    sessionId: snapshot.sessionId ?? UUID().uuidString
                )
                round = min(max(snapshot.round, 1), snapshot.rounds)
            } else {
                config = FocusConfig(
                    taskName: lastKnownTaskName,
                    focusMinutes: max(1, phase == .focus ? phaseTotalSeconds / 60 : 25),
                    breakMinutes: max(0, phase == .rest ? phaseTotalSeconds / 60 : 10),
                    rounds: max(1, markerCount),
                    taskForgeFile: nil,
                    taskForgeLine: nil,
                    taskForgeList: nil,
                    taskNotesPath: nil,
                    sessionId: UUID().uuidString
                )
            }
        } else if let previousConfig {
            config = FocusConfig(
                taskName: lastKnownTaskName.isEmpty ? previousConfig.taskName : lastKnownTaskName,
                focusMinutes: previousConfig.focusMinutes,
                breakMinutes: previousConfig.breakMinutes,
                rounds: max(previousConfig.rounds, markerCount),
                taskForgeFile: previousConfig.taskForgeFile,
                taskForgeLine: previousConfig.taskForgeLine,
                taskForgeList: previousConfig.taskForgeList,
                taskNotesPath: previousConfig.taskNotesPath,
                sessionId: previousConfig.sessionId
            )
        }

        updateRoundAfterRefresh(previousPhase: previousPhase, previousRound: previousRound)
        if previousPhase == .focus, phase != .focus {
            logCompletedFocusRound(previousRound)
        }
        startLocalCountdown()
        updateStatusTitle()
        persistSessionSnapshot()
        log("refresh: applied state phase=\(phase.rawValue) task=\(lastKnownTaskName) remaining=\(timeLine) markers=\(markerCount) round=\(round)/\(config?.rounds ?? 1)")
    }

    private func applyFlowState(title: String, phaseText: String, timeText: String) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPhase = phaseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTime = timeText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let seconds = secondsFromTimerString(normalizedTime) else {
            log("refresh: Flow returned unrecognized time '\(normalizedTime)'")
            return
        }

        let previousPhase = phase
        let previousRound = round
        phase = phaseFromFlowPhase(normalizedPhase)
        remainingSeconds = seconds
        lastKnownTaskName = normalizedTitle

        if config == nil {
            if let snapshot = loadSessionSnapshot(), snapshot.taskName == normalizedTitle {
                config = FocusConfig(
                    taskName: snapshot.taskName,
                    focusMinutes: snapshot.focusMinutes,
                    breakMinutes: snapshot.breakMinutes,
                    rounds: snapshot.rounds,
                    taskForgeFile: snapshot.taskForgeFile,
                    taskForgeLine: snapshot.taskForgeLine,
                    taskForgeList: snapshot.taskForgeList,
                    taskNotesPath: snapshot.taskNotesPath,
                    sessionId: snapshot.sessionId ?? UUID().uuidString
                )
                round = min(max(snapshot.round, 1), snapshot.rounds)
            } else {
                config = FocusConfig(
                    taskName: normalizedTitle,
                    focusMinutes: max(1, phase == .focus ? seconds / 60 : 25),
                    breakMinutes: max(0, phase == .rest ? seconds / 60 : 10),
                    rounds: max(round, 1),
                    taskForgeFile: nil,
                    taskForgeLine: nil,
                    taskForgeList: nil,
                    taskNotesPath: nil,
                    sessionId: UUID().uuidString
                )
            }
        }

        let expectedTotal = phase == .rest ? (config?.breakMinutes ?? 10) * 60 : (config?.focusMinutes ?? 25) * 60
        phaseTotalSeconds = max(expectedTotal, seconds)
        updateRoundAfterRefresh(previousPhase: previousPhase, previousRound: previousRound)
        if previousPhase == .focus, phase != .focus {
            logCompletedFocusRound(previousRound)
        }
        startLocalCountdown()
        updateStatusTitle()
        persistSessionSnapshot()
        log("refresh: applied Flow state phase=\(phase.rawValue) task=\(lastKnownTaskName) remaining=\(normalizedTime) round=\(round)/\(config?.rounds ?? 1)")
    }

    private func phaseFromFlowPhase(_ string: String) -> TimerPhase {
        let normalized = string.lowercased()
        if normalized.contains("break") || normalized.contains("pause") {
            return .rest
        }
        return .focus
    }

    private func updateRoundAfterRefresh(previousPhase: TimerPhase, previousRound: Int) {
        guard let config else { return }
        if phase == .focus, previousPhase == .rest {
            round = min(previousRound + 1, config.rounds)
        } else {
            round = min(max(previousRound, 1), config.rounds)
        }
    }

    private func persistSessionSnapshot() {
        guard let config else { return }
        let snapshot = SessionSnapshot(
            taskName: lastKnownTaskName.isEmpty ? config.taskName : lastKnownTaskName,
            focusMinutes: config.focusMinutes,
            breakMinutes: config.breakMinutes,
            rounds: config.rounds,
            taskForgeFile: config.taskForgeFile,
            taskForgeLine: config.taskForgeLine,
            taskForgeList: config.taskForgeList,
            taskNotesPath: config.taskNotesPath,
            sessionId: config.sessionId,
            loggedFocusRounds: Array(loggedFocusRounds).sorted(),
            round: round,
            phase: phase.rawValue,
            savedAt: Date()
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: "sessionSnapshot")
        }
    }

    private func restoreSessionSnapshot() {
        guard let snapshot = loadSessionSnapshot() else { return }
        config = FocusConfig(
            taskName: snapshot.taskName,
            focusMinutes: snapshot.focusMinutes,
            breakMinutes: snapshot.breakMinutes,
            rounds: snapshot.rounds,
            taskForgeFile: snapshot.taskForgeFile,
            taskForgeLine: snapshot.taskForgeLine,
            taskForgeList: snapshot.taskForgeList,
            taskNotesPath: snapshot.taskNotesPath,
            sessionId: snapshot.sessionId ?? UUID().uuidString
        )
        round = min(max(snapshot.round, 1), snapshot.rounds)
        phase = TimerPhase(rawValue: snapshot.phase) ?? .idle
        lastKnownTaskName = snapshot.taskName
        loggedFocusRounds = Set(snapshot.loggedFocusRounds ?? [])
        log("session-snapshot: restored task=\(snapshot.taskName) round=\(snapshot.round)/\(snapshot.rounds)")
    }

    private func loadSessionSnapshot() -> SessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: "sessionSnapshot") else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    private func clearSessionSnapshot() {
        UserDefaults.standard.removeObject(forKey: "sessionSnapshot")
    }

    private func markSelectedTaskInProgress(_ config: FocusConfig) {
        guard let filePath = config.taskForgeFile,
              let lineNumber = config.taskForgeLine,
              let list = config.taskForgeList else {
            return
        }

        let task = TaskForgeTask(
            title: config.taskName,
            list: list,
            filePath: filePath,
            lineNumber: lineNumber,
            isCompleted: false,
            estimate: nil,
            progress: nil,
            status: nil,
            dueDate: nil,
            dueTime: nil,
            scheduled: nil,
            scheduledAt: nil,
            endDate: nil,
            endAt: nil,
            taskNotesPath: config.taskNotesPath
        )

        do {
            try TaskForgeStore.markInProgress(task)
            log("taskforge: marked in progress file=\(filePath) line=\(lineNumber)")
        } catch {
            log("taskforge: failed to mark in progress: \(error.localizedDescription)")
        }
    }

    private func logCompletedFocusRound(_ completedRound: Int) {
        guard let config else { return }
        guard completedRound > 0, completedRound <= config.rounds else { return }
        guard !loggedFocusRounds.contains(completedRound) else { return }
        loggedFocusRounds.insert(completedRound)

        let entry = PomodoroLogEntry(
            completedAt: ISO8601DateFormatter().string(from: Date()),
            taskTitle: lastKnownTaskName.isEmpty ? config.taskName : lastKnownTaskName,
            taskForgeFile: config.taskForgeFile,
            taskForgeLine: config.taskForgeLine,
            taskForgeList: config.taskForgeList,
            taskNotesPath: config.taskNotesPath,
            plannedMinutes: config.focusMinutes,
            actualMinutes: max(1, config.focusMinutes),
            round: completedRound,
            totalRounds: config.rounds,
            sessionId: config.sessionId,
            source: "endel-focus-menubar"
        )

        do {
            try appendPomodoroLog(entry)
            persistSessionSnapshot()
            log("pomodoro: logged completed focus round \(completedRound)/\(config.rounds)")
        } catch {
            loggedFocusRounds.remove(completedRound)
            log("pomodoro: failed to log completed focus round: \(error.localizedDescription)")
        }
    }

    private func appendPomodoroLog(_ entry: PomodoroLogEntry) throws {
        let url = TaskForgeStore.pomodoroLogURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(entry)
        data.append(0x0A)

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private func isTimerString(_ string: String) -> Bool {
        string.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil
    }

    private func isPhaseLine(_ string: String) -> Bool {
        let normalized = string.lowercased()
        return normalized == "focus time"
            || normalized == "focus"
            || normalized == "break time"
            || normalized == "short break"
            || normalized == "long break"
    }

    private func phaseFromLine(_ string: String) -> TimerPhase {
        string.lowercased().contains("break") ? .rest : .focus
    }

    private func sessionMarkerCount(in lines: [String]) -> Int {
        if let markerLine = lines.first(where: { $0.hasPrefix("SESSION_MARKERS:") }),
           let count = Int(markerLine.replacingOccurrences(of: "SESSION_MARKERS:", with: "")) {
            return count
        }

        return lines.filter { line in
            let normalized = line
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "＋", with: "+")
            return normalized == "+"
        }.count
    }

    private func secondsFromTimerString(_ string: String) -> Int? {
        let parts = string.split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]) else {
            return nil
        }
        return minutes * 60 + seconds
    }

    private func collectAccessibilityText(pid: pid_t) -> [String] {
        let appElement = AXUIElementCreateApplication(pid)
        var output: [String] = []
        var visited = 0
        collectAccessibilityText(from: appElement, into: &output, visited: &visited, depth: 0)
        return Array(NSOrderedSet(array: output).array as? [String] ?? output)
    }

    private func collectAccessibilityText(from element: AXUIElement, into output: inout [String], visited: inout Int, depth: Int) {
        guard visited < 500, depth < 12 else { return }
        visited += 1

        for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            if let value = copyAXAttribute(element, attribute) {
                appendAccessibilityValue(value, into: &output)
            }
        }

        if let children = copyAXAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                collectAccessibilityText(from: child, into: &output, visited: &visited, depth: depth + 1)
            }
        }
    }

    private func pressAXButton(title: String, pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var visited = 0
        guard let button = findAXButton(title: title, in: appElement, visited: &visited, depth: 0) else {
            return false
        }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private func findAXButton(title: String, in element: AXUIElement, visited: inout Int, depth: Int) -> AXUIElement? {
        guard visited < 500, depth < 12 else { return nil }
        visited += 1

        let role = copyAXAttribute(element, kAXRoleAttribute) as? String
        let elementTitle = copyAXAttribute(element, kAXTitleAttribute) as? String
        if role == kAXButtonRole as String, elementTitle == title {
            return element
        }

        if let children = copyAXAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                if let match = findAXButton(title: title, in: child, visited: &visited, depth: depth + 1) {
                    return match
                }
            }
        }

        return nil
    }

    private func copyAXAttribute(_ element: AXUIElement, _ attribute: String) -> Any? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    private func appendAccessibilityValue(_ value: Any, into output: inout [String]) {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                output.append(trimmed)
            }
        } else if let number = value as? NSNumber {
            output.append(number.stringValue)
        }
    }

    private func collectOCRText(pid: pid_t, completion: @escaping ([String], Int) -> Void) {
        guard let image = endelWindowImage(pid: pid) else {
            log("refresh: no Endel window image available for OCR")
            completion([], 0)
            return
        }

        let visualMarkerCount = countCircularSessionMarkers(in: image)
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    DispatchQueue.main.async {
                        self.log("refresh: OCR failed: \(error.localizedDescription)")
                        completion([], visualMarkerCount)
                    }
                    return
                }

                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty } ?? []

                DispatchQueue.main.async {
                    completion(lines, visualMarkerCount)
                }
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: image)
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    self.log("refresh: OCR perform failed: \(error.localizedDescription)")
                    completion([], visualMarkerCount)
                }
            }
        }
    }

    private func countCircularSessionMarkers(in image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return 0 }

        let crop = CGRect(
            x: CGFloat(width) * 0.34,
            y: CGFloat(height) * 0.34,
            width: CGFloat(width) * 0.32,
            height: CGFloat(height) * 0.30
        ).integral

        guard
            let cropped = image.cropping(to: crop),
            let provider = cropped.dataProvider,
            let data = provider.data,
            let bytes = CFDataGetBytePtr(data)
        else {
            return 0
        }

        let bytesPerPixel = max(cropped.bitsPerPixel / 8, 4)
        let bytesPerRow = cropped.bytesPerRow
        let cropWidth = cropped.width
        let cropHeight = cropped.height
        var mask = Array(repeating: false, count: cropWidth * cropHeight)

        for y in 0..<cropHeight {
            for x in 0..<cropWidth {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = Int(bytes[offset])
                let g = Int(bytes[offset + min(1, bytesPerPixel - 1)])
                let b = Int(bytes[offset + min(2, bytesPerPixel - 1)])
                let brightness = (r + g + b) / 3
                if brightness > 82 {
                    mask[y * cropWidth + x] = true
                }
            }
        }

        var visited = Array(repeating: false, count: mask.count)
        var components: [(x: Int, y: Int, width: Int, height: Int, area: Int)] = []

        for y in 0..<cropHeight {
            for x in 0..<cropWidth {
                let index = y * cropWidth + x
                guard mask[index], !visited[index] else { continue }

                var stack = [(x, y)]
                visited[index] = true
                var minX = x
                var maxX = x
                var minY = y
                var maxY = y
                var area = 0

                while let point = stack.popLast() {
                    area += 1
                    minX = min(minX, point.0)
                    maxX = max(maxX, point.0)
                    minY = min(minY, point.1)
                    maxY = max(maxY, point.1)

                    for neighbor in [(point.0 + 1, point.1), (point.0 - 1, point.1), (point.0, point.1 + 1), (point.0, point.1 - 1)] {
                        guard neighbor.0 >= 0, neighbor.0 < cropWidth, neighbor.1 >= 0, neighbor.1 < cropHeight else { continue }
                        let neighborIndex = neighbor.1 * cropWidth + neighbor.0
                        if mask[neighborIndex], !visited[neighborIndex] {
                            visited[neighborIndex] = true
                            stack.append(neighbor)
                        }
                    }
                }

                components.append((minX, minY, maxX - minX + 1, maxY - minY + 1, area))
            }
        }

        let candidates = components.filter { component in
            let size = max(component.width, component.height)
            let aspect = Double(component.width) / Double(max(component.height, 1))
            return size >= 12
                && size <= 48
                && component.area >= 18
                && component.area <= 700
                && aspect >= 0.55
                && aspect <= 1.8
        }

        return min(candidates.count, 12)
    }

    private func endelWindowImage(pid: pid_t) -> CGImage? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard
                (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                let windowNumber = window[kCGWindowNumber as String] as? CGWindowID,
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let width = bounds["Width"], width > 100,
                let height = bounds["Height"], height > 100
            else {
                continue
            }

            return screenshotWindow(windowNumber: windowNumber)
        }

        return nil
    }

    private func screenshotWindow(windowNumber: CGWindowID) -> CGImage? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EndelFocusMenuBar-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", "\(windowNumber)", url.path]

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                log("refresh: screencapture exited with \(process.terminationStatus)")
                return nil
            }
            defer { try? FileManager.default.removeItem(at: url) }
            guard
                let image = NSImage(contentsOf: url),
                let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                return nil
            }
            return cgImage
        } catch {
            log("refresh: screencapture failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func log(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/EndelFocusMenuBar.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(timestamp)] \(message)\n"
        if let data = text.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func progressFraction() -> CGFloat {
        guard phaseTotalSeconds > 0 else { return 0 }
        return CGFloat(max(remainingSeconds, 0)) / CGFloat(phaseTotalSeconds)
    }

    private func statusImage(label: String, progress: CGFloat) -> NSImage {
        let width = statusItemLength()
        let size = NSSize(width: width, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()

        var textX: CGFloat = 2
        if showRing {
            let ringRect = NSRect(x: 2, y: 2, width: 18, height: 18)
            NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke()
            let base = NSBezierPath(ovalIn: ringRect)
            base.lineWidth = 2
            base.stroke()

            if progress > 0 {
                ringColor().setStroke()
                let path = NSBezierPath()
                path.appendArc(
                    withCenter: NSPoint(x: ringRect.midX, y: ringRect.midY),
                    radius: 8,
                    startAngle: 90,
                    endAngle: 90 - (360 * progress),
                    clockwise: true
                )
                path.lineWidth = 2.5
                path.stroke()
            }
            drawEndelGlyph(in: ringRect.insetBy(dx: 4.5, dy: 4.5))
            textX = 26
        }

        let text = statusText(label: label)
        if !text.isEmpty {
            text.draw(in: NSRect(x: textX, y: 3, width: width - textX - 2, height: 18), withAttributes: statusTextAttributes())
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func statusText(label: String) -> String {
        var parts: [String] = []
        if showTaskName {
            let task = lastKnownTaskName.isEmpty ? "Endel" : lastKnownTaskName
            parts.append(task)
        }
        if showTime {
            parts.append(phase == .idle ? "--:--" : label)
        }
        return parts.joined(separator: " ")
    }

    private func statusTextAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
    }

    private func ringColor() -> NSColor {
        switch phase {
        case .focus:
            return NSColor.systemGreen
        case .rest:
            return NSColor.systemOrange
        case .done:
            return NSColor.systemBlue
        case .idle:
            return NSColor.controlAccentColor
        }
    }

    private func drawEndelGlyph(in rect: NSRect) {
        let strokeColor = NSColor.labelColor.withAlphaComponent(0.82)
        strokeColor.setStroke()

        let face = NSBezierPath(ovalIn: rect)
        face.lineWidth = 0.8
        face.stroke()

        let leftEye = NSRect(
            x: rect.minX + rect.width * 0.28,
            y: rect.minY + rect.height * 0.52,
            width: 1.2,
            height: 1.2
        )
        let rightEye = NSRect(
            x: rect.minX + rect.width * 0.62,
            y: rect.minY + rect.height * 0.52,
            width: 1.2,
            height: 1.2
        )
        strokeColor.setFill()
        NSBezierPath(ovalIn: leftEye).fill()
        NSBezierPath(ovalIn: rightEye).fill()

        let mouth = NSBezierPath()
        mouth.move(to: NSPoint(x: rect.minX + rect.width * 0.32, y: rect.minY + rect.height * 0.34))
        mouth.curve(
            to: NSPoint(x: rect.minX + rect.width * 0.68, y: rect.minY + rect.height * 0.34),
            controlPoint1: NSPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.22),
            controlPoint2: NSPoint(x: rect.minX + rect.width * 0.58, y: rect.minY + rect.height * 0.22)
        )
        mouth.lineWidth = 0.7
        mouth.stroke()
    }

    private func startFlow(_ config: FocusConfig) {
        guard runFlowCommand("setTitle to \"\(appleScriptEscaped(config.taskName))\"") != nil else {
            showError(message: "Could not set Flow session title.")
            return
        }

        guard runFlowCommand("start") != nil else {
            showError(message: "Could not start or resume Flow session.")
            return
        }

        log("flow: started session title=\(config.taskName)")
    }

    private func runFlowCommand(_ command: String) -> String? {
        let script = """
        tell application "Flow"
          \(command)
        end tell
        """

        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error) else {
            if let error {
                log("flow: AppleScript error \(error)")
            }
            return nil
        }
        return result.stringValue ?? ""
    }

    @discardableResult
    private func requestAccessibilityPermissionIfNeeded(showPane: Bool) -> Bool {
        if AXIsProcessTrusted() {
            log("accessibility: trusted")
            return true
        }

        log("accessibility: not trusted; requesting prompt")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startPermissionPoll()

        if showPane {
            accessibilityController = AccessibilityPermissionController()
            accessibilityController?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        return false
    }

    private func startPermissionPoll() {
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.log("accessibility: trusted after prompt; refreshing Flow state")
                timer.invalidate()
                self.permissionPollTimer = nil
                self.accessibilityController?.close()
                self.refreshStateFromFlow()
            }
        }
    }

    private func appleScriptEscaped(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func showError(_ error: NSDictionary?) {
        showError(message: error?.description ?? "Grant Automation permission to the helper in System Settings, then try again.")
    }

    private func showError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not automate Flow"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
