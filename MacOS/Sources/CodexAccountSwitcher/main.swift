import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct CodexProfile: Identifiable, Hashable {
    let name: String
    let profileURL: URL
    let authURL: URL
    let browserSessionURL: URL
    let modifiedAt: Date?
    let isActive: Bool
    let hasAuth: Bool
    let hasBrowserSession: Bool
    let limits: CodexLimitSnapshot?
    let error: ProfileErrorSnapshot?
    let email: String?

    var id: String { name }
}

struct CodexLimitSnapshot: Codable, Hashable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Date?
    let secondaryUsedPercent: Double?
    let secondaryWindowMinutes: Int?
    let secondaryResetsAt: Date?
    let planType: String?
    let sourceTimestamp: Date?
    let capturedAt: Date

    var remainingPercent: Double? {
        guard let usedPercent else { return nil }
        return max(0, 100 - usedPercent)
    }

    var secondaryRemainingPercent: Double? {
        guard let secondaryUsedPercent else { return nil }
        return max(0, 100 - secondaryUsedPercent)
    }

    func remainingPercent(at date: Date, secondary: Bool = false) -> Double? {
        if let reset = secondary ? secondaryResetsAt : resetsAt, date >= reset {
            return 100
        }
        return secondary ? secondaryRemainingPercent : remainingPercent
    }

    func nextResetAfter(_ date: Date) -> Date? {
        [resetsAt, secondaryResetsAt]
            .compactMap { $0 }
            .filter { $0 > date }
            .min()
    }
}

struct ProfileErrorSnapshot: Codable, Hashable {
    let code: String
    let message: String
    let capturedAt: Date
}

final class AccountStore: ObservableObject {
    @Published var profiles: [CodexProfile] = []
    @Published var selectedProfileID: String?
    @Published var activeProfileName: String = "не выбран"
    @Published var pendingProfileName: String?
    @Published var message: String = "Ожидание действий"
    @Published var messageShowsProgress: Bool = false
    @Published var errorMessage: String?

    private let fileManager = FileManager.default
    private let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    private let codexAppName = "Codex"
    private var lastLimitScanKey: String?
    private var statusResetWorkItem: DispatchWorkItem?

