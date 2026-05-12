using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace CodexAccountSwitcher.WindowsApp
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            NativeMethods.EnableDpiAwareness();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    internal static class NativeMethods
    {
        private static readonly IntPtr DpiAwarenessContextPerMonitorAwareV2 = new IntPtr(-4);
        private const int EmSetCueBanner = 0x1501;

        [DllImport("user32.dll")]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

        [DllImport("shcore.dll")]
        private static extern int SetProcessDpiAwareness(int awareness);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int attributeValue, int attributeSize);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);

        public static void EnableDpiAwareness()
        {
            try
            {
                if (SetProcessDpiAwarenessContext(DpiAwarenessContextPerMonitorAwareV2))
                {
                    return;
                }
            }
            catch
            {
            }

            try
            {
                if (SetProcessDpiAwareness(2) == 0)
                {
                    return;
                }
            }
            catch
            {
            }

            try
            {
                SetProcessDPIAware();
            }
            catch
            {
            }
        }

        public static void ApplyDarkTitleBar(IntPtr handle)
        {
            var enabled = 1;
            try
            {
                DwmSetWindowAttribute(handle, 20, ref enabled, Marshal.SizeOf(typeof(int)));
                DwmSetWindowAttribute(handle, 19, ref enabled, Marshal.SizeOf(typeof(int)));
            }
            catch
            {
            }
        }

        public static void SetCueBanner(TextBox textBox, string placeholder)
        {
            if (textBox == null || textBox.IsDisposed)
            {
                return;
            }

            try
            {
                if (!textBox.IsHandleCreated)
                {
                    var unused = textBox.Handle;
                }
                SendMessage(textBox.Handle, EmSetCueBanner, (IntPtr)1, placeholder ?? string.Empty);
            }
            catch
            {
            }
        }
    }

    internal sealed class SwitcherException : Exception
    {
        public SwitcherException(string message) : base(message)
        {
        }
    }

    internal enum PendingPollState
    {
        None,
        Waiting,
        Completed,
        Cancelled
    }

    internal enum ButtonIconKind
    {
        None,
        Telegram,
        GitHub,
        Refresh,
        Folder
    }

    internal sealed class ProfileInfo
    {
        public string Name { get; set; }
        public string DirectoryPath { get; set; }
        public string AuthPath { get; set; }
        public string SessionPath { get; set; }
        public bool HasAuth { get; set; }
        public bool HasSession { get; set; }
        public bool IsActive { get; set; }
        public DateTime? ModifiedAt { get; set; }
        public string Email { get; set; }
    }

    internal sealed class SwitcherService
    {
        private readonly string _homeDir;
        private readonly string _codexHome;
        private readonly string _authFile;
        private readonly string _switcherDir;
        private readonly string _profilesDir;
        private readonly string _backupsDir;
        private readonly string _currentFile;
        private readonly string _pendingFile;
        private readonly string _pendingPrevProfileFile;
        private readonly string _pendingPrevFingerprintFile;
        private readonly string _languageFile;
        private readonly string _logFile;

        private readonly string[] _managedBrowserSessionItems =
        {
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
        };

        public SwitcherService()
        {
            _homeDir = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var envCodexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
            _codexHome = string.IsNullOrWhiteSpace(envCodexHome)
                ? Path.Combine(_homeDir, ".codex")
                : envCodexHome.Trim();
            _authFile = Path.Combine(_codexHome, "auth.json");
            _switcherDir = Path.Combine(_homeDir, ".codex-account-switcher");
            _profilesDir = Path.Combine(_switcherDir, "profiles");
            _backupsDir = Path.Combine(_switcherDir, "backups");
            _currentFile = Path.Combine(_switcherDir, "current_profile");
            _pendingFile = Path.Combine(_switcherDir, "pending_profile");
            _pendingPrevProfileFile = Path.Combine(_switcherDir, "pending_previous_profile");
            _pendingPrevFingerprintFile = Path.Combine(_switcherDir, "pending_previous_fingerprint");
            _languageFile = Path.Combine(_switcherDir, "ui_language");
            _logFile = Path.Combine(_switcherDir, "switcher.log");

            EnsureDirectories();
        }

        public string ProfilesDirPath
        {
            get { return _profilesDir; }
        }

        public string ReadLanguage()
        {
            var value = ReadTextFileTrimmed(_languageFile);
            return string.Equals(value, "RU", StringComparison.OrdinalIgnoreCase) ? "RU" : "EN";
        }

        public void WriteLanguage(string language)
        {
            var value = string.Equals(language, "RU", StringComparison.OrdinalIgnoreCase) ? "RU" : "EN";
            File.WriteAllText(_languageFile, value + Environment.NewLine, Encoding.UTF8);
        }

        public string SuggestedProfileName()
        {
            EnsureDirectories();
            var existing = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var dir in Directory.GetDirectories(_profilesDir))
            {
                var name = Path.GetFileName(dir);
                if (!string.IsNullOrWhiteSpace(name))
                {
                    existing.Add(name);
                }
            }

            var index = 1;
            while (true)
            {
                var name = "Account " + index;
                if (!existing.Contains(name))
                {
                    return name;
                }
                index++;
            }
        }

        public List<ProfileInfo> GetProfiles()
        {
            EnsureDirectories();
            var active = ReadCurrentProfile();
            var profiles = new List<ProfileInfo>();

            foreach (var dir in Directory.GetDirectories(_profilesDir))
            {
                var name = Path.GetFileName(dir);
                if (string.IsNullOrWhiteSpace(name))
                {
                    continue;
                }

                var authPath = Path.Combine(dir, "auth.json");
                var sessionPath = Path.Combine(dir, "CodexSession");
                var hasAuth = File.Exists(authPath);
                var hasSession = SessionSnapshotHasData(sessionPath);
                if (!hasAuth && !hasSession)
                {
                    continue;
                }

                DateTime? modified = null;
                if (hasAuth)
                {
                    modified = File.GetLastWriteTime(authPath);
                }
                if (hasSession)
                {
                    var sessionModified = Directory.GetLastWriteTime(sessionPath);
                    if (!modified.HasValue || sessionModified > modified.Value)
                    {
                        modified = sessionModified;
                    }
                }

                profiles.Add(new ProfileInfo
                {
                    Name = name,
                    DirectoryPath = dir,
                    AuthPath = authPath,
                    SessionPath = sessionPath,
                    HasAuth = hasAuth,
                    HasSession = hasSession,
                    IsActive = !string.IsNullOrEmpty(active) && string.Equals(active, name, StringComparison.OrdinalIgnoreCase),
                    ModifiedAt = modified,
                    Email = hasAuth ? ParseEmailFromAuth(authPath) : string.Empty
                });
            }

            profiles.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
            return profiles;
        }

        public string ReadCurrentProfile()
        {
            return ReadTextFileTrimmed(_currentFile);
        }

        public string ReadPendingProfile()
        {
            return ReadTextFileTrimmed(_pendingFile);
        }

        public void SaveCurrentSessionToProfile(string rawProfileName)
        {
            var name = ValidateProfileName(rawProfileName);
            StopCodex();
            SaveSessionSnapshotToProfile(name, allowCreate: true, replaceExisting: true);
            WriteCurrentProfile(name);
            StartCodex();
            Log("Saved current session as '" + name + "'.");
        }

        public void SwitchToProfile(string rawProfileName)
        {
            var name = ValidateProfileName(rawProfileName);
            var profileDir = GetProfileDir(name);
            if (!Directory.Exists(profileDir))
            {
                throw new SwitcherException("Profile '" + name + "' was not found.");
            }

            var profileAuth = Path.Combine(profileDir, "auth.json");
            var profileSession = Path.Combine(profileDir, "CodexSession");
            var hasAuth = File.Exists(profileAuth);
            var hasSession = SessionSnapshotHasData(profileSession);
            if (!hasAuth && !hasSession)
            {
                throw new SwitcherException("Profile '" + name + "' has no saved session.");
            }

            StopCodex();
            RefreshActiveProfileSessionIfPossible();
            BackupCurrentAuthIfPresent();
            ClearCurrentSession();

            if (hasAuth)
            {
                Directory.CreateDirectory(_codexHome);
                CopyFileReplace(profileAuth, _authFile);
            }

            var targetSessionRoot = GetCodexSessionPath();
            Directory.CreateDirectory(targetSessionRoot);

            if (hasSession)
            {
                foreach (var item in _managedBrowserSessionItems)
                {
                    var source = Path.Combine(profileSession, item);
                    if (!File.Exists(source) && !Directory.Exists(source))
                    {
                        continue;
                    }
                    var target = Path.Combine(targetSessionRoot, item);
                    CopyItemReplace(source, target);
                }
            }

            WriteCurrentProfile(name);
            StartCodex();
            Log("Switched to '" + name + "'.");
        }

        public void RenameProfile(string rawOldName, string rawNewName)
        {
            var oldName = ValidateProfileName(rawOldName);
            var newName = ValidateProfileName(rawNewName);
            if (string.Equals(oldName, newName, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            var oldPath = GetProfileDir(oldName);
            var newPath = GetProfileDir(newName);
            if (!Directory.Exists(oldPath))
            {
                throw new SwitcherException("Profile '" + oldName + "' was not found.");
            }
            if (Directory.Exists(newPath))
            {
                throw new SwitcherException("Profile '" + newName + "' already exists.");
            }

            Directory.Move(oldPath, newPath);

            if (string.Equals(ReadCurrentProfile(), oldName, StringComparison.OrdinalIgnoreCase))
            {
                WriteCurrentProfile(newName);
            }
            if (string.Equals(ReadPendingProfile(), oldName, StringComparison.OrdinalIgnoreCase))
            {
                WritePendingProfile(newName);
            }

            Log("Renamed profile '" + oldName + "' to '" + newName + "'.");
        }

        public void DeleteProfile(string rawName)
        {
            var name = ValidateProfileName(rawName);
            var profileDir = GetProfileDir(name);
            if (!Directory.Exists(profileDir))
            {
                return;
            }

            Directory.Delete(profileDir, true);

            if (string.Equals(ReadCurrentProfile(), name, StringComparison.OrdinalIgnoreCase))
            {
                TryDeleteFile(_currentFile);
            }
            if (string.Equals(ReadPendingProfile(), name, StringComparison.OrdinalIgnoreCase))
            {
                ClearPendingState();
            }

            Log("Deleted profile '" + name + "'.");
        }

        public void StartPendingLoginFlow(string rawName)
        {
            var name = ValidateProfileName(rawName);
            var profileDir = GetProfileDir(name);
            if (Directory.Exists(profileDir))
            {
                throw new SwitcherException("Profile '" + name + "' already exists.");
            }

            StopCodex();
            RefreshActiveProfileSessionIfPossible();
            BackupCurrentAuthIfPresent();

            var previousProfile = ReadCurrentProfile();
            var previousFingerprint = GetCurrentSessionFingerprint();

            ClearCurrentSession();
            WritePendingProfile(name);
            WritePendingPreviousProfile(previousProfile);
            WritePendingPreviousFingerprint(previousFingerprint);
            TryDeleteFile(_currentFile);

            StartCodex();
            Log("Started login flow for '" + name + "'.");
        }

        public void CancelPendingLoginFlow()
        {
            var pending = ReadPendingProfile();
            if (string.IsNullOrEmpty(pending))
            {
                return;
            }
            CancelPendingLoginFlowInternal(restorePreviousProfile: true);
        }

        public PendingPollState PollPendingLoginFlow()
        {
            var pending = ReadPendingProfile();
            if (string.IsNullOrEmpty(pending))
            {
                return PendingPollState.None;
            }

            if (!HasUsableAuthFile())
            {
                if (!IsCodexRunning() && GetPendingAgeSeconds() > 8)
                {
                    CancelPendingLoginFlowInternal(restorePreviousProfile: true);
                    return PendingPollState.Cancelled;
                }
                return PendingPollState.Waiting;
            }

            var currentFingerprint = GetCurrentSessionFingerprint();
            var previousFingerprint = ReadTextFileTrimmed(_pendingPrevFingerprintFile);
            if (!string.IsNullOrEmpty(currentFingerprint) &&
                (!string.Equals(currentFingerprint, previousFingerprint, StringComparison.OrdinalIgnoreCase) ||
                 string.IsNullOrEmpty(previousFingerprint)))
            {
                SaveSessionSnapshotToProfile(pending, allowCreate: true, replaceExisting: false);
                WriteCurrentProfile(pending);
                ClearPendingState();
                Log("Completed login flow for '" + pending + "'.");
                return PendingPollState.Completed;
            }

            // If Codex is already closed and fingerprint did not change, treat it as failed login and rollback.
            if (!IsCodexRunning() && GetPendingAgeSeconds() > 8)
            {
                CancelPendingLoginFlowInternal(restorePreviousProfile: true);
                return PendingPollState.Cancelled;
            }

            return PendingPollState.Waiting;
        }

        private void CancelPendingLoginFlowInternal(bool restorePreviousProfile)
        {
            var pending = ReadPendingProfile();
            var previous = ReadTextFileTrimmed(_pendingPrevProfileFile);
            ClearPendingState();

            if (restorePreviousProfile && !string.IsNullOrEmpty(previous))
            {
                var previousDir = GetProfileDir(previous);
                if (Directory.Exists(previousDir))
                {
                    SwitchToProfile(previous);
                }
            }

            Log("Cancelled login flow for '" + pending + "'.");
        }

        private void SaveSessionSnapshotToProfile(string profileName, bool allowCreate, bool replaceExisting)
        {
            EnsureDirectories();
            var profileDir = GetProfileDir(profileName);
            if (Directory.Exists(profileDir))
            {
                if (!replaceExisting)
                {
                    throw new SwitcherException("Profile '" + profileName + "' already exists.");
                }
            }
            else
            {
                if (!allowCreate)
                {
                    throw new SwitcherException("Profile '" + profileName + "' was not found.");
                }
                Directory.CreateDirectory(profileDir);
            }

            var sourceSessionRoot = GetCodexSessionPath();
            var sourceHasSession = SessionSnapshotHasData(sourceSessionRoot);
            var sourceHasAuth = File.Exists(_authFile);
            if (!sourceHasAuth && !sourceHasSession)
            {
                throw new SwitcherException("Codex login data not found. Sign in to Codex first.");
            }

            var targetAuth = Path.Combine(profileDir, "auth.json");
            if (sourceHasAuth)
            {
                CopyFileReplace(_authFile, targetAuth);
            }

            var targetSession = Path.Combine(profileDir, "CodexSession");
            Directory.CreateDirectory(targetSession);
            if (sourceHasSession)
            {
                foreach (var item in _managedBrowserSessionItems)
                {
                    var source = Path.Combine(sourceSessionRoot, item);
                    if (!File.Exists(source) && !Directory.Exists(source))
                    {
                        continue;
                    }

                    var target = Path.Combine(targetSession, item);
                    CopyItemReplace(source, target);
                }
            }
        }

        public void RefreshActiveProfileSessionIfPossible()
        {
            var active = ReadCurrentProfile();
            if (string.IsNullOrEmpty(active))
            {
                return;
            }

            var profileDir = GetProfileDir(active);
            if (!Directory.Exists(profileDir))
            {
                return;
            }

            var sourceSessionRoot = GetCodexSessionPath();
            var sourceHasSession = SessionSnapshotHasData(sourceSessionRoot);
            var sourceHasAuth = File.Exists(_authFile);
            if (!sourceHasAuth && !sourceHasSession)
            {
                return;
            }

            SaveSessionSnapshotToProfile(active, allowCreate: false, replaceExisting: true);
            Log("Refreshed active profile '" + active + "'.");
        }

        private void EnsureDirectories()
        {
            Directory.CreateDirectory(_switcherDir);
            Directory.CreateDirectory(_profilesDir);
            Directory.CreateDirectory(_backupsDir);
        }

        private string ValidateProfileName(string rawName)
        {
            var name = (rawName ?? string.Empty).Trim();
            if (string.IsNullOrWhiteSpace(name))
            {
                throw new SwitcherException("Profile name is required.");
            }
            if (name == "." || name == "..")
            {
                throw new SwitcherException("Profile name is not allowed.");
            }
            if (!Regex.IsMatch(name, @"^[A-Za-z0-9 ._-]+$"))
            {
                throw new SwitcherException("Profile name can contain only Latin letters, numbers, space, dot, dash, and underscore.");
            }
            return name;
        }

        private string GetProfileDir(string name)
        {
            return Path.Combine(_profilesDir, name);
        }

        private string ReadTextFileTrimmed(string path)
        {
            if (!File.Exists(path))
            {
                return string.Empty;
            }
            var text = File.ReadAllText(path, Encoding.UTF8).Trim();
            return text;
        }

        private void WriteCurrentProfile(string profileName)
        {
            File.WriteAllText(_currentFile, profileName + Environment.NewLine, Encoding.UTF8);
        }

        private void WritePendingProfile(string profileName)
        {
            File.WriteAllText(_pendingFile, profileName + Environment.NewLine, Encoding.UTF8);
        }

        private void WritePendingPreviousProfile(string profileName)
        {
            if (string.IsNullOrWhiteSpace(profileName))
            {
                TryDeleteFile(_pendingPrevProfileFile);
                return;
            }
            File.WriteAllText(_pendingPrevProfileFile, profileName.Trim() + Environment.NewLine, Encoding.UTF8);
        }

        private void WritePendingPreviousFingerprint(string fingerprint)
        {
            if (string.IsNullOrWhiteSpace(fingerprint))
            {
                TryDeleteFile(_pendingPrevFingerprintFile);
                return;
            }
            File.WriteAllText(_pendingPrevFingerprintFile, fingerprint.Trim() + Environment.NewLine, Encoding.UTF8);
        }

        private void ClearPendingState()
        {
            TryDeleteFile(_pendingFile);
            TryDeleteFile(_pendingPrevProfileFile);
            TryDeleteFile(_pendingPrevFingerprintFile);
        }

        private void TryDeleteFile(string path)
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }

        private bool SessionSnapshotHasData(string rootDir)
        {
            if (string.IsNullOrWhiteSpace(rootDir) || !Directory.Exists(rootDir))
            {
                return false;
            }

            foreach (var item in _managedBrowserSessionItems)
            {
                var path = Path.Combine(rootDir, item);
                if (File.Exists(path) || Directory.Exists(path))
                {
                    return true;
                }
            }
            return false;
        }

        private string GetCodexSessionPath()
        {
            var candidates = new List<string>();
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            if (!string.IsNullOrWhiteSpace(appData))
            {
                candidates.Add(Path.Combine(appData, "Codex"));
            }

            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (!string.IsNullOrWhiteSpace(localAppData))
            {
                candidates.Add(Path.Combine(localAppData, @"Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Roaming\Codex"));
                candidates.Add(Path.Combine(localAppData, "Codex"));
            }

            candidates = candidates.Distinct(StringComparer.OrdinalIgnoreCase).ToList();

            var scored = new List<Tuple<string, int>>();
            foreach (var candidate in candidates)
            {
                if (!Directory.Exists(candidate))
                {
                    continue;
                }

                var score = 0;
                foreach (var item in _managedBrowserSessionItems)
                {
                    var path = Path.Combine(candidate, item);
                    if (File.Exists(path) || Directory.Exists(path))
                    {
                        score++;
                    }
                }
                scored.Add(Tuple.Create(candidate, score));
            }

            if (scored.Count > 0)
            {
                return scored
                    .OrderByDescending(x => x.Item2)
                    .ThenBy(x => x.Item1, StringComparer.OrdinalIgnoreCase)
                    .First()
                    .Item1;
            }

            return candidates.FirstOrDefault() ?? Path.Combine(_homeDir, "AppData", "Roaming", "Codex");
        }

        private void CopyFileReplace(string source, string target)
        {
            var targetDir = Path.GetDirectoryName(target);
            if (!string.IsNullOrEmpty(targetDir))
            {
                Directory.CreateDirectory(targetDir);
            }
            File.Copy(source, target, true);
        }

        private void CopyDirectoryReplace(string sourceDir, string targetDir)
        {
            if (Directory.Exists(targetDir))
            {
                Directory.Delete(targetDir, true);
            }
            Directory.CreateDirectory(targetDir);

            foreach (var file in Directory.GetFiles(sourceDir))
            {
                var name = Path.GetFileName(file);
                if (string.IsNullOrEmpty(name))
                {
                    continue;
                }
                File.Copy(file, Path.Combine(targetDir, name), true);
            }

            foreach (var dir in Directory.GetDirectories(sourceDir))
            {
                var name = Path.GetFileName(dir);
                if (string.IsNullOrEmpty(name))
                {
                    continue;
                }
                CopyDirectoryReplace(dir, Path.Combine(targetDir, name));
            }
        }

        private void CopyItemReplace(string source, string target)
        {
            if (File.Exists(source))
            {
                CopyFileReplace(source, target);
                return;
            }

            if (Directory.Exists(source))
            {
                CopyDirectoryReplace(source, target);
                return;
            }
        }

        private void StopCodex()
        {
            var processes = Process.GetProcessesByName("Codex");
            foreach (var process in processes)
            {
                try
                {
                    process.CloseMainWindow();
                }
                catch
                {
                }
            }

            var waitUntil = DateTime.UtcNow.AddSeconds(1.2);
            while (DateTime.UtcNow < waitUntil)
            {
                if (!IsCodexRunning())
                {
                    return;
                }
                System.Threading.Thread.Sleep(100);
            }

            processes = Process.GetProcessesByName("Codex");
            foreach (var process in processes)
            {
                try
                {
                    process.Kill();
                }
                catch
                {
                }
            }
            System.Threading.Thread.Sleep(300);
        }

        private bool IsCodexRunning()
        {
            return Process.GetProcessesByName("Codex").Length > 0;
        }

        private void StartCodex()
        {
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);

            var exeCandidates = new[]
            {
                Path.Combine(localAppData, @"Programs\Codex\Codex.exe"),
                Path.Combine(programFiles, @"Codex\Codex.exe"),
                Path.Combine(programFilesX86, @"Codex\Codex.exe")
            };

            foreach (var exePath in exeCandidates)
            {
                if (File.Exists(exePath))
                {
                    Process.Start(exePath);
                    return;
                }
            }

            try
            {
                var psi = new ProcessStartInfo("explorer.exe", @"shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App")
                {
                    UseShellExecute = true
                };
                Process.Start(psi);
            }
            catch
            {
            }
        }

        private void BackupCurrentAuthIfPresent()
        {
            if (!File.Exists(_authFile))
            {
                return;
            }

            EnsureDirectories();
            var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            var backupPath = Path.Combine(_backupsDir, "auth." + stamp + ".json");
            File.Copy(_authFile, backupPath, true);
        }

        private void ClearCurrentSession()
        {
            var sessionRoot = GetCodexSessionPath();
            if (Directory.Exists(sessionRoot))
            {
                foreach (var item in _managedBrowserSessionItems)
                {
                    var path = Path.Combine(sessionRoot, item);
                    if (File.Exists(path))
                    {
                        File.Delete(path);
                    }
                    else if (Directory.Exists(path))
                    {
                        Directory.Delete(path, true);
                    }
                }
            }

            if (File.Exists(_authFile))
            {
                File.Delete(_authFile);
            }
        }

        private bool HasUsableAuthFile()
        {
            if (!File.Exists(_authFile))
            {
                return false;
            }

            string json;
            try
            {
                json = File.ReadAllText(_authFile, Encoding.UTF8);
            }
            catch
            {
                return false;
            }

            if (Regex.IsMatch(json, "\"OPENAI_API_KEY\"\\s*:\\s*\"[^\"]+\""))
            {
                return true;
            }

            var tokenNames = new[] { "access_token", "refresh_token", "id_token" };
            return tokenNames.Any(token => Regex.IsMatch(json, "\"" + token + "\"\\s*:\\s*\"[^\"]+\""));
        }

        private double GetPendingAgeSeconds()
        {
            if (!File.Exists(_pendingFile))
            {
                return double.PositiveInfinity;
            }
            return (DateTime.Now - File.GetLastWriteTime(_pendingFile)).TotalSeconds;
        }

        private string GetCurrentSessionFingerprint()
        {
            var parts = new List<string>();

            if (File.Exists(_authFile))
            {
                var authHash = TrySha256File(_authFile);
                if (!string.IsNullOrEmpty(authHash))
                {
                    parts.Add("file:auth.json:" + authHash);
                }
            }

            var sessionRoot = GetCodexSessionPath();
            if (Directory.Exists(sessionRoot))
            {
                foreach (var item in _managedBrowserSessionItems)
                {
                    var itemPath = Path.Combine(sessionRoot, item);
                    HashItem(itemPath, "browser/" + item, parts);
                }
            }

            if (parts.Count == 0)
            {
                return string.Empty;
            }

            parts.Sort(StringComparer.Ordinal);
            var joined = string.Join("\n", parts);
            return ComputeSha256Text(joined);
        }

        private void HashItem(string path, string label, List<string> parts)
        {
            if (File.Exists(path))
            {
                var hash = TrySha256File(path);
                if (!string.IsNullOrEmpty(hash))
                {
                    parts.Add("file:" + label + ":" + hash);
                }
                return;
            }

            if (!Directory.Exists(path))
            {
                return;
            }

            var root = path.TrimEnd('\\');
            parts.Add("dir:" + label);
            foreach (var file in Directory.GetFiles(path, "*", SearchOption.AllDirectories).OrderBy(x => x, StringComparer.OrdinalIgnoreCase))
            {
                var hash = TrySha256File(file);
                if (string.IsNullOrEmpty(hash))
                {
                    continue;
                }
                var rel = file.Substring(root.Length).TrimStart('\\');
                parts.Add("file:" + label + "/" + rel.Replace('\\', '/') + ":" + hash);
            }
        }

        private string TrySha256File(string path)
        {
            try
            {
                using (var stream = File.OpenRead(path))
                using (var sha = SHA256.Create())
                {
                    var hash = sha.ComputeHash(stream);
                    return BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
                }
            }
            catch
            {
                return string.Empty;
            }
        }

        private string ComputeSha256Text(string text)
        {
            using (var sha = SHA256.Create())
            {
                var bytes = Encoding.UTF8.GetBytes(text);
                var hash = sha.ComputeHash(bytes);
                return BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
            }
        }

        private string ParseEmailFromAuth(string authPath)
        {
            if (!File.Exists(authPath))
            {
                return string.Empty;
            }

            string json;
            try
            {
                json = File.ReadAllText(authPath, Encoding.UTF8);
            }
            catch
            {
                return string.Empty;
            }

            var directMatch = Regex.Match(json, "\"email\"\\s*:\\s*\"([^\"]+)\"");
            if (directMatch.Success)
            {
                return directMatch.Groups[1].Value;
            }

            var tokenMatch = Regex.Match(json, "\"id_token\"\\s*:\\s*\"([^\"]+)\"");
            if (!tokenMatch.Success)
            {
                return string.Empty;
            }

            var token = tokenMatch.Groups[1].Value;
            var parts = token.Split('.');
            if (parts.Length < 2)
            {
                return string.Empty;
            }

            string payloadJson;
            try
            {
                payloadJson = Encoding.UTF8.GetString(Base64UrlDecode(parts[1]));
            }
            catch
            {
                return string.Empty;
            }

            var payloadMatch = Regex.Match(payloadJson, "\"email\"\\s*:\\s*\"([^\"]+)\"");
            return payloadMatch.Success ? payloadMatch.Groups[1].Value : string.Empty;
        }

        private byte[] Base64UrlDecode(string input)
        {
            var output = input.Replace('-', '+').Replace('_', '/');
            switch (output.Length % 4)
            {
                case 2:
                    output += "==";
                    break;
                case 3:
                    output += "=";
                    break;
            }
            return Convert.FromBase64String(output);
        }

        private void Log(string message)
        {
            try
            {
                EnsureDirectories();
                var stamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
                File.AppendAllText(_logFile, "[" + stamp + "] " + message + Environment.NewLine, Encoding.UTF8);
            }
            catch
            {
            }
        }
    }

    internal sealed class MainForm : Form
    {
        private readonly SwitcherService _service;
        private readonly Font _titleFont = new Font("Segoe UI Semibold", 16f, FontStyle.Bold);
        private readonly Font _headingFont = new Font("Segoe UI Semibold", 12f, FontStyle.Bold);
        private readonly Font _bodyFont = new Font("Segoe UI", 10f, FontStyle.Regular);
        private readonly Color _appBack = Color.FromArgb(24, 24, 24);
        private readonly Color _surface = Color.FromArgb(35, 35, 35);
        private readonly Color _surfaceAlt = Color.FromArgb(45, 45, 45);
        private readonly Color _border = Color.FromArgb(57, 57, 57);
        private readonly Color _text = Color.FromArgb(242, 242, 242);
        private readonly Color _muted = Color.FromArgb(172, 172, 172);
        private readonly Color _active = Color.FromArgb(35, 72, 54);
        private readonly Color _accent = Color.FromArgb(74, 144, 226);
        private readonly Color _danger = Color.FromArgb(196, 63, 63);
        private readonly Color _titleBarLike = Color.FromArgb(10, 10, 10);

        private readonly TextBox _profileNameBox = new TextBox();
        private readonly TextBox _searchBox = new TextBox();
        private readonly Label _titleLabel = new Label();
        private readonly Label _versionLabel = new Label();
        private readonly Label _languageLabel = new Label();
        private readonly Label _profilesTitle = new Label();
        private readonly Label _totalLabel = new Label();
        private readonly Label _addAccountTitle = new Label();
        private readonly Label _addAccountHint = new Label();
        private readonly Label _detailsTitle = new Label();
        private readonly Label _pendingLabel = new Label();
        private readonly Label _statusLabel = new Label();
        private readonly ListBox _profileList = new ListBox();
        private readonly Label _nameValue = new Label();
        private readonly Label _stateValue = new Label();
        private readonly Label _savedValue = new Label();
        private readonly Label _contentValue = new Label();
        private readonly Label _pathValue = new Label();
        private readonly Label _emailValue = new Label();
        private readonly RoundedButton _langEnButton = new RoundedButton();
        private readonly RoundedButton _langRuButton = new RoundedButton();
        private readonly Dictionary<string, Label> _detailLabels = new Dictionary<string, Label>();
        private readonly Timer _pollTimer = new Timer();
        private readonly Font _listNameFont = new Font("Segoe UI Semibold", 10.5f, FontStyle.Bold);
        private readonly Font _listMetaFont = new Font("Segoe UI", 8.8f, FontStyle.Regular);

        private List<ProfileInfo> _profiles = new List<ProfileInfo>();
        private List<ProfileInfo> _visibleProfiles = new List<ProfileInfo>();
        private string _language = "EN";
        private bool _busy;
        private int _profileItemHeight;

        public MainForm()
        {
            _service = new SwitcherService();
            _language = _service.ReadLanguage();

            Text = "Codex Account Switcher";
            StartPosition = FormStartPosition.CenterScreen;
            AutoScaleMode = AutoScaleMode.Dpi;
            MinimumSize = new Size(1240, 780);
            Size = new Size(1280, 820);
            Font = _bodyFont;
            BackColor = _appBack;
            TryApplyAppIcon();

            BuildUi();
            WireEvents();

            _pollTimer.Interval = 2000;
            _pollTimer.Tick += PollTimerOnTick;
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            NativeMethods.ApplyDarkTitleBar(Handle);
        }

        private void TryApplyAppIcon()
        {
            try
            {
                var exePath = Application.ExecutablePath;
                var extracted = Icon.ExtractAssociatedIcon(exePath);
                if (extracted != null)
                {
                    Icon = (Icon)extracted.Clone();
                    extracted.Dispose();
                }
            }
            catch
            {
            }
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            _profileNameBox.Text = _service.SuggestedProfileName();
            RefreshProfiles(null);
            SetStatus(T("Ready.", "Готово."));
            _pollTimer.Start();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            _pollTimer.Stop();
            base.OnFormClosing(e);
        }

        private void BuildUi()
        {
            var root = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 2,
                RowCount = 3,
                Padding = new Padding(18),
                BackColor = _appBack
            };
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 360f));
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 76f));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 52f));

            var header = BuildHeader();
            var left = BuildLeftPanel();
            var right = BuildRightPanel();
            var statusPanel = BuildStatusPanel();

            root.Controls.Add(header, 0, 0);
            root.SetColumnSpan(header, 2);
            root.Controls.Add(left, 0, 1);
            root.Controls.Add(right, 1, 1);
            root.Controls.Add(statusPanel, 0, 2);
            root.SetColumnSpan(statusPanel, 2);

            Controls.Add(root);
        }

        private Control BuildHeader()
        {
            var panel = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 2,
                BackColor = _appBack,
                Margin = new Padding(0, 0, 0, 10)
            };
            panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            panel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

            var titleFlow = new FlowLayoutPanel
            {
                Dock = DockStyle.Fill,
                FlowDirection = FlowDirection.LeftToRight,
                WrapContents = false,
                BackColor = _appBack,
                Padding = new Padding(2, 12, 0, 0)
            };

            var logo = new PictureBox
            {
                Width = 30,
                Height = 30,
                SizeMode = PictureBoxSizeMode.Zoom,
                BackColor = _appBack,
                Margin = new Padding(0, 0, 12, 0)
            };
            logo.Image = LoadLogoImage();

            _titleLabel.Text = "Codex Account Switcher";
            _titleLabel.Font = _titleFont;
            _titleLabel.ForeColor = _text;
            _titleLabel.AutoSize = true;
            _titleLabel.Margin = new Padding(0, 1, 10, 0);

            _versionLabel.Text = "v1.0.2";
            _versionLabel.Font = new Font("Segoe UI Semibold", 10f, FontStyle.Bold);
            _versionLabel.ForeColor = _muted;
            _versionLabel.AutoSize = true;
            _versionLabel.Margin = new Padding(0, 8, 0, 0);

            titleFlow.Controls.Add(logo);
            titleFlow.Controls.Add(_titleLabel);
            titleFlow.Controls.Add(_versionLabel);

            var actions = new FlowLayoutPanel
            {
                Dock = DockStyle.Right,
                FlowDirection = FlowDirection.LeftToRight,
                WrapContents = false,
                BackColor = _appBack,
                Padding = new Padding(0, 13, 0, 0),
                AutoSize = true,
                AutoSizeMode = AutoSizeMode.GrowAndShrink
            };

            _languageLabel.AutoSize = true;
            _languageLabel.ForeColor = _muted;
            _languageLabel.Font = new Font("Segoe UI Semibold", 9.5f, FontStyle.Bold);
            _languageLabel.Margin = new Padding(0, 6, 8, 0);

            ConfigureSegmentButton(_langEnButton, "EN");
            ConfigureSegmentButton(_langRuButton, "RU");
            _langEnButton.Name = "btnLangEn";
            _langRuButton.Name = "btnLangRu";
            _langEnButton.Width = 44;
            _langRuButton.Width = 44;
            _langEnButton.Margin = new Padding(0, 0, 0, 0);
            _langRuButton.Margin = new Padding(0, 0, 16, 0);

            var telegramButton = CreateSecondaryButton("Telegram");
            telegramButton.Name = "btnTelegram";
            telegramButton.Width = 116;
            telegramButton.IconKind = ButtonIconKind.Telegram;
            var githubButton = CreateSecondaryButton("GitHub");
            githubButton.Name = "btnGitHub";
            githubButton.Width = 102;
            githubButton.IconKind = ButtonIconKind.GitHub;
            var refreshButton = CreateSecondaryButton("Refresh");
            refreshButton.Name = "btnRefresh";
            refreshButton.Width = 112;
            refreshButton.IconKind = ButtonIconKind.Refresh;
            var folderButton = CreateSecondaryButton("Folder");
            folderButton.Name = "btnOpenFolder";
            folderButton.Width = 104;
            folderButton.IconKind = ButtonIconKind.Folder;

            actions.Controls.Add(_languageLabel);
            actions.Controls.Add(_langEnButton);
            actions.Controls.Add(_langRuButton);
            actions.Controls.Add(telegramButton);
            actions.Controls.Add(githubButton);
            actions.Controls.Add(refreshButton);
            actions.Controls.Add(folderButton);

            panel.Controls.Add(titleFlow, 0, 0);
            panel.Controls.Add(actions, 1, 0);
            return panel;
        }

        private Image LoadLogoImage()
        {
            try
            {
                var exeDir = Path.GetDirectoryName(Application.ExecutablePath);
                if (!string.IsNullOrEmpty(exeDir))
                {
                    var assetPath = Path.GetFullPath(Path.Combine(exeDir, "..", "assets", "AppIcon-1024.png"));
                    if (File.Exists(assetPath))
                    {
                        return Image.FromFile(assetPath);
                    }
                }
            }
            catch
            {
            }

            if (Icon != null)
            {
                return new Icon(Icon, 64, 64).ToBitmap();
            }
            return null;
        }

        private Control BuildLeftPanel()
        {
            var card = CreateCardPanel();

            var topLine = new TableLayoutPanel
            {
                Dock = DockStyle.Top,
                Height = 34,
                ColumnCount = 2,
                BackColor = _surface
            };
            topLine.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            topLine.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 90f));

            _profilesTitle.Font = _headingFont;
            _profilesTitle.ForeColor = _text;
            _profilesTitle.Dock = DockStyle.Fill;
            _profilesTitle.TextAlign = ContentAlignment.MiddleLeft;

            _totalLabel.Font = new Font("Segoe UI Semibold", 9f, FontStyle.Bold);
            _totalLabel.ForeColor = _muted;
            _totalLabel.Dock = DockStyle.Fill;
            _totalLabel.TextAlign = ContentAlignment.MiddleRight;

            topLine.Controls.Add(_profilesTitle, 0, 0);
            topLine.Controls.Add(_totalLabel, 1, 0);

            var searchWrap = new Panel
            {
                Dock = DockStyle.Top,
                Height = 34,
                Margin = new Padding(0, 0, 0, 10),
                Padding = new Padding(8, 6, 8, 6),
                BackColor = _surfaceAlt
            };
            searchWrap.Paint += (s, e) =>
            {
                using (var pen = new Pen(_border))
                {
                    e.Graphics.DrawRectangle(pen, 0, 0, searchWrap.Width - 1, searchWrap.Height - 1);
                }
            };

            var searchIcon = new PictureBox
            {
                Dock = DockStyle.Left,
                Width = 16,
                BackColor = _surfaceAlt,
                Cursor = Cursors.IBeam
            };
            searchIcon.Paint += DrawSearchIcon;
            searchIcon.Click += (s, e) => _searchBox.Focus();

            _searchBox.Dock = DockStyle.Fill;
            _searchBox.Height = 22;
            _searchBox.Font = _bodyFont;
            _searchBox.Margin = new Padding(6, 0, 0, 0);
            _searchBox.BackColor = _surfaceAlt;
            _searchBox.ForeColor = _text;
            _searchBox.BorderStyle = BorderStyle.None;

            searchWrap.Controls.Add(_searchBox);
            searchWrap.Controls.Add(searchIcon);

            ConfigureProfileList();

            card.Controls.Add(_profileList);
            card.Controls.Add(searchWrap);
            card.Controls.Add(topLine);

            return card;
        }

        private Control BuildRightPanel()
        {
            var card = CreateCardPanel();
            var layout = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = 4,
                BackColor = _surface
            };
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 132f));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32f));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 56f));

            var addPanel = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 2,
                BackColor = _surface,
                Padding = new Padding(0, 0, 0, 14)
            };
            addPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            addPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150f));

            _addAccountTitle.Font = _headingFont;
            _addAccountTitle.ForeColor = _text;
            _addAccountTitle.Dock = DockStyle.Top;
            _addAccountTitle.Height = 30;

            _profileNameBox.Dock = DockStyle.Top;
            _profileNameBox.Font = new Font("Segoe UI", 10.5f, FontStyle.Regular);
            _profileNameBox.Height = 30;
            _profileNameBox.BackColor = _surfaceAlt;
            _profileNameBox.ForeColor = _text;
            _profileNameBox.BorderStyle = BorderStyle.FixedSingle;

            _addAccountHint.Dock = DockStyle.Top;
            _addAccountHint.Height = 36;
            _addAccountHint.ForeColor = _muted;
            _addAccountHint.Font = new Font("Segoe UI", 8.8f, FontStyle.Regular);

            var inputStack = new Panel
            {
                Dock = DockStyle.Fill,
                BackColor = _surface
            };
            inputStack.Controls.Add(_addAccountHint);
            inputStack.Controls.Add(_profileNameBox);
            inputStack.Controls.Add(_addAccountTitle);

            var loginButton = CreatePrimaryButton("Login");
            loginButton.Name = "btnLogin";
            loginButton.Dock = DockStyle.Top;
            loginButton.Height = 34;
            loginButton.Margin = new Padding(10, 30, 0, 0);

            addPanel.Controls.Add(inputStack, 0, 0);
            addPanel.Controls.Add(loginButton, 1, 0);

            _pendingLabel.Dock = DockStyle.Top;
            _pendingLabel.Height = 30;
            _pendingLabel.ForeColor = _muted;
            _pendingLabel.TextAlign = ContentAlignment.MiddleLeft;

            var detailPanel = new Panel
            {
                Dock = DockStyle.Fill,
                BackColor = _surface,
                AutoScroll = true,
                Padding = new Padding(0, 0, 14, 12)
            };

            _detailsTitle.Font = _headingFont;
            _detailsTitle.ForeColor = _text;
            _detailsTitle.Dock = DockStyle.Top;
            _detailsTitle.Height = 38;
            _detailsTitle.TextAlign = ContentAlignment.MiddleLeft;

            var details = new TableLayoutPanel
            {
                Dock = DockStyle.Top,
                ColumnCount = 2,
                AutoSize = true,
                AutoSizeMode = AutoSizeMode.GrowAndShrink,
                Padding = new Padding(0, 4, 0, 12),
                BackColor = _surface
            };
            details.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 128));
            details.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));

            AddDetailRow(details, 0, "Name:", _nameValue);
            AddDetailRow(details, 1, "State:", _stateValue);
            AddDetailRow(details, 2, "Saved:", _savedValue);
            AddDetailRow(details, 3, "Contents:", _contentValue);
            AddDetailRow(details, 4, "Path:", _pathValue);
            AddDetailRow(details, 5, "Email:", _emailValue);
            detailPanel.Controls.Add(details);
            detailPanel.Controls.Add(_detailsTitle);

            var buttons = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 3,
                RowCount = 1,
                Padding = new Padding(0, 4, 0, 0),
                BackColor = _surface
            };
            for (var i = 0; i < 3; i++)
            {
                buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33.333f));
            }
            buttons.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));

            var switchButton = CreatePrimaryButton("Switch");
            switchButton.Name = "btnSwitch";
            var renameButton = CreateSecondaryButton("Rename");
            renameButton.Name = "btnRename";
            var deleteButton = CreateDangerButton("Delete");
            deleteButton.Name = "btnDelete";
            foreach (var button in new[] { switchButton, renameButton, deleteButton })
            {
                button.Dock = DockStyle.Fill;
            }

            buttons.Controls.Add(switchButton, 0, 0);
            buttons.Controls.Add(renameButton, 1, 0);
            buttons.Controls.Add(deleteButton, 2, 0);

            layout.Controls.Add(addPanel, 0, 0);
            layout.Controls.Add(_pendingLabel, 0, 1);
            layout.Controls.Add(detailPanel, 0, 2);
            layout.Controls.Add(buttons, 0, 3);

            card.Controls.Add(layout);

            return card;
        }

        private Control BuildStatusPanel()
        {
            var panel = new Panel
            {
                Dock = DockStyle.Fill,
                BackColor = _titleBarLike,
                Padding = new Padding(12, 10, 12, 10),
                Margin = new Padding(0)
            };

            _statusLabel.Dock = DockStyle.Fill;
            _statusLabel.ForeColor = _muted;
            _statusLabel.TextAlign = ContentAlignment.MiddleLeft;
            _statusLabel.Margin = new Padding(0);
            _statusLabel.Text = T("Ready.", "Готово.");

            panel.Controls.Add(_statusLabel);
            return panel;
        }

        private void ConfigureProfileList()
        {
            _profileList.Dock = DockStyle.Fill;
            _profileList.BackColor = _surface;
            _profileList.ForeColor = _text;
            _profileList.BorderStyle = BorderStyle.None;
            _profileList.DrawMode = DrawMode.OwnerDrawVariable;
            _profileItemHeight = GetProfileItemHeight();
            _profileList.ItemHeight = _profileItemHeight;
            _profileList.IntegralHeight = false;
            _profileList.Margin = new Padding(0);
            _profileList.MeasureItem += (s, e) => { e.ItemHeight = _profileItemHeight; };
            _profileList.DrawItem += DrawProfileItem;
        }

        private int GetProfileItemHeight()
        {
            var contentHeight = _listNameFont.Height + _bodyFont.Height + _listMetaFont.Height;
            return Math.Max(84, contentHeight + 28);
        }

        private void DrawSearchIcon(object sender, PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;

            using (var pen = new Pen(_muted, 1.6f))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                var circle = new RectangleF(1.5f, 1.5f, 8.2f, 8.2f);
                e.Graphics.DrawEllipse(pen, circle);
                e.Graphics.DrawLine(pen, 8.8f, 8.8f, 13.8f, 13.8f);
            }
        }

        private void DrawProfileItem(object sender, DrawItemEventArgs e)
        {
            if (e.Index < 0 || e.Index >= _visibleProfiles.Count)
            {
                return;
            }

            var profile = _visibleProfiles[e.Index];
            var selected = (e.State & DrawItemState.Selected) == DrawItemState.Selected;
            var row = e.Bounds;
            if (row.Height <= 2)
            {
                return;
            }

            var back = selected ? _surfaceAlt : _surface;
            if (profile.IsActive)
            {
                back = selected ? Color.FromArgb(44, 92, 68) : _active;
            }

            using (var brush = new SolidBrush(back))
            {
                e.Graphics.FillRectangle(brush, row);
            }

            using (var pen = new Pen(_border))
            {
                e.Graphics.DrawLine(pen, row.Left + 8, row.Bottom - 1, row.Right - 8, row.Bottom - 1);
            }

            var left = row.Left + 12;
            var top = row.Top + 8;
            var width = row.Width - 24;
            var lineGap = 3;
            var nameHeight = _listNameFont.Height + 2;
            var emailHeight = _bodyFont.Height + 1;
            var metaHeight = _listMetaFont.Height + 1;
            var nameRect = new Rectangle(left, top, width - 34, nameHeight);
            var emailRect = new Rectangle(left, top + nameHeight + lineGap, width, emailHeight);
            var metaRect = new Rectangle(left, top + nameHeight + emailHeight + (lineGap * 2), width, metaHeight);

            TextRenderer.DrawText(
                e.Graphics,
                profile.Name,
                _listNameFont,
                nameRect,
                _text,
                TextFormatFlags.EndEllipsis | TextFormatFlags.Left | TextFormatFlags.VerticalCenter);

            var email = string.IsNullOrEmpty(profile.Email) ? T("No email captured", "Почта не найдена") : profile.Email;
            TextRenderer.DrawText(
                e.Graphics,
                email,
                _bodyFont,
                emailRect,
                _muted,
                TextFormatFlags.EndEllipsis | TextFormatFlags.Left | TextFormatFlags.VerticalCenter);

            var saved = profile.ModifiedAt.HasValue
                ? profile.ModifiedAt.Value.ToString("yyyy-MM-dd HH:mm")
                : T("date unknown", "дата неизвестна");
            var status = profile.IsActive ? T("Active", "Активен") : T("Saved", "Сохранён");
            TextRenderer.DrawText(
                e.Graphics,
                status + " · " + saved,
                _listMetaFont,
                metaRect,
                _muted,
                TextFormatFlags.EndEllipsis | TextFormatFlags.Left | TextFormatFlags.VerticalCenter);

            if (profile.IsActive)
            {
                using (var brush = new SolidBrush(Color.FromArgb(102, 210, 132)))
                {
                    e.Graphics.FillEllipse(brush, row.Right - 28, row.Top + 14, 10, 10);
                }
            }
        }

        private void WireEvents()
        {
            var loginButton = FindButton("btnLogin");
            var switchButton = FindButton("btnSwitch");
            var renameButton = FindButton("btnRename");
            var deleteButton = FindButton("btnDelete");
            var refreshButton = FindButton("btnRefresh");
            var openFolderButton = FindButton("btnOpenFolder");
            var telegramButton = FindButton("btnTelegram");
            var githubButton = FindButton("btnGitHub");

            loginButton.Click += (s, e) => RunSafe(() =>
            {
                _service.StartPendingLoginFlow(_profileNameBox.Text);
                SetStatus(T("Waiting for login in Codex.", "Ожидание входа в Codex."));
                RefreshProfiles(null);
            });

            switchButton.Click += (s, e) => RunSafe(() =>
            {
                var selected = RequireSelectedProfile();
                _service.SwitchToProfile(selected.Name);
                RefreshProfiles(selected.Name);
                SetStatus(T("Switched to '" + selected.Name + "'.", "Переключено на '" + selected.Name + "'."));
            });

            renameButton.Click += (s, e) => RunSafe(() =>
            {
                var selected = RequireSelectedProfile();
                var newName = InputDialog.Show(
                    this,
                    T("Rename Profile", "Переименование профиля"),
                    T("New name:", "Новое имя:"),
                    selected.Name,
                    string.Equals(_language, "RU", StringComparison.OrdinalIgnoreCase));
                if (newName == null)
                {
                    return;
                }
                _service.RenameProfile(selected.Name, newName);
                RefreshProfiles(newName);
                SetStatus(T("Renamed to '" + newName + "'.", "Переименовано в '" + newName + "'."));
            });

            deleteButton.Click += (s, e) => RunSafe(() =>
            {
                var selected = RequireSelectedProfile();
                if (!ConfirmDeleteProfile(selected.Name))
                {
                    return;
                }
                _service.DeleteProfile(selected.Name);
                RefreshProfiles(null);
                SetStatus(T("Deleted profile '" + selected.Name + "'.", "Профиль '" + selected.Name + "' удалён."));
            });

            refreshButton.Click += (s, e) => RunSafe(() =>
            {
                var selected = GetSelectedProfile();
                RefreshProfiles(selected != null ? selected.Name : null);
                SetStatus(T("Refreshed.", "Обновлено."));
            });

            openFolderButton.Click += (s, e) => RunSafe(() =>
            {
                Process.Start("explorer.exe", _service.ProfilesDirPath);
                SetStatus(T("Opened profiles folder.", "Открыта папка профилей."));
            });

            telegramButton.Click += (s, e) => Process.Start("https://t.me/b_tier");
            githubButton.Click += (s, e) => Process.Start("https://github.com/goutor/CAS");

            _langEnButton.Click += (s, e) => SetLanguage("EN");
            _langRuButton.Click += (s, e) => SetLanguage("RU");
            _searchBox.TextChanged += (s, e) => RefreshProfiles(GetSelectedProfile() != null ? GetSelectedProfile().Name : null);

            _profileList.SelectedIndexChanged += (s, e) => UpdateDetails();
            _profileList.DoubleClick += (s, e) => RunSafe(() =>
            {
                var selected = RequireSelectedProfile();
                _service.SwitchToProfile(selected.Name);
                RefreshProfiles(selected.Name);
                SetStatus(T("Switched to '" + selected.Name + "'.", "Переключено на '" + selected.Name + "'."));
            });

            ApplyLanguage();
        }

        private void PollTimerOnTick(object sender, EventArgs e)
        {
            if (_busy)
            {
                return;
            }

            try
            {
                var state = _service.PollPendingLoginFlow();
                if (state == PendingPollState.Completed)
                {
                    var current = _service.ReadCurrentProfile();
                    RefreshProfiles(current);
                    SetStatus(T("New profile '" + current + "' saved after login.", "Новый профиль '" + current + "' сохранён после входа."));
                }
                else if (state == PendingPollState.Cancelled)
                {
                    RefreshProfiles(null);
                    SetStatus(T("Pending login cancelled.", "Ожидание входа отменено."));
                }
                else if (state == PendingPollState.Waiting)
                {
                    var pending = _service.ReadPendingProfile();
                    if (!string.IsNullOrEmpty(pending))
                    {
                        _pendingLabel.Text = T("Pending login: ", "Ожидание входа: ") + pending;
                    }
                }
                else
                {
                    _pendingLabel.Text = T("Pending login: none", "Ожидание входа: нет");
                }
            }
            catch (Exception ex)
            {
                SetStatus(T("Error: ", "Ошибка: ") + ex.Message);
            }
        }

        private void RunSafe(Action action)
        {
            if (_busy)
            {
                return;
            }

            try
            {
                _busy = true;
                Cursor = Cursors.WaitCursor;
                action();
            }
            catch (SwitcherException ex)
            {
                MessageBox.Show(this, ex.Message, "Codex Account Switcher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                SetStatus(T("Warning: ", "Предупреждение: ") + ex.Message);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "Codex Account Switcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
                SetStatus(T("Error: ", "Ошибка: ") + ex.Message);
            }
            finally
            {
                Cursor = Cursors.Default;
                _busy = false;
            }
        }

        private void RefreshProfiles(string preferredName)
        {
            _profiles = _service.GetProfiles();
            var filter = (_searchBox.Text ?? string.Empty).Trim();
            _visibleProfiles = _profiles
                .Where(profile =>
                    string.IsNullOrEmpty(filter) ||
                    profile.Name.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0 ||
                    (!string.IsNullOrEmpty(profile.Email) && profile.Email.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0))
                .ToList();

            _profileItemHeight = GetProfileItemHeight();
            _profileList.BeginUpdate();
            _profileList.Items.Clear();
            foreach (var profile in _visibleProfiles)
            {
                _profileList.Items.Add(profile.Name);
            }
            _profileList.EndUpdate();

            var pending = _service.ReadPendingProfile();
            _pendingLabel.Text = string.IsNullOrEmpty(pending)
                ? T("Pending login: none", "Ожидание входа: нет")
                : T("Pending login: ", "Ожидание входа: ") + pending;
            _totalLabel.Text = T("Total: ", "Всего: ") + _profiles.Count;

            SelectProfileInGrid(preferredName);
            UpdateDetails();
            _profileList.Invalidate();
        }

        private void SelectProfileInGrid(string preferredName)
        {
            if (_visibleProfiles.Count == 0)
            {
                return;
            }

            string target = preferredName;
            if (string.IsNullOrWhiteSpace(target))
            {
                target = _service.ReadCurrentProfile();
            }
            if (string.IsNullOrWhiteSpace(target) && _profiles.Count > 0)
            {
                target = _profiles[0].Name;
            }

            for (var i = 0; i < _visibleProfiles.Count; i++)
            {
                if (string.Equals(_visibleProfiles[i].Name, target, StringComparison.OrdinalIgnoreCase))
                {
                    _profileList.SelectedIndex = i;
                    return;
                }
            }

            _profileList.SelectedIndex = 0;
        }

        private void UpdateDetails()
        {
            var selected = GetSelectedProfile();
            if (selected == null)
            {
                _nameValue.Text = "-";
                _stateValue.Text = "-";
                _savedValue.Text = "-";
                _contentValue.Text = "-";
                _pathValue.Text = "-";
                _emailValue.Text = "-";
                return;
            }

            _nameValue.Text = selected.Name;
            _stateValue.Text = selected.IsActive ? T("Active", "Активен") : T("Saved", "Сохранён");
            _savedValue.Text = selected.ModifiedAt.HasValue
                ? selected.ModifiedAt.Value.ToString("yyyy-MM-dd HH:mm:ss")
                : T("Unknown", "Неизвестно");
            _contentValue.Text = selected.HasSession && selected.HasAuth
                ? T("Browser session + CLI auth.json", "Сессия браузера + CLI auth.json")
                : selected.HasSession
                    ? T("Browser session", "Сессия браузера")
                    : "CLI auth.json";
            _pathValue.Text = selected.DirectoryPath;
            _emailValue.Text = string.IsNullOrEmpty(selected.Email) ? "-" : selected.Email;
        }

        private ProfileInfo GetSelectedProfile()
        {
            if (_profileList.SelectedIndex < 0 || _profileList.SelectedIndex >= _visibleProfiles.Count)
            {
                return null;
            }
            return _visibleProfiles[_profileList.SelectedIndex];
        }

        private ProfileInfo RequireSelectedProfile()
        {
            var selected = GetSelectedProfile();
            if (selected == null)
            {
                throw new SwitcherException(T("Select a profile first.", "Сначала выберите профиль."));
            }
            return selected;
        }

        private void SetStatus(string text)
        {
            _statusLabel.Text = text;
        }

        private bool ConfirmDeleteProfile(string profileName)
        {
            var answer = MessageBox.Show(
                this,
                T(
                    "Delete profile '" + profileName + "'?\n\nThis action cannot be undone.",
                    "Удалить профиль '" + profileName + "'?\n\nЭто действие нельзя отменить."),
                T("Confirm Delete", "Подтвердите удаление"),
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2);
            return answer == DialogResult.Yes;
        }

        private string T(string en, string ru)
        {
            return string.Equals(_language, "RU", StringComparison.OrdinalIgnoreCase) ? ru : en;
        }

        private void SetLanguage(string language)
        {
            _language = string.Equals(language, "RU", StringComparison.OrdinalIgnoreCase) ? "RU" : "EN";
            _service.WriteLanguage(_language);
            ApplyLanguage();
            RefreshProfiles(GetSelectedProfile() != null ? GetSelectedProfile().Name : null);
        }

        private void ApplyLanguage()
        {
            _languageLabel.Text = T("Language", "Язык");
            _profilesTitle.Text = T("Profiles", "Профили");
            _addAccountTitle.Text = T("Add account", "Добавить аккаунт");
            _detailsTitle.Text = T("Profile Details", "Детали профиля");
            _addAccountHint.Text = T(
                "Login opens Codex without the previous session. Current account is saved first.",
                "Вход откроет Codex без старой сессии. Текущий аккаунт сначала сохраняется.");

            FindButton("btnLogin").Text = T("Login", "Войти");
            FindButton("btnSwitch").Text = T("Switch", "Переключить");
            FindButton("btnRename").Text = T("Rename", "Переименовать");
            FindButton("btnDelete").Text = T("Delete", "Удалить");
            FindButton("btnRefresh").Text = T("Refresh", "Обновить");
            FindButton("btnOpenFolder").Text = T("Folder", "Папка");
            FindButton("btnRefresh").Width = string.Equals(_language, "RU", StringComparison.OrdinalIgnoreCase) ? 126 : 112;
            FindButton("btnOpenFolder").Width = string.Equals(_language, "RU", StringComparison.OrdinalIgnoreCase) ? 108 : 104;

            SetDetailLabel("Name:", T("Name:", "Имя:"));
            SetDetailLabel("State:", T("State:", "Статус:"));
            SetDetailLabel("Saved:", T("Saved:", "Сохранено:"));
            SetDetailLabel("Contents:", T("Contents:", "Состав:"));
            SetDetailLabel("Path:", T("Path:", "Путь:"));
            SetDetailLabel("Email:", T("Email:", "Почта:"));

            _langEnButton.Selected = string.Equals(_language, "EN", StringComparison.OrdinalIgnoreCase);
            _langRuButton.Selected = string.Equals(_language, "RU", StringComparison.OrdinalIgnoreCase);
            _langEnButton.Invalidate();
            _langRuButton.Invalidate();

            _totalLabel.Text = T("Total: ", "Всего: ") + _profiles.Count;
            var pending = _service.ReadPendingProfile();
            _pendingLabel.Text = string.IsNullOrEmpty(pending)
                ? T("Pending login: none", "Ожидание входа: нет")
                : T("Pending login: ", "Ожидание входа: ") + pending;
            NativeMethods.SetCueBanner(_searchBox, T("Search by name or email", "Поиск по названию или почте"));
            UpdateDetails();
        }

        private void SetDetailLabel(string key, string value)
        {
            Label label;
            if (_detailLabels.TryGetValue(key, out label))
            {
                label.Text = value;
            }
        }

        private void ConfigureSegmentButton(RoundedButton button, string text)
        {
            button.Text = text;
            button.Height = 30;
            button.Font = new Font("Segoe UI Semibold", 9f, FontStyle.Bold);
            button.BackColor = _surfaceAlt;
            button.ForeColor = _text;
            button.BorderColor = _border;
            button.HoverBackColor = Color.FromArgb(58, 58, 58);
            button.SelectedBackColor = Color.FromArgb(67, 67, 67);
            button.SelectedBorderColor = _border;
            button.Radius = 14;
            button.Cursor = Cursors.Hand;
        }

        private Panel CreateCardPanel()
        {
            return new Panel
            {
                Dock = DockStyle.Fill,
                BackColor = _surface,
                BorderStyle = BorderStyle.FixedSingle,
                Padding = new Padding(18),
                Margin = new Padding(0, 0, 14, 0)
            };
        }

        private RoundedButton CreatePrimaryButton(string text)
        {
            var button = new RoundedButton
            {
                Text = text,
                Font = new Font("Segoe UI Semibold", 10f, FontStyle.Bold),
                Height = 36,
                BackColor = _surfaceAlt,
                ForeColor = _text,
                Cursor = Cursors.Hand,
                Margin = new Padding(4, 4, 4, 4)
            };
            button.BorderColor = _accent;
            button.HoverBackColor = Color.FromArgb(55, 55, 55);
            button.Radius = 12;
            return button;
        }

        private RoundedButton CreateSecondaryButton(string text)
        {
            var button = new RoundedButton
            {
                Text = text,
                Font = new Font("Segoe UI", 10f, FontStyle.Regular),
                Height = 36,
                BackColor = Color.FromArgb(47, 47, 47),
                ForeColor = _text,
                Cursor = Cursors.Hand,
                Margin = new Padding(4, 4, 4, 4)
            };
            button.BorderColor = _border;
            button.HoverBackColor = Color.FromArgb(58, 58, 58);
            button.Radius = 12;
            return button;
        }

        private RoundedButton CreateDangerButton(string text)
        {
            var button = new RoundedButton
            {
                Text = text,
                Font = new Font("Segoe UI Semibold", 10f, FontStyle.Bold),
                Height = 36,
                BackColor = _danger,
                ForeColor = Color.White,
                Cursor = Cursors.Hand,
                Margin = new Padding(4, 4, 4, 4)
            };
            button.BorderColor = Color.FromArgb(214, 86, 86);
            button.HoverBackColor = Color.FromArgb(214, 74, 74);
            button.Radius = 12;
            return button;
        }

        private void AddDetailRow(TableLayoutPanel table, int row, string labelText, Label valueLabel)
        {
            table.RowStyles.Add(new RowStyle(SizeType.AutoSize));

            var label = new Label
            {
                Text = labelText,
                Font = new Font("Segoe UI Semibold", 10f, FontStyle.Bold),
                ForeColor = _muted,
                AutoSize = false,
                Width = 118,
                Height = 30,
                TextAlign = ContentAlignment.TopLeft,
                Margin = new Padding(0, 4, 8, 6)
            };
            valueLabel.AutoSize = true;
            valueLabel.MaximumSize = new Size(720, 0);
            valueLabel.ForeColor = _text;
            valueLabel.Margin = new Padding(0, 4, 0, 6);

            _detailLabels[labelText] = label;
            table.Controls.Add(label, 0, row);
            table.Controls.Add(valueLabel, 1, row);
        }

        private RoundedButton FindButton(string name)
        {
            return Controls
                .Find(name, true)
                .OfType<RoundedButton>()
                .First();
        }
    }

    internal sealed class RoundedButton : Control
    {
        private bool _hovered;
        private GraphicsPath _paintPath;

        public int Radius { get; set; }
        public Color BorderColor { get; set; }
        public Color HoverBackColor { get; set; }
        public Color SelectedBackColor { get; set; }
        public Color SelectedBorderColor { get; set; }
        public ButtonIconKind IconKind { get; set; }
        public int IconSize { get; set; }
        public int IconTextGap { get; set; }
        public bool Selected { get; set; }

        public RoundedButton()
        {
            Radius = 8;
            BorderColor = Color.FromArgb(57, 57, 57);
            HoverBackColor = Color.FromArgb(58, 58, 58);
            SelectedBackColor = Color.FromArgb(67, 67, 67);
            SelectedBorderColor = Color.FromArgb(57, 57, 57);
            IconKind = ButtonIconKind.None;
            IconSize = 12;
            IconTextGap = 7;
            TabStop = true;
            SetStyle(
                ControlStyles.UserPaint |
                ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer |
                ControlStyles.ResizeRedraw,
                true);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && _paintPath != null)
            {
                _paintPath.Dispose();
                _paintPath = null;
            }
            base.Dispose(disposing);
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            BuildPath();
            Invalidate();
        }

        protected override void OnParentChanged(EventArgs e)
        {
            base.OnParentChanged(e);
            Invalidate();
        }

        protected override void OnMouseEnter(EventArgs e)
        {
            _hovered = true;
            Invalidate();
            base.OnMouseEnter(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            _hovered = false;
            Invalidate();
            base.OnMouseLeave(e);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space)
            {
                OnClick(EventArgs.Empty);
                e.Handled = true;
            }
            base.OnKeyDown(e);
        }

        protected override void OnPaint(PaintEventArgs pevent)
        {
            pevent.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            pevent.Graphics.PixelOffsetMode = PixelOffsetMode.Half;
            pevent.Graphics.CompositingQuality = CompositingQuality.HighQuality;

            var rect = new Rectangle(0, 0, Width - 1, Height - 1);
            var back = Selected ? SelectedBackColor : (_hovered ? HoverBackColor : BackColor);
            var border = Selected ? SelectedBorderColor : BorderColor;

            using (var clearBrush = new SolidBrush(Parent != null ? Parent.BackColor : BackColor))
            {
                pevent.Graphics.FillRectangle(clearBrush, ClientRectangle);
            }

            using (var backBrush = new SolidBrush(back))
            {
                if (_paintPath == null)
                {
                    BuildPath();
                }

                if (_paintPath != null)
                {
                    pevent.Graphics.FillPath(backBrush, _paintPath);
                }
                else
                {
                    pevent.Graphics.FillRectangle(backBrush, rect);
                }
            }

            var borderRadius = Math.Max(1f, GetEffectiveRadius() - 0.5f);
            using (var borderPath = RoundedRect(new RectangleF(0.5f, 0.5f, Width - 2f, Height - 2f), borderRadius))
            using (var borderPen = new Pen(border, 1f))
            {
                borderPen.Alignment = PenAlignment.Inset;
                borderPen.LineJoin = LineJoin.Round;
                pevent.Graphics.DrawPath(borderPen, borderPath);
            }

            if (IconKind == ButtonIconKind.None)
            {
                TextRenderer.DrawText(
                    pevent.Graphics,
                    Text,
                    Font,
                    rect,
                    ForeColor,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis);
            }
            else
            {
                DrawIconAndText(pevent.Graphics, rect);
            }
        }

        private void BuildPath()
        {
            if (Width <= 1 || Height <= 1)
            {
                return;
            }

            if (_paintPath != null)
            {
                _paintPath.Dispose();
                _paintPath = null;
            }

            _paintPath = RoundedRect(new RectangleF(0f, 0f, Width - 1f, Height - 1f), GetEffectiveRadius());
        }

        private void DrawIconAndText(Graphics graphics, Rectangle rect)
        {
            var iconSize = Math.Max(10, Math.Min(IconSize, Height - 12));
            var text = Text ?? string.Empty;
            var textSize = TextRenderer.MeasureText(
                graphics,
                text,
                Font,
                new Size(2048, Height),
                TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);

            var groupWidth = iconSize + IconTextGap + textSize.Width;
            var startX = Math.Max(8, (Width - groupWidth) / 2);
            var iconRect = new Rectangle(startX, (Height - iconSize) / 2, iconSize, iconSize);
            DrawButtonIcon(graphics, iconRect, ForeColor);

            var textRect = new Rectangle(
                iconRect.Right + IconTextGap,
                0,
                Math.Max(0, rect.Right - (iconRect.Right + IconTextGap) - 8),
                Height);
            TextRenderer.DrawText(
                graphics,
                text,
                Font,
                textRect,
                ForeColor,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis);
        }

        private void DrawButtonIcon(Graphics graphics, Rectangle rect, Color color)
        {
            switch (IconKind)
            {
                case ButtonIconKind.Telegram:
                    DrawTelegramIcon(graphics, rect, color);
                    break;
                case ButtonIconKind.GitHub:
                    DrawGitHubIcon(graphics, rect, color);
                    break;
                case ButtonIconKind.Refresh:
                    DrawRefreshIcon(graphics, rect, color);
                    break;
                case ButtonIconKind.Folder:
                    DrawFolderIcon(graphics, rect, color);
                    break;
            }
        }

        private static void DrawTelegramIcon(Graphics graphics, Rectangle rect, Color color)
        {
            using (var pen = new Pen(color, 1.5f))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                pen.LineJoin = LineJoin.Round;

                var left = rect.Left + 1f;
                var top = rect.Top + 1f;
                var right = rect.Right - 1f;
                var bottom = rect.Bottom - 1f;
                var midY = rect.Top + rect.Height * 0.55f;

                var p1 = new PointF(left, midY);
                var p2 = new PointF(right, top + 0.5f);
                var p3 = new PointF(right - rect.Width * 0.34f, bottom);
                var p4 = new PointF(left + rect.Width * 0.45f, rect.Top + rect.Height * 0.58f);

                graphics.DrawLines(pen, new[] { p1, p2, p3, p4, p1 });
                graphics.DrawLine(pen, p4, p2);
            }
        }

        private static void DrawGitHubIcon(Graphics graphics, Rectangle rect, Color color)
        {
            using (var pen = new Pen(color, 1.4f))
            using (var brush = new SolidBrush(color))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                pen.LineJoin = LineJoin.Round;

                var x = rect.Left;
                var y = rect.Top;
                var w = rect.Width;
                var h = rect.Height;
                var r = Math.Max(1.6f, Math.Min(w, h) * 0.16f);

                var pTop = new PointF(x + w * 0.28f, y + h * 0.22f);
                var pMid = new PointF(x + w * 0.75f, y + h * 0.50f);
                var pBottom = new PointF(x + w * 0.28f, y + h * 0.78f);

                graphics.DrawLine(pen, pTop, pBottom);
                graphics.DrawLine(pen, pTop, pMid);
                graphics.DrawLine(pen, pBottom, pMid);

                graphics.FillEllipse(brush, pTop.X - r, pTop.Y - r, r * 2f, r * 2f);
                graphics.FillEllipse(brush, pMid.X - r, pMid.Y - r, r * 2f, r * 2f);
                graphics.FillEllipse(brush, pBottom.X - r, pBottom.Y - r, r * 2f, r * 2f);
            }
        }

        private static void DrawRefreshIcon(Graphics graphics, Rectangle rect, Color color)
        {
            using (var pen = new Pen(color, 1.5f))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                pen.LineJoin = LineJoin.Round;

                var arcRect = new RectangleF(rect.Left + 1.5f, rect.Top + 1.5f, rect.Width - 3f, rect.Height - 3f);
                graphics.DrawArc(pen, arcRect, 35f, 285f);

                var angle = 320f * (float)Math.PI / 180f;
                var cx = arcRect.Left + arcRect.Width / 2f;
                var cy = arcRect.Top + arcRect.Height / 2f;
                var rx = arcRect.Width / 2f;
                var ry = arcRect.Height / 2f;
                var tip = new PointF(cx + rx * (float)Math.Cos(angle), cy + ry * (float)Math.Sin(angle));
                var wingA = new PointF(tip.X - 4.5f, tip.Y - 0.8f);
                var wingB = new PointF(tip.X - 1.2f, tip.Y + 3.8f);
                graphics.DrawLine(pen, tip, wingA);
                graphics.DrawLine(pen, tip, wingB);
            }
        }

        private static void DrawFolderIcon(Graphics graphics, Rectangle rect, Color color)
        {
            using (var pen = new Pen(color, 1.4f))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                pen.LineJoin = LineJoin.Round;

                var x = rect.Left + 1f;
                var y = rect.Top + 2f;
                var w = rect.Width - 2f;
                var h = rect.Height - 3f;
                var tabW = w * 0.34f;
                var tabH = h * 0.28f;
                var bodyTop = y + tabH;

                using (var path = new GraphicsPath())
                {
                    path.AddLine(x, bodyTop, x + tabW - 1f, bodyTop);
                    path.AddLine(x + tabW - 1f, bodyTop, x + tabW + 2f, y);
                    path.AddLine(x + tabW + 2f, y, x + w - 1f, y);
                    path.AddLine(x + w - 1f, y, x + w - 1f, y + h - 1f);
                    path.AddLine(x + w - 1f, y + h - 1f, x, y + h - 1f);
                    path.AddLine(x, y + h - 1f, x, bodyTop);
                    path.CloseFigure();
                    graphics.DrawPath(pen, path);
                }
            }
        }

        private float GetEffectiveRadius()
        {
            var maxRadius = Math.Max(1f, (Math.Min(Width, Height) - 2f) / 2f);
            return Math.Min(Radius, maxRadius);
        }

        private static GraphicsPath RoundedRect(RectangleF bounds, float radius)
        {
            var diameter = radius * 2f;
            var path = new GraphicsPath();
            if (diameter <= 0f)
            {
                path.AddRectangle(bounds);
                return path;
            }
            if (diameter >= Math.Min(bounds.Width, bounds.Height))
            {
                diameter = Math.Min(bounds.Width, bounds.Height);
                radius = diameter / 2f;
            }
            if (diameter <= 1f)
            {
                path.AddRectangle(bounds);
                return path;
            }

            var arc = new RectangleF(bounds.X, bounds.Y, diameter, diameter);
            path.AddArc(arc, 180, 90);
            arc.X = bounds.Right - diameter;
            path.AddArc(arc, 270, 90);
            arc.Y = bounds.Bottom - diameter;
            path.AddArc(arc, 0, 90);
            arc.X = bounds.X;
            path.AddArc(arc, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    internal static class InputDialog
    {
        public static string Show(IWin32Window owner, string title, string labelText, string defaultValue, bool isRussian)
        {
            using (var form = new Form())
            using (var label = new Label())
            using (var textBox = new TextBox())
            using (var okButton = new Button())
            using (var cancelButton = new Button())
            {
                form.Text = title;
                form.FormBorderStyle = FormBorderStyle.FixedDialog;
                form.StartPosition = FormStartPosition.CenterParent;
                form.ClientSize = new Size(460, 150);
                form.MinimizeBox = false;
                form.MaximizeBox = false;
                form.ShowInTaskbar = false;
                form.BackColor = Color.FromArgb(35, 35, 35);

                label.Text = labelText;
                label.SetBounds(12, 14, 430, 20);
                label.AutoSize = true;
                label.ForeColor = Color.FromArgb(242, 242, 242);

                textBox.SetBounds(12, 40, 430, 30);
                textBox.Text = defaultValue ?? string.Empty;
                textBox.BackColor = Color.FromArgb(45, 45, 45);
                textBox.ForeColor = Color.FromArgb(242, 242, 242);
                textBox.BorderStyle = BorderStyle.FixedSingle;

                okButton.Text = "OK";
                okButton.DialogResult = DialogResult.OK;
                okButton.SetBounds(286, 92, 75, 30);
                okButton.FlatStyle = FlatStyle.Flat;
                okButton.BackColor = Color.FromArgb(45, 45, 45);
                okButton.ForeColor = Color.FromArgb(242, 242, 242);
                okButton.FlatAppearance.BorderColor = Color.FromArgb(57, 57, 57);

                cancelButton.Text = isRussian ? "Отмена" : "Cancel";
                cancelButton.DialogResult = DialogResult.Cancel;
                cancelButton.SetBounds(367, 92, 75, 30);
                cancelButton.FlatStyle = FlatStyle.Flat;
                cancelButton.BackColor = Color.FromArgb(45, 45, 45);
                cancelButton.ForeColor = Color.FromArgb(242, 242, 242);
                cancelButton.FlatAppearance.BorderColor = Color.FromArgb(57, 57, 57);

                form.Controls.AddRange(new Control[] { label, textBox, okButton, cancelButton });
                form.AcceptButton = okButton;
                form.CancelButton = cancelButton;

                var result = form.ShowDialog(owner);
                if (result == DialogResult.OK)
                {
                    return textBox.Text;
                }
                return null;
            }
        }
    }
}