    private var codexDir: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return homeURL.appendingPathComponent(".codex", isDirectory: true)
    }

    private var authURL: URL { codexDir.appendingPathComponent("auth.json") }
    private var codexAppSupportDir: URL {
        homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Codex", isDirectory: true)
    }
    private var switcherDir: URL { homeURL.appendingPathComponent(".codex-account-switcher", isDirectory: true) }
    private var profilesDir: URL { switcherDir.appendingPathComponent("profiles", isDirectory: true) }
    private var backupsDir: URL { switcherDir.appendingPathComponent("backups", isDirectory: true) }
    private var currentProfileURL: URL { switcherDir.appendingPathComponent("current_profile") }
    private var pendingProfileURL: URL { switcherDir.appendingPathComponent("pending_profile") }
    private var pendingPreviousProfileURL: URL { switcherDir.appendingPathComponent("pending_previous_profile") }
    private var pendingPreviousFingerprintURL: URL { switcherDir.appendingPathComponent("pending_previous_fingerprint") }
    private var logURL: URL { switcherDir.appendingPathComponent("switcher.log") }
    private var sessionsDir: URL { codexDir.appendingPathComponent("sessions", isDirectory: true) }
    var profilesStoragePath: String { profilesDir.path }
    private let managedBrowserSessionItems = [
        "Cookies",
        "Cookies-journal",
        "Local Storage",
        "Session Storage",
        "Partitions",
        "Network Persistent State",
        "Preferences",
        "SharedStorage",
        "SharedStorage-wal",
        "Trust Tokens",
        "Trust Tokens-journal",
        "TransportSecurity",
        "DIPS",
        "DIPS-wal",
        "blob_storage"
    ]

    init() {
        ensureDirectories()
        refresh()
    }

    func refresh() {
        ensureDirectories()
        activeProfileName = readActiveProfile() ?? "не выбран"
        pendingProfileName = readPendingProfile()

        let urls = (try? fileManager.contentsOfDirectory(
            at: profilesDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        profiles = urls
            .filter { $0.hasDirectoryPath }
            .compactMap { profileURL in
                let auth = authSnapshotURL(in: profileURL)
                let browserSession = browserSessionSnapshotURL(in: profileURL)
                let hasAuth = auth != nil
                let hasBrowserSession = browserSession != nil
                guard hasAuth || hasBrowserSession else { return nil }
                let fallbackAuth = profileURL.appendingPathComponent("auth.json")
                let fallbackBrowserSession = profileURL
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent("Codex", isDirectory: true)
                let modifiedSource = browserSession ?? auth ?? profileURL
                let values = try? modifiedSource.resourceValues(forKeys: [.contentModificationDateKey])
                let name = profileURL.lastPathComponent
                let limits = loadLimitSnapshot(from: profileURL)
                let error = loadProfileError(from: profileURL)
                let email = auth.flatMap { profileEmail(from: $0) }
                return CodexProfile(
                    name: name,
                    profileURL: profileURL,
                    authURL: auth ?? fallbackAuth,
                    browserSessionURL: browserSession ?? fallbackBrowserSession,
                    modifiedAt: values?.contentModificationDate,
                    isActive: name == activeProfileName,
                    hasAuth: hasAuth,
                    hasBrowserSession: hasBrowserSession,
                    limits: limits,
                    error: error,
                    email: email
                )
            }

            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = profiles.first(where: { $0.isActive })?.id ?? profiles.first?.id
        }
    }

    func refreshAndUpdateActiveLimits() {
        if let active = readActiveProfile(), !active.isEmpty {
            let profileDir = profilesDir.appendingPathComponent(active, isDirectory: true)
            if fileManager.fileExists(atPath: profileDir.path) {
                let minimumDate = activeProfileChangedAt()
                let scanKey = latestSessionScanKey(since: minimumDate)
                guard scanKey != lastLimitScanKey else {
                    refresh()
                    return
                }
                lastLimitScanKey = scanKey
                if saveCurrentLimitSnapshotIfAvailable(to: profileDir, since: minimumDate) {
                    clearProfileError(in: profileDir)
                } else {
                    updateActiveProfileErrorIfNeeded(profileDir: profileDir)
                }
            }
        }
        refresh()
    }

    func suggestedProfileName() -> String {
        let occupiedNumbers = occupiedSuggestedProfileNumbers()
        var index = 1
        var candidate = "Account \(index)"
        while occupiedNumbers.contains(index) || profileNameExists(candidate) {
            index += 1
            candidate = "Account \(index)"
        }
        return candidate
    }

    func saveCurrentSession(named rawName: String) {
        do {
            let name = try sanitizedProfileName(rawName)
            guard fileManager.fileExists(atPath: authURL.path) || fileManager.fileExists(atPath: codexAppSupportDir.path) else {
                throw SwitcherError.userFacing("Не найдены данные входа Codex. Сначала войдите в Codex вручную.")
            }
            if let duplicateKey = currentSessionDuplicateKey(),
               let duplicate = findProfileMatchingDuplicateKey(duplicateKey, excluding: name) {
                skipDuplicateSave(existingName: duplicate)
                return
            }

            ensureDirectories()
            quitCodex()
            let profileDir = profilesDir.appendingPathComponent(name, isDirectory: true)
            let pending = readPendingProfile()
            let active = readActiveProfile()
            if fileManager.fileExists(atPath: profileDir.path), pending != name, active != name {
                throw SwitcherError.userFacing("Профиль \(name) уже существует. Выберите другое название.")
            }
            try fileManager.createDirectory(at: profileDir, withIntermediateDirectories: true)
            try saveAuthSnapshot(to: profileDir)
            try saveBrowserSessionSnapshot(to: profileDir)
            saveCurrentLimitSnapshotIfAvailable(to: profileDir)
            try writeActiveProfile(name)
            if readPendingProfile() == name {
                try? fileManager.removeItem(at: pendingProfileURL)
                try? fileManager.removeItem(at: pendingPreviousProfileURL)
                try? fileManager.removeItem(at: pendingPreviousFingerprintURL)
            }
            openCodex()
            log("Saved current session as '\(name)'")
            setStatus("Сессия сохранена: \(name)")
            refresh()
        } catch {
            show(error)
        }
    }

    func beginLoginForNewProfile(named rawName: String) {
        do {
            let name = try sanitizedProfileName(rawName)
            guard !profileNameExists(name) else {
                throw SwitcherError.userFacing("Профиль \(name) уже существует. Выберите другое название.")
            }
            ensureDirectories()
            let previousProfile = readActiveProfile()
            quitCodex()
            refreshActiveProfileSessionIfPossible()
            let previousFingerprint = currentSessionFingerprint()
            backupCurrentSessionIfPresent()
            try clearCurrentCodexSession()
            try writePendingProfile(name)
            try writePendingPreviousProfile(previousProfile)
            try writePendingPreviousFingerprint(previousFingerprint)
            try? fileManager.removeItem(at: currentProfileURL)
            openCodex()
            log("Started login flow for '\(name)'")
            setStatus("Ожидание логина: \(name)", autoClear: false)
            refresh()
        } catch {
            show(error)
        }
    }

    func savePendingProfileAfterLogin() {
        guard let pendingProfileName else {
            show(SwitcherError.userFacing("Нет аккаунта в режиме входа."))
            return
        }
        guard sessionChangedSincePendingLogin() else {
            cancelPendingLogin(message: "Вход отменён: новый аккаунт не создан")
            return
        }
        if let duplicateKey = currentSessionDuplicateKey(),
           let duplicate = findProfileMatchingDuplicateKey(duplicateKey, excluding: pendingProfileName) {
            finishPendingAsDuplicate(existingName: duplicate)
            return
        }
        saveCurrentSession(named: pendingProfileName)
    }

    func pollPendingLogin() {
        guard let pending = readPendingProfile() else {
            if pendingProfileName != nil {
                refresh()
            }
            return
        }
        pendingProfileName = pending
        if hasUsableAuthFile() {
            if sessionChangedSincePendingLogin() {
                savePendingProfileAfterLogin()
                if errorMessage == nil {
                    setStatus("Аккаунт сохранён: \(pending)")
                }
            } else {
                cancelPendingLogin(message: "Вход отменён: новый аккаунт не создан")
            }
        } else if !isCodexRunning() && pendingLoginAge() > 8 {
            cancelPendingLogin()
        } else {
            setStatus("Ожидание логина: \(pending)", autoClear: false)
        }
    }

    func cancelPendingLogin(message customMessage: String? = nil) {
        guard let pending = readPendingProfile() else { return }
        let previous = readPendingPreviousProfile()
        try? fileManager.removeItem(at: pendingProfileURL)
        try? fileManager.removeItem(at: pendingPreviousProfileURL)
        try? fileManager.removeItem(at: pendingPreviousFingerprintURL)
        pendingProfileName = nil
        log("Cancelled login flow for '\(pending)'")

        if let previous,
           let profile = profiles.first(where: { $0.name.caseInsensitiveCompare(previous) == .orderedSame }) {
            switchTo(profile)
            setStatus(customMessage ?? "Вход отменён, вернул \(profile.name)")
        } else {
            setStatus(customMessage ?? "Вход отменён")
            refresh()
        }
    }

    func importDroppedProviders(_ providers: [NSItemProvider]) {
        let type = UTType.fileURL.identifier
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(type) {
            group.enter()
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                } else if let text = item as? String {
                    url = URL(string: text)
                } else {
                    url = nil
                }
                guard let url else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            self.importProfileItems(urls)
        }
    }

    func switchToSelectedProfile() {
        guard let selectedProfileID,
              let profile = profiles.first(where: { $0.id == selectedProfileID }) else {
            show(SwitcherError.userFacing("Выберите профиль для переключения."))
            return
        }
        setStatus("Идёт переключение на \(profile.name)", autoClear: false, showsProgress: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.beginInteractiveSwitch(to: profile)
        }
    }

    private func beginInteractiveSwitch(to profile: CodexProfile) {
        guard profile.hasAuth || profile.hasBrowserSession else {
            show(SwitcherError.userFacing("В профиле \(profile.name) нет сохранённой сессии."))
            return
        }
        ensureDirectories()
        quitCodex()
        refreshActiveProfileSessionIfPossible()
        refresh()
        setStatus("Идёт переключение на \(profile.name)", autoClear: false, showsProgress: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.switchTo(profile, statusAlreadyStarted: true, outgoingAlreadyRefreshed: true)
        }
    }

    func switchTo(_ profile: CodexProfile, statusAlreadyStarted: Bool = false, outgoingAlreadyRefreshed: Bool = false) {
        do {
            guard profile.hasAuth || profile.hasBrowserSession else {
                throw SwitcherError.userFacing("В профиле \(profile.name) нет сохранённой сессии.")
            }

            ensureDirectories()
            if !statusAlreadyStarted {
                setStatus("Идёт переключение на \(profile.name)", autoClear: false, showsProgress: true)
            }
            if !outgoingAlreadyRefreshed {
                quitCodex()
                refreshActiveProfileSessionIfPossible()
                refresh()
            }
            backupCurrentSessionIfPresent()
            try restoreAuthSnapshot(from: profile)
            try restoreBrowserSessionSnapshot(from: profile)
            try writeActiveProfile(profile.name)
            clearProfileError(in: profile.profileURL)
            refresh()
            openCodex()
            log("Switched to '\(profile.name)'")
            setStatus("Успешно переключено на \(profile.name)")
            schedulePostSwitchLimitRefresh(for: profile.name)
            refresh()
        } catch {
            markProfileError(in: profile.profileURL, code: switchErrorCode(error), message: error.localizedDescription)
            show(error)
            refresh()
        }
    }

    private func schedulePostSwitchLimitRefresh(for profileName: String) {
        for delay in [1.0, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.readActiveProfile() == profileName else { return }
                self.refreshAndUpdateActiveLimits()
            }
        }
    }

    func deleteSelectedProfile() {
        guard let profileID = selectedProfileID else { return }
        do {
            let target = profilesDir.appendingPathComponent(profileID, isDirectory: true)
            guard fileManager.fileExists(atPath: target.path) else { return }
            try fileManager.removeItem(at: target)
            if readActiveProfile() == profileID {
                try? fileManager.removeItem(at: currentProfileURL)
            }
            log("Deleted profile '\(profileID)'")
            selectedProfileID = nil
            setStatus("Профиль удалён: \(profileID)")
            refresh()
        } catch {
            show(error)
        }
    }

    func renameSelectedProfile(to rawName: String) {
        guard let profileID = selectedProfileID else { return }
        do {
            let newName = try sanitizedProfileName(rawName)
            guard newName != profileID else { return }
            let source = profilesDir.appendingPathComponent(profileID, isDirectory: true)
            let target = profilesDir.appendingPathComponent(newName, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else { return }
            guard !fileManager.fileExists(atPath: target.path) else {
                throw SwitcherError.userFacing("Профиль \(newName) уже существует.")
            }
            try fileManager.moveItem(at: source, to: target)
            if readActiveProfile() == profileID {
                try writeActiveProfile(newName)
            }
            if readPendingProfile() == profileID {
                try writePendingProfile(newName)
            }
            selectedProfileID = newName
            setStatus("Профиль переименован: \(newName)")
            log("Renamed profile '\(profileID)' to '\(newName)'")
            refresh()
        } catch {
            show(error)
        }
    }

    func revealProfilesFolder() {
        ensureDirectories()
        NSWorkspace.shared.activateFileViewerSelecting([profilesDir])
    }

    private func importProfileItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var imported: [String] = []
        var skippedDuplicates = 0
        do {
            ensureDirectories()
            for source in urls {
                let result = try importProfileItem(from: source)
                switch result {
                case .imported(let name):
                    imported.append(name)
                case .duplicate:
                    skippedDuplicates += 1
                }
            }
            refresh()
            if !imported.isEmpty, skippedDuplicates > 0 {
                setStatus("Импортировано: \(imported.joined(separator: ", ")); дубли пропущены")
            } else if !imported.isEmpty {
                setStatus("Импортировано: \(imported.joined(separator: ", "))")
            } else if skippedDuplicates > 0 {
                setStatus("Дубль не сохранён")
            }
        } catch {
            show(error)
            refresh()
        }
    }

    private enum ImportResult {
        case imported(String)
        case duplicate(String)
    }

    private func importProfileItem(from source: URL) throws -> ImportResult {
        let standardizedSource = source.standardizedFileURL
        guard fileManager.fileExists(atPath: standardizedSource.path) else {
            throw SwitcherError.userFacing("Файл или папка не найдены.")
        }
        guard let duplicateKey = candidateDuplicateKey(at: standardizedSource) else {
            throw SwitcherError.userFacing("Перетащите папку профиля, папку Codex или файл auth.json/сессии.")
        }
        if let existing = findProfileMatchingDuplicateKey(duplicateKey, excluding: nil) {
            return .duplicate(existing)
        }

        let baseName = validBaseProfileName(from: standardizedSource)
        let name = uniqueProfileName(basedOn: baseName)
        let target = profilesDir.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try copySessionCandidate(from: standardizedSource, to: target)
        try setSecurePermissions(for: target, mode: 0o700)
        log("Imported profile '\(name)' from '\(standardizedSource.path)'")
        return .imported(name)
    }

    private func refreshActiveProfileSessionIfPossible() {
        guard let active = readActiveProfile(),
              !active.isEmpty else { return }
        let profileDir = profilesDir.appendingPathComponent(active, isDirectory: true)
        guard fileManager.fileExists(atPath: profileDir.path) else { return }
        do {
            try saveAuthSnapshot(to: profileDir)
            try saveBrowserSessionSnapshot(to: profileDir)
            saveCurrentLimitSnapshotIfAvailable(to: profileDir, since: activeProfileChangedAt())
            log("Refreshed active profile '\(active)'")
        } catch {
            log("Could not refresh active profile '\(active)': \(error.localizedDescription)")
        }
    }

    private func backupCurrentSessionIfPresent() {
        guard fileManager.fileExists(atPath: authURL.path) || fileManager.fileExists(atPath: codexAppSupportDir.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = backupsDir.appendingPathComponent("session.\(formatter.string(from: Date()))", isDirectory: true)
        do {
            try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
            try saveAuthSnapshot(to: backup)
            try saveBrowserSessionSnapshot(to: backup)
        } catch {
            log("Could not create backup: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func saveCurrentLimitSnapshotIfAvailable(to profileDir: URL, since minimumDate: Date? = nil) -> Bool {
        guard let snapshot = latestLimitSnapshot(since: minimumDate) else { return false }
        let target = profileDir.appendingPathComponent("limits.json")
        do {
            let data = try JSONEncoder.codexDateEncoder.encode(snapshot)
            try data.write(to: target, options: [.atomic])
            try setSecurePermissions(for: target, mode: 0o600)
            return true
        } catch {
            log("Could not save limits snapshot: \(error.localizedDescription)")
            return false
        }
    }

    private func loadLimitSnapshot(from profileDir: URL) -> CodexLimitSnapshot? {
        let source = profileDir.appendingPathComponent("limits.json")
        guard let data = try? Data(contentsOf: source) else { return nil }
        return try? JSONDecoder.codexDateDecoder.decode(CodexLimitSnapshot.self, from: data)
    }

    private func loadProfileError(from profileDir: URL) -> ProfileErrorSnapshot? {
        let source = profileDir.appendingPathComponent("profile-error.json")
        guard let data = try? Data(contentsOf: source) else { return nil }
        return try? JSONDecoder.codexDateDecoder.decode(ProfileErrorSnapshot.self, from: data)
    }

    private func profileEmail(from authURL: URL) -> String? {
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let email = normalizedEmail(in: object) {
            return email
        }
        guard let tokens = object["tokens"] as? [String: Any] else { return nil }
        if let email = normalizedEmail(in: tokens) {
            return email
        }
        for key in ["id_token", "access_token"] {
            guard let token = tokens[key] as? String,
                  let payload = jwtPayload(from: token),
                  let email = normalizedEmail(in: payload) else {
                continue
            }
            return email
        }
        return nil
    }

    private func profileAccountIdentity(from authURL: URL) -> String? {
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let tokens = object["tokens"] as? [String: Any]
        var payloads: [[String: Any]] = [object]
        if let tokens {
            payloads.append(tokens)
            for key in ["id_token", "access_token"] {
                if let token = tokens[key] as? String,
                   let payload = jwtPayload(from: token) {
                    payloads.append(payload)
                }
            }
        }

        for payload in payloads {
            if let accountID = payload["account_id"] as? String, !accountID.isEmpty {
                return "account:\(accountID)"
            }
            if let auth = payload["https://api.openai.com/auth"] as? [String: Any],
               let accountID = auth["chatgpt_account_id"] as? String,
               !accountID.isEmpty {
                return "account:\(accountID)"
            }
        }

        for payload in payloads {
            guard let email = normalizedEmail(in: payload) else { continue }
            let auth = payload["https://api.openai.com/auth"] as? [String: Any]
            let plan = (auth?["chatgpt_plan_type"] as? String) ?? ""
            let organizationID = defaultOrganizationID(in: auth)
            if !plan.isEmpty || organizationID != nil {
                return "email:\(email.lowercased())|plan:\(plan.lowercased())|org:\(organizationID ?? "")"
            }
        }

        return nil
    }

    private func normalizedEmail(in object: [String: Any]) -> String? {
        if let email = object["email"] as? String, isEmailLike(email) {
            return email
        }
        if let profile = object["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String,
           isEmailLike(email) {
            return email
        }
        return nil
    }

    private func jwtPayload(from token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: padding))
        }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func defaultOrganizationID(in auth: [String: Any]?) -> String? {
        guard let organizations = auth?["organizations"] as? [[String: Any]] else { return nil }
        if let defaultOrganization = organizations.first(where: { ($0["is_default"] as? Bool) == true }),
           let id = defaultOrganization["id"] as? String,
           !id.isEmpty {
            return id
        }
        return organizations.compactMap { $0["id"] as? String }.first { !$0.isEmpty }
    }

    private func isEmailLike(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".")
    }

    private func latestSessionScanKey(since minimumDate: Date?) -> String {
        guard let enumerator = fileManager.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "none"
        }

        var newest = Date.distantPast
        var count = 0
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            if let minimumDate, modified < minimumDate {
                continue
            }
            count += 1
            if modified > newest {
                newest = modified
            }
        }
        let minimum = minimumDate?.timeIntervalSince1970 ?? 0
        return "\(count):\(newest.timeIntervalSince1970):\(minimum)"
    }

    private func markProfileError(in profileDir: URL, code: String, message: String) {
        let snapshot = ProfileErrorSnapshot(code: code, message: message, capturedAt: Date())
        let target = profileDir.appendingPathComponent("profile-error.json")
        do {
            let data = try JSONEncoder.codexDateEncoder.encode(snapshot)
            try data.write(to: target, options: [.atomic])
            try setSecurePermissions(for: target, mode: 0o600)
            log("Profile error for '\(profileDir.lastPathComponent)': \(code) \(message)")
        } catch {
            log("Could not save profile error: \(error.localizedDescription)")
        }
    }

    private func clearProfileError(in profileDir: URL) {
        let target = profileDir.appendingPathComponent("profile-error.json")
        if fileManager.fileExists(atPath: target.path) {
            try? fileManager.removeItem(at: target)
        }
    }

    private func updateActiveProfileErrorIfNeeded(profileDir: URL) {
        guard let changedAt = activeProfileChangedAt(),
              let error = latestSwitchError(since: changedAt) else {
            return
        }
        markProfileError(in: profileDir, code: error.code, message: error.message)
    }

    private func latestLimitSnapshot(since minimumDate: Date? = nil) -> CodexLimitSnapshot? {
        guard let enumerator = fileManager.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var candidates: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            candidates.append((url, values?.contentModificationDate ?? .distantPast))
        }

        for candidate in candidates.sorted(by: { $0.modified > $1.modified }).prefix(20) {
            if let minimumDate, candidate.modified < minimumDate {
                continue
            }
            if let snapshot = latestLimitSnapshot(in: candidate.url, since: minimumDate) {
                return snapshot
            }
        }
        return nil
    }

    private func latestLimitSnapshot(in fileURL: URL, since minimumDate: Date? = nil) -> CodexLimitSnapshot? {
        guard let text = tailText(from: fileURL) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let payload = object["payload"] as? [String: Any]
            let sourceTimestamp = eventTimestamp(from: object)
            if let minimumDate, let sourceTimestamp, sourceTimestamp < minimumDate {
                continue
            }
            if line.contains("\"rate_limits\""),
               let rateLimits = object["rate_limits"] as? [String: Any]
                    ?? payload?["rate_limits"] as? [String: Any],
               let snapshot = limitSnapshot(from: rateLimits, sourceTimestamp: sourceTimestamp) {
                return snapshot
            }
            if detectedLimitExhausted(in: String(line).lowercased()) {
                return exhaustedLimitSnapshot(sourceTimestamp: sourceTimestamp)
            }
        }
        return nil
    }

    private func latestSwitchError(since minimumDate: Date) -> ProfileErrorSnapshot? {
        guard let enumerator = fileManager.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var candidates: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            guard modified >= minimumDate else { continue }
            candidates.append((url, modified))
        }

        for candidate in candidates.sorted(by: { $0.modified > $1.modified }).prefix(20) {
            if let error = latestSwitchError(in: candidate.url, since: minimumDate) {
                return error
            }
        }
        return nil
    }

    private func latestSwitchError(in fileURL: URL, since minimumDate: Date) -> ProfileErrorSnapshot? {
        guard let text = tailText(from: fileURL) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let timestamp = eventTimestamp(from: object), timestamp < minimumDate {
                continue
            }
            let lower = String(line).lowercased()
            guard let code = detectedSwitchErrorCode(in: lower) else { continue }
            return ProfileErrorSnapshot(
                code: code,
                message: compactErrorMessage(from: lower),
                capturedAt: eventTimestamp(from: object) ?? Date()
            )
        }
        return nil
    }

    private func tailText(from fileURL: URL, maxBytes: UInt64 = 2 * 1024 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        let offset = size > maxBytes ? size - maxBytes : 0
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func detectedSwitchErrorCode(in text: String) -> String? {
        if text.contains("workspace") && (text.contains("deactiv") || text.contains("disabled") || text.contains("not active")) {
            return "WORKSPACE_DEACTIVATED"
        }
        if text.contains("session") && (text.contains("expired") || text.contains("invalid")) {
            return "SESSION_EXPIRED"
        }
        if text.contains("unauthorized") || text.contains("401") {
            return "AUTH_401"
        }
        if text.contains("forbidden") || text.contains("403") {
            return "AUTH_403"
        }
        if text.contains("invalid_api_key") || text.contains("invalid api key") {
            return "INVALID_AUTH"
        }
        return nil
    }

    private func detectedLimitExhausted(in text: String) -> Bool {
        if text.contains("rate_limit_reached_type") && !text.contains("rate_limit_reached_type\":null") {
            return true
        }
        let markers = [
            "usage limit",
            "rate limit reached",
            "limit reached",
            "лимит исчерпан",
            "лимит законч",
            "закончились лимиты"
        ]
        return markers.contains { text.contains($0) }
    }

    private func exhaustedLimitSnapshot(sourceTimestamp: Date?) -> CodexLimitSnapshot {
        CodexLimitSnapshot(
            usedPercent: 100,
            windowMinutes: nil,
            resetsAt: nil,
            secondaryUsedPercent: nil,
            secondaryWindowMinutes: nil,
            secondaryResetsAt: nil,
            planType: nil,
            sourceTimestamp: sourceTimestamp,
            capturedAt: Date()
        )
    }

    private func compactErrorMessage(from text: String) -> String {
        String(text.prefix(240))
    }

    private func switchErrorCode(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return "FILE_\(nsError.code)"
        }
        return "SWITCH_FAILED"
    }

    private func eventTimestamp(from object: [String: Any]) -> Date? {
        guard let text = object["timestamp"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    private func limitSnapshot(from rateLimits: [String: Any], sourceTimestamp: Date?) -> CodexLimitSnapshot? {
        let reachedType = rateLimits["rate_limit_reached_type"] as? String
        let isReached = reachedType.map { !$0.isEmpty } ?? false

        let primary = rateLimits["primary"] as? [String: Any]
        let rawUsedPercent = primary?["used_percent"] as? Double
            ?? (primary?["used_percent"] as? NSNumber)?.doubleValue
        let usedPercent = isReached ? 100.0 : rawUsedPercent
        let windowMinutes = primary?["window_minutes"] as? Int
            ?? (primary?["window_minutes"] as? NSNumber)?.intValue
        let resetsAtSeconds = primary?["resets_at"] as? Double
            ?? (primary?["resets_at"] as? NSNumber)?.doubleValue
        let resetsAt = resetsAtSeconds.map { Date(timeIntervalSince1970: $0) }

        let secondary = rateLimits["secondary"] as? [String: Any]
        let secondaryUsedPercent = secondary?["used_percent"] as? Double
            ?? (secondary?["used_percent"] as? NSNumber)?.doubleValue
        let secondaryWindowMinutes = secondary?["window_minutes"] as? Int
            ?? (secondary?["window_minutes"] as? NSNumber)?.intValue
        let secondaryResetsAtSeconds = secondary?["resets_at"] as? Double
            ?? (secondary?["resets_at"] as? NSNumber)?.doubleValue
        let secondaryResetsAt = secondaryResetsAtSeconds.map { Date(timeIntervalSince1970: $0) }

        let planType = rateLimits["plan_type"] as? String
        guard usedPercent != nil || secondaryUsedPercent != nil || planType != nil || isReached else {
            return nil
        }
        return CodexLimitSnapshot(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            secondaryUsedPercent: secondaryUsedPercent,
            secondaryWindowMinutes: secondaryWindowMinutes,
            secondaryResetsAt: secondaryResetsAt,
            planType: planType,
            sourceTimestamp: sourceTimestamp,
            capturedAt: Date()
        )
    }

    private func activeProfileChangedAt() -> Date? {
        let values = try? currentProfileURL.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    private func authSnapshotURL(in profileDir: URL) -> URL? {
        let candidates = [
            profileDir.appendingPathComponent("auth.json"),
            profileDir
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("auth.json")
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private func browserSessionSnapshotURL(in profileDir: URL) -> URL? {
        let candidates = [
            profileDir
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Codex", isDirectory: true),
            profileDir
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Codex", isDirectory: true),
            profileDir.appendingPathComponent("Codex", isDirectory: true),
            profileDir
        ]
        return candidates.first { hasBrowserSessionItems(at: $0) }
    }

    private func hasBrowserSessionItems(at url: URL) -> Bool {
        let strongSignals = [
            "Cookies",
            "Local Storage",
            "Session Storage"
        ]
        if strongSignals.contains(where: { item in
            fileManager.fileExists(atPath: url.appendingPathComponent(item).path)
        }) {
            return true
        }

        let weakSignals = [
            "Network Persistent State",
            "Partitions",
            "blob_storage"
        ]
        let weakSignalCount = weakSignals.filter { item in
            fileManager.fileExists(atPath: url.appendingPathComponent(item).path)
        }.count
        return weakSignalCount >= 2
    }

    private func saveAuthSnapshot(to profileDir: URL) throws {
        let target = profileDir.appendingPathComponent("auth.json")
        if fileManager.fileExists(atPath: authURL.path) {
            try replaceFile(from: authURL, to: target)
            try setSecurePermissions(for: target, mode: 0o600)
        } else if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
    }

    private func restoreAuthSnapshot(from profile: CodexProfile) throws {
        if profile.hasAuth {
            try fileManager.createDirectory(at: codexDir, withIntermediateDirectories: true)
            try replaceFile(from: profile.authURL, to: authURL)
            try setSecurePermissions(for: authURL, mode: 0o600)
        }
    }

    private func saveBrowserSessionSnapshot(to profileDir: URL) throws {
        let targetRoot = profileDir
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Codex", isDirectory: true)

        if fileManager.fileExists(atPath: targetRoot.path) {
            try fileManager.removeItem(at: targetRoot)
        }
        try fileManager.createDirectory(at: targetRoot, withIntermediateDirectories: true)

        guard fileManager.fileExists(atPath: codexAppSupportDir.path) else { return }
        for item in managedBrowserSessionItems {
            let source = codexAppSupportDir.appendingPathComponent(item)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let target = targetRoot.appendingPathComponent(item)
            try copyItemReplacingExisting(from: source, to: target)
        }
        try setSecurePermissions(for: targetRoot, mode: 0o700)
    }

    private func restoreBrowserSessionSnapshot(from profile: CodexProfile) throws {
        guard profile.hasBrowserSession else { return }
        try fileManager.createDirectory(at: codexAppSupportDir, withIntermediateDirectories: true)
        try removeManagedCurrentSessionItems()
        for item in managedBrowserSessionItems {
            let source = profile.browserSessionURL.appendingPathComponent(item)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let target = codexAppSupportDir.appendingPathComponent(item)
            try copyItemReplacingExisting(from: source, to: target)
        }
        try setSecurePermissions(for: codexAppSupportDir, mode: 0o700)
    }

    private func clearCurrentCodexSession() throws {
        try removeManagedCurrentSessionItems()
        if fileManager.fileExists(atPath: authURL.path) {
            try fileManager.removeItem(at: authURL)
        }
    }

    private func hasUsableAuthFile() -> Bool {
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let apiKey = object["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return true
        }
        guard let tokens = object["tokens"] as? [String: Any] else {
            return false
        }
        let tokenKeys = ["access_token", "refresh_token", "id_token"]
        return tokenKeys.contains { key in
            guard let value = tokens[key] as? String else { return false }
            return !value.isEmpty
        }
    }

    private func sessionChangedSincePendingLogin() -> Bool {
        guard let current = currentSessionFingerprint() else { return false }
        guard let previous = readPendingPreviousFingerprint() else { return true }
        return current != previous
    }

    private func finishPendingAsDuplicate(existingName: String) {
        try? fileManager.removeItem(at: pendingProfileURL)
        try? fileManager.removeItem(at: pendingPreviousProfileURL)
        try? fileManager.removeItem(at: pendingPreviousFingerprintURL)
        pendingProfileName = nil
        if let profile = profiles.first(where: { $0.name.caseInsensitiveCompare(existingName) == .orderedSame }) {
            switchTo(profile)
        } else {
            refresh()
        }
        setStatus("Дубль не сохранён")
    }

    private func skipDuplicateSave(existingName: String) {
        if readPendingProfile() != nil {
            try? fileManager.removeItem(at: pendingProfileURL)
            try? fileManager.removeItem(at: pendingPreviousProfileURL)
            try? fileManager.removeItem(at: pendingPreviousFingerprintURL)
            pendingProfileName = nil
        }
        if let profile = profiles.first(where: { $0.name.caseInsensitiveCompare(existingName) == .orderedSame }) {
            selectedProfileID = profile.id
        }
        setStatus("Дубль не сохранён")
        refresh()
    }

    private func removeManagedCurrentSessionItems() throws {
        for item in managedBrowserSessionItems {
            let target = codexAppSupportDir.appendingPathComponent(item)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
        }
    }

    private func quitCodex() {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName == codexAppName
        }
        for app in running {
            app.terminate()
        }
        guard !running.isEmpty else { return }

        if waitForCodexExit(timeout: 5) {
            return
        }
        for app in running where !app.isTerminated {
            app.forceTerminate()
        }
        _ = waitForCodexExit(timeout: 2)
    }

    private func isCodexRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.localizedName == codexAppName
        }
    }

    private func waitForCodexExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isCodexRunning() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !isCodexRunning()
    }

    private func openCodex() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", codexAppName]
        try? process.run()
    }

    private func ensureDirectories() {
        try? fileManager.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        try? setSecurePermissions(for: switcherDir, mode: 0o700)
        try? setSecurePermissions(for: profilesDir, mode: 0o700)
        try? setSecurePermissions(for: backupsDir, mode: 0o700)
    }

    private func sanitizedProfileName(_ raw: String) throws -> String {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !trimmed.isEmpty else {
            throw SwitcherError.userFacing("Введите имя профиля.")
        }
        let pattern = #"^[A-Za-z0-9 ._-]+$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            throw SwitcherError.userFacing("Имя профиля может содержать только латиницу, цифры, пробел, точку, дефис и подчёркивание.")
        }
        guard trimmed != "." && trimmed != ".." else {
            throw SwitcherError.userFacing("Такое имя профиля использовать нельзя.")
        }
        return trimmed
    }

    private func profileNameExists(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if profiles.contains(where: { $0.name.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return true
        }
        let existingNames = (try? fileManager.contentsOfDirectory(atPath: profilesDir.path)) ?? []
        return existingNames.contains {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }
    }

    private func occupiedSuggestedProfileNumbers() -> Set<Int> {
        let profileNames = profiles.map(\.name) + ((try? fileManager.contentsOfDirectory(atPath: profilesDir.path)) ?? [])
        return Set(profileNames.compactMap(profileNumber))
    }

    private func profileNumber(from name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(trimmed), number > 0 {
            return number
        }
        let pattern = #"(?i)^account\s+([1-9][0-9]*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.numberOfRanges == 2,
              let range = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        return Int(trimmed[range])
    }

    private func uniqueProfileName(basedOn rawBase: String) -> String {
        let base = (try? sanitizedProfileName(rawBase)) ?? suggestedProfileName()
        if !profileNameExists(base) {
            return base
        }
        var index = 2
        var candidate = "\(base) \(index)"
        while profileNameExists(candidate) {
            index += 1
            candidate = "\(base) \(index)"
        }
        return candidate
    }

    private func validBaseProfileName(from url: URL) -> String {
        let raw = url.hasDirectoryPath ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        return (try? sanitizedProfileName(raw)) ?? suggestedProfileName()
    }

    private func currentSessionFingerprint() -> String? {
        let auth = fileManager.fileExists(atPath: authURL.path) ? authURL : nil
        let browser = fileManager.fileExists(atPath: codexAppSupportDir.path) ? codexAppSupportDir : nil
        return sessionFingerprint(auth: auth, browserSession: browser)
    }

    private func currentSessionDuplicateKey() -> String? {
        let auth = fileManager.fileExists(atPath: authURL.path) ? authURL : nil
        if let auth, let identity = profileAccountIdentity(from: auth) {
            return identity
        }
        return currentSessionFingerprint().map { "fingerprint:\($0)" }
    }

    private func profileSessionFingerprint(in profileDir: URL) -> String? {
        sessionFingerprint(auth: authSnapshotURL(in: profileDir), browserSession: browserSessionSnapshotURL(in: profileDir))
    }

    private func profileDuplicateKey(in profileDir: URL) -> String? {
        if let auth = authSnapshotURL(in: profileDir),
           let identity = profileAccountIdentity(from: auth) {
            return identity
        }
        return profileSessionFingerprint(in: profileDir).map { "fingerprint:\($0)" }
    }

    private func candidateSessionFingerprint(at source: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            return sessionFingerprint(auth: authSnapshotURL(in: source), browserSession: browserSessionSnapshotURL(in: source))
        }
        if source.lastPathComponent == "auth.json" {
            return sessionFingerprint(auth: source, browserSession: nil)
        }
        if managedBrowserSessionItems.contains(source.lastPathComponent) {
            return singleFileFingerprint(source, label: source.lastPathComponent)
        }
        return nil
    }

    private func candidateDuplicateKey(at source: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            if let auth = authSnapshotURL(in: source),
               let identity = profileAccountIdentity(from: auth) {
                return identity
            }
        } else if source.lastPathComponent == "auth.json",
                  let identity = profileAccountIdentity(from: source) {
            return identity
        }
        return candidateSessionFingerprint(at: source).map { "fingerprint:\($0)" }
    }

    private func findProfileMatchingDuplicateKey(_ duplicateKey: String, excluding excludedName: String?) -> String? {
        let excluded = excludedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileDirs = (try? fileManager.contentsOfDirectory(
            at: profilesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for profileDir in profileDirs where profileDir.hasDirectoryPath {
            let name = profileDir.lastPathComponent
            if let excluded, name.caseInsensitiveCompare(excluded) == .orderedSame {
                continue
            }
            guard profileDuplicateKey(in: profileDir) == duplicateKey else { continue }
            return name
        }
        return nil
    }

    private func sessionFingerprint(auth: URL?, browserSession: URL?) -> String? {
        var hasher = SHA256()
        var includedData = false

        if let auth, fileManager.fileExists(atPath: auth.path),
           hashFile(auth, label: "auth.json", into: &hasher) {
            includedData = true
        }

        if let browserSession, fileManager.fileExists(atPath: browserSession.path) {
            for item in managedBrowserSessionItems {
                let itemURL = browserSession.appendingPathComponent(item)
                if hashItem(itemURL, label: "browser/\(item)", into: &hasher) {
                    includedData = true
                }
            }
        }

        guard includedData else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func singleFileFingerprint(_ fileURL: URL, label: String) -> String? {
        var hasher = SHA256()
        guard hashFile(fileURL, label: label, into: &hasher) else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private func hashItem(_ url: URL, label: String, into hasher: inout SHA256) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue {
            var includedData = false
            updateHash(&hasher, "dir:\(label)\n")
            let children = (try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if hashItem(child, label: "\(label)/\(child.lastPathComponent)", into: &hasher) {
                    includedData = true
                }
            }
            return includedData
        }
        return hashFile(url, label: label, into: &hasher)
    }

    @discardableResult
    private func hashFile(_ url: URL, label: String, into hasher: inout SHA256) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        updateHash(&hasher, "file:\(label):\(data.count)\n")
        hasher.update(data: data)
        updateHash(&hasher, "\n")
        return true
    }

    private func updateHash(_ hasher: inout SHA256, _ text: String) {
        hasher.update(data: Data(text.utf8))
    }

    private func copySessionCandidate(from source: URL, to target: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            if let auth = authSnapshotURL(in: source) {
                try replaceFile(from: auth, to: target.appendingPathComponent("auth.json"))
                try setSecurePermissions(for: target.appendingPathComponent("auth.json"), mode: 0o600)
            }
            if let browser = browserSessionSnapshotURL(in: source) {
                let targetBrowser = target
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent("Codex", isDirectory: true)
                try fileManager.createDirectory(at: targetBrowser, withIntermediateDirectories: true)
                for item in managedBrowserSessionItems {
                    let sourceItem = browser.appendingPathComponent(item)
                    guard fileManager.fileExists(atPath: sourceItem.path) else { continue }
                    try copyItemReplacingExisting(from: sourceItem, to: targetBrowser.appendingPathComponent(item))
                }
                try setSecurePermissions(for: targetBrowser, mode: 0o700)
            }
            return
        }

        if source.lastPathComponent == "auth.json" {
            try replaceFile(from: source, to: target.appendingPathComponent("auth.json"))
            try setSecurePermissions(for: target.appendingPathComponent("auth.json"), mode: 0o600)
            return
        }

        if managedBrowserSessionItems.contains(source.lastPathComponent) {
            let targetBrowser = target
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Codex", isDirectory: true)
            try fileManager.createDirectory(at: targetBrowser, withIntermediateDirectories: true)
            try copyItemReplacingExisting(from: source, to: targetBrowser.appendingPathComponent(source.lastPathComponent))
            try setSecurePermissions(for: targetBrowser, mode: 0o700)
        }
    }

    private func replaceFile(from source: URL, to target: URL) throws {
        let parent = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".\(target.lastPathComponent).tmp-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: temporary, to: target)
    }

    private func copyItemReplacingExisting(from source: URL, to target: URL) throws {
        let parent = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.copyItem(at: source, to: target)
    }

    private func readActiveProfile() -> String? {
        guard let text = try? String(contentsOf: currentProfileURL, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func readPendingProfile() -> String? {
        guard let text = try? String(contentsOf: pendingProfileURL, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func pendingLoginAge() -> TimeInterval {
        let values = try? pendingProfileURL.resourceValues(forKeys: [.contentModificationDateKey])
        guard let startedAt = values?.contentModificationDate else { return .infinity }
        return Date().timeIntervalSince(startedAt)
    }

    private func readPendingPreviousProfile() -> String? {
        guard let text = try? String(contentsOf: pendingPreviousProfileURL, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func writeActiveProfile(_ name: String) throws {
        try name.appending("\n").write(to: currentProfileURL, atomically: true, encoding: .utf8)
        try setSecurePermissions(for: currentProfileURL, mode: 0o600)
    }

    private func writePendingProfile(_ name: String) throws {
        try name.appending("\n").write(to: pendingProfileURL, atomically: true, encoding: .utf8)
        try setSecurePermissions(for: pendingProfileURL, mode: 0o600)
    }

    private func writePendingPreviousProfile(_ name: String?) throws {
        if let name, !name.isEmpty {
            try name.appending("\n").write(to: pendingPreviousProfileURL, atomically: true, encoding: .utf8)
            try setSecurePermissions(for: pendingPreviousProfileURL, mode: 0o600)
        } else if fileManager.fileExists(atPath: pendingPreviousProfileURL.path) {
            try fileManager.removeItem(at: pendingPreviousProfileURL)
        }
    }

    private func readPendingPreviousFingerprint() -> String? {
        guard let text = try? String(contentsOf: pendingPreviousFingerprintURL, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func writePendingPreviousFingerprint(_ fingerprint: String?) throws {
        if let fingerprint, !fingerprint.isEmpty {
            try fingerprint.appending("\n").write(to: pendingPreviousFingerprintURL, atomically: true, encoding: .utf8)
            try setSecurePermissions(for: pendingPreviousFingerprintURL, mode: 0o600)
        } else if fileManager.fileExists(atPath: pendingPreviousFingerprintURL.path) {
            try fileManager.removeItem(at: pendingPreviousFingerprintURL)
        }
    }

    private func setSecurePermissions(for url: URL, mode: Int16) throws {
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(line)\n"
        if let data = text.data(using: .utf8) {
            if fileManager.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private func show(_ error: Error) {
        let text: String
        if let switcherError = error as? SwitcherError {
            text = switcherError.localizedDescription
        } else {
            text = error.localizedDescription
        }
        errorMessage = text
        setStatus("Ошибка", autoClear: false)
        log("ERROR: \(text)")
    }

    private func setStatus(_ text: String, autoClear: Bool = true, showsProgress: Bool = false) {
        statusResetWorkItem?.cancel()
        message = text
        messageShowsProgress = showsProgress
        guard autoClear else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.readPendingProfile() == nil {
                self.message = "Ожидание действий"
                self.messageShowsProgress = false
            }
        }
        statusResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: workItem)
    }
}

enum SwitcherError: LocalizedError {
    case userFacing(String)

    var errorDescription: String? {
        switch self {
        case .userFacing(let text):
            return text
        }
    }
}

extension JSONEncoder {
    static var codexDateEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var codexDateDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) {
                return date
            }

            let standard = ISO8601DateFormatter()
            if let date = standard.date(from: text) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(text)"
            )
        }
        return decoder
    }
}

struct ContentView: View {
    @StateObject private var store = AccountStore()
    @State private var newProfileName = ""
    @State private var lastSuggestedProfileName = ""
    @State private var renameProfileName = ""
    @State private var profileSearchText = ""
    @State private var showingDeleteConfirmation = false
    @State private var showingRenameDialog = false
    @State private var now = Date()
    @State private var statusDotStep = 0
    private let loginPoller = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let limitTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let limitRefreshTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()
    private let statusAnimationTimer = Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()

    private var selectedProfile: CodexProfile? {
        guard let selected = store.selectedProfileID else { return nil }
        return store.profiles.first(where: { $0.id == selected })
    }

    private var filteredProfiles: [CodexProfile] {
        let query = profileSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.profiles }
        let parts = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        return store.profiles.filter { profile in
            let haystack = [profile.name, profile.email ?? ""]
                .joined(separator: " ")
                .lowercased()
            return parts.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            mainContent
            Divider()
            footer
        }
        .frame(minWidth: 780, minHeight: 480)
        .onAppear {
            fillSuggestedNameIfNeeded()
        }
        .onReceive(loginPoller) { _ in
            store.pollPendingLogin()
            fillSuggestedNameIfNeeded()
        }
        .onReceive(limitTicker) { value in
            now = value
        }
        .onReceive(limitRefreshTimer) { _ in
            store.refreshAndUpdateActiveLimits()
        }
        .onReceive(statusAnimationTimer) { _ in
            statusDotStep = store.messageShowsProgress ? (statusDotStep + 1) % 3 : 0
        }
        .onChange(of: profileSearchText) {
            keepSelectionVisibleInSearch()
        }
        .onChange(of: store.profiles) {
            keepSelectionVisibleInSearch()
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            store.importDroppedProviders(providers)
            return true
        }
        .alert("Ошибка", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog(
            "Удалить профиль?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                store.deleteSelectedProfile()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(selectedProfile?.name ?? "")
        }
        .alert("Переименовать профиль", isPresented: $showingRenameDialog) {
            TextField("Название", text: $renameProfileName)
            Button("Сохранить") {
                store.renameSelectedProfile(to: renameProfileName)
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Codex Account Switcher")
                        .font(.title2.weight(.semibold))
                    Text("v1.0")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("Активный профиль: \(store.activeProfileName)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                openExternalURL("https://t.me/b_tier")
            } label: {
                Label("Telegram", systemImage: "paperplane")
            }
            Button {
                openExternalURL("https://github.com/goutor/CAS")
            } label: {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Button {
                store.refreshAndUpdateActiveLimits()
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            Button {
                store.revealProfilesFolder()
            } label: {
                Label("Папка профилей", systemImage: "folder")
            }
        }
        .padding(20)
    }

    private func openExternalURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    private var mainContent: some View {
        HStack(spacing: 0) {
            profileList
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
            Divider()
            profileDetails
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Профили")
                    .font(.headline)
                Spacer()
                Text("Всего: \(store.profiles.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("поиск по названию или почте", text: $profileSearchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            if store.profiles.isEmpty {
                emptyList
            } else if filteredProfiles.isEmpty {
                noSearchResults
            } else {
                List(selection: $store.selectedProfileID) {
                    ForEach(filteredProfiles) { profile in
                        profileRow(profile)
                            .tag(profile.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .padding(16)
    }

    private var noSearchResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Нет совпадений.")
                .font(.headline)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Пока нет сохранённых профилей.")
                .font(.headline)
            Text("Введите имя аккаунта справа и нажмите «Войти». После логина профиль сохранится автоматически.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func profileRow(_ profile: CodexProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(profile.name)
                    .font(.body.weight(profile.isActive ? .semibold : .regular))
                    .lineLimit(1)
                if let email = profile.email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if profile.error != nil {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                } else if profile.isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            Text(profile.modifiedAt.map(formatDate) ?? "дата неизвестна")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(profile.error.map(errorListText) ?? shortLimitsText(profile.limits, now: now))
                .font(.caption)
                .foregroundStyle(profileRowStatusStyle(profile, now: now))
        }
        .padding(.vertical, 4)
    }

    private var profileDetails: some View {
        VStack(alignment: .leading, spacing: 18) {
            addAccountPanel
            Divider()
            if let profile = selectedProfile {
                selectedPanel(profile)
            } else {
                Text("Выберите профиль слева.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(20)
    }

    private var addAccountPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Добавить аккаунт")
                .font(.headline)
            HStack(spacing: 10) {
                TextField("название аккаунта", text: $newProfileName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(beginLogin)
                Button {
                    beginLogin()
                } label: {
                    Label("Войти", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.pendingProfileName != nil)
            }
            if let pending = store.pendingProfileName {
                HStack(spacing: 10) {
                    Image(systemName: "person.badge.clock")
                        .foregroundStyle(.orange)
                    Text("Ожидаю вход для \(pending). После успешного логина профиль сохранится сам.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.caption)
            }
            Text("Нажатие «Войти» откроет Codex без старой сессии. Текущий аккаунт будет сохранён перед выходом.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func selectedPanel(_ profile: CodexProfile) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(profile.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        if let email = profile.email {
                            Text(email)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Text(profile.error.map(errorListText) ?? (profile.isActive ? "Сейчас активен" : "Сохранённая сессия"))
                        .foregroundStyle(profile.error == nil ? (profile.isActive ? .green : .secondary) : .red)
                }
                Spacer()
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                if let error = profile.error {
                    GridRow {
                        Text("Ошибка")
                            .foregroundStyle(.secondary)
                        Text("\(error.code): \(error.message)")
                            .foregroundStyle(.red)
                            .lineLimit(3)
                            .truncationMode(.tail)
                    }
                }
                GridRow {
                    Text("Сохранено")
                        .foregroundStyle(.secondary)
                    Text(profile.modifiedAt.map(formatDate) ?? "дата неизвестна")
                }
                GridRow {
                    Text("Лимиты")
                        .foregroundStyle(.secondary)
                    Text(detailedLimitsText(profile.limits, now: now))
                        .lineLimit(3)
                        .truncationMode(.tail)
                }
                GridRow {
                    Text("Состав")
                        .foregroundStyle(.secondary)
                    Text(profileContents(profile))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                GridRow {
                    Text("Папка")
                        .foregroundStyle(.secondary)
                    Text(profile.profileURL.path)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 10) {
                Button {
                    store.switchToSelectedProfile()
                } label: {
                    Label("Переключиться", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(profile.isActive)

                Button {
                    renameProfileName = profile.name
                    showingRenameDialog = true
                } label: {
                    Label("Редактировать название", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Text(statusText)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Профили хранятся локально: \(store.profilesStoragePath)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        guard store.messageShowsProgress else { return store.message }
        return store.message + String(repeating: ".", count: statusDotStep + 1)
    }

    private func beginLogin() {
        store.beginLoginForNewProfile(named: newProfileName)
        if store.errorMessage == nil {
            newProfileName = ""
            lastSuggestedProfileName = ""
        }
    }

    private func fillSuggestedNameIfNeeded() {
        let currentName = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.pendingProfileName == nil,
              (currentName.isEmpty || currentName == lastSuggestedProfileName) else {
            return
        }
        let suggestion = store.suggestedProfileName()
        newProfileName = suggestion
        lastSuggestedProfileName = suggestion
    }

    private func keepSelectionVisibleInSearch() {
        let profiles = filteredProfiles
        guard !profiles.isEmpty else { return }
        if let selected = store.selectedProfileID,
           profiles.contains(where: { $0.id == selected }) {
            return
        }
        store.selectedProfileID = profiles.first?.id
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func profileContents(_ profile: CodexProfile) -> String {
        var parts: [String] = []
        if profile.hasBrowserSession {
            parts.append("вход ChatGPT/Codex")
        }
        if profile.hasAuth {
            parts.append("CLI auth.json")
        }
        return parts.isEmpty ? "пусто" : parts.joined(separator: " + ")
    }

    private func errorListText(_ error: ProfileErrorSnapshot) -> String {
        "Ошибка: \(error.code)"
    }

    private func profileRowStatusStyle(_ profile: CodexProfile, now: Date) -> AnyShapeStyle {
        if profile.error != nil {
            return AnyShapeStyle(.red)
        }
        if profile.limits?.remainingPercent(at: now) == nil {
            return AnyShapeStyle(.secondary)
        }
        return AnyShapeStyle(.primary)
    }

    private func shortLimitsText(_ limits: CodexLimitSnapshot?, now: Date) -> String {
        guard let limits else {
            return "лимиты: жду данных Codex"
        }
        if let remaining = limits.remainingPercent {
            if remaining <= 0 {
                return "\(planPrefix(limits))0%"
            }
            return "\(planPrefix(limits))~\(formatPercent(remaining)), \(compactResetText(limits, now: now))"
        }
        if let secondaryRemaining = limits.secondaryRemainingPercent {
            if secondaryRemaining <= 0 {
                return "\(planPrefix(limits))0%"
            }
            return "\(planPrefix(limits))~\(formatPercent(secondaryRemaining)), \(compactResetText(limits, now: now))"
        }
        return "лимиты: жду данных Codex"
    }

    private func detailedLimitsText(_ limits: CodexLimitSnapshot?, now: Date) -> String {
        guard let limits else {
            return "нет данных: Codex ещё не записал rate_limits для этого аккаунта"
        }
        var parts: [String] = []
        if let remaining = limits.remainingPercent {
            parts.append("\(formatWindow(limits.windowMinutes)): осталось \(remaining <= 0 ? "0%" : "~\(formatPercent(remaining))")")
        }
        if let secondaryRemaining = limits.secondaryRemainingPercent {
            parts.append("\(formatWindow(limits.secondaryWindowMinutes)): осталось \(secondaryRemaining <= 0 ? "0%" : "~\(formatPercent(secondaryRemaining))")")
        }
        if let sourceTimestamp = limits.sourceTimestamp ?? Optional(limits.capturedAt) {
            parts.append("получено \(formatAge(now.timeIntervalSince(sourceTimestamp))) назад")
        }
        if let resetText = resetText(limits) {
            parts.append(resetText)
        }
        if let planType = limits.planType, !planType.isEmpty {
            parts.append("план \(displayPlan(planType))")
        }
        return parts.isEmpty ? "нет данных" : parts.joined(separator: ", ")
    }

    private func snapshotAgeSuffix(_ limits: CodexLimitSnapshot, now: Date) -> String {
        let timestamp = limits.sourceTimestamp ?? limits.capturedAt
        return ", \(formatAge(now.timeIntervalSince(timestamp))) назад"
    }

    private func compactResetText(_ limits: CodexLimitSnapshot, now: Date) -> String {
        let resets = [limits.resetsAt, limits.secondaryResetsAt].compactMap { $0 }
        guard let nextReset = resets.filter({ $0 > now }).min() ?? resets.max() else {
            let timestamp = limits.sourceTimestamp ?? limits.capturedAt
            return "\(formatAge(now.timeIntervalSince(timestamp))) назад"
        }
        if nextReset > now {
            return "сброс через \(formatDuration(nextReset.timeIntervalSince(now)))"
        }
        return "сброс \(formatDate(nextReset))"
    }

    private func planPrefix(_ limits: CodexLimitSnapshot) -> String {
        guard let planType = limits.planType, !planType.isEmpty else { return "" }
        return "\(displayPlan(planType)): "
    }

    private func resetText(_ limits: CodexLimitSnapshot) -> String? {
        let resets = [limits.resetsAt, limits.secondaryResetsAt].compactMap { $0 }
        guard !resets.isEmpty else { return nil }
        return "сброс: \(resets.map(formatDate).joined(separator: ", "))"
    }

    private func formatAge(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total >= 86400 {
            return "\(total / 86400) д."
        }
        if total >= 3600 {
            return "\(total / 3600) ч."
        }
        if total >= 60 {
            return "\(total / 60) мин."
        }
        return "\(total) сек."
    }

    private func formatPercent(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))%"
        }
        return String(format: "%.1f%%", value)
    }

    private func formatWindow(_ minutes: Int?) -> String {
        guard let minutes else { return "лимит" }
        if minutes % 10080 == 0 {
            return "\(minutes / 10080) нед."
        }
        if minutes % 1440 == 0 {
            return "\(minutes / 1440) дн."
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60) ч."
        }
        return "\(minutes) мин."
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if days > 0 {
            return "\(days) д. \(hours) ч."
        }
        if hours > 0 {
            return "\(hours) ч. \(minutes) мин."
        }
        if minutes > 0 {
            return "\(minutes) мин. \(seconds) сек."
        }
        return "\(seconds) сек."
    }

    private func displayPlan(_ plan: String) -> String {
        switch plan.lowercased() {
        case "free":
            return "Free"
        case "plus":
            return "Plus"
        case "pro":
            return "Pro"
        case "team":
            return "Team"
        case "enterprise":
            return "Enterprise"
        default:
            return plan
        }
    }
}

@main
struct CodexAccountSwitcherApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
