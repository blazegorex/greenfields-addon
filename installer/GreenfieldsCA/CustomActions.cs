// Greenfields installer custom actions.
//
// FindWow / CheckWowDir   work out the World of Warcraft folder (the same places the updater looks,
//                         plus Battle.net's own install list) and fill the GF_* properties the
//                         dialogs show. Read-only.
// CheckInUse              makes sure WoW is closed and nothing (usually a File Explorer window) has
//                         the Greenfields folder open, before Windows Installer starts deleting and
//                         copying. Read-only apart from a throwaway file proving the folder is writable.
// EnableAutoUpdates       deferred: runs the installed updater with -InstallSchedule, exactly what
//                         "Turn On Auto Updates" does.
// RemoveAutoUpdates       deferred, real uninstall only: deletes the "Greenfields Updater" task.
// RemoveUpdaterData       deferred, real uninstall only: deletes %LOCALAPPDATA%\GreenfieldsUpdater
//                         (the updater's log, state and backups) without following links.
//
// Never touches the WTF folder (SavedVariables) or any other addon.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using WixToolset.Dtf.WindowsInstaller;
using FileAttributes = System.IO.FileAttributes;

namespace GreenfieldsCA
{
    public static class CustomActions
    {
        const string Primary = "_forever_";
        const string AddonName = "Greenfields";
        const string TaskName = "Greenfields Updater";

        // Any of these under a folder means it's a World of Warcraft folder.
        static readonly string[] Flavors =
        {
            "_forever_", "_forever_ptr_", "_forever_beta_", "_classic_beta_", "_retail_", "_classic_",
            "_classic_era_", "_ptr_", "_beta_", "_classic_ptr_", "_classic_era_ptr_", "_xptr_"
        };

        // Common install spots, tried on every fixed drive (same list as the updater).
        static readonly string[] DriveSpots =
        {
            @"Program Files (x86)\World of Warcraft", @"Program Files\World of Warcraft", @"World of Warcraft",
            @"Games\World of Warcraft", @"Battle.net\World of Warcraft", @"Blizzard\World of Warcraft"
        };

        // WoW's own game clients. WowUp (an addon manager) and the Wowhead client don't count.
        static readonly Regex WowProcess = new Regex(@"^wow(classic|forever)?(-?64)?(b|t|ptr|beta)?$", RegexOptions.IgnoreCase);

        // ------------------------------------------------------------------ immediate: finding WoW
        [CustomAction]
        public static ActionResult FindWow(Session session)
        {
            try
            {
                string given = session["WOWDIR"];
                string saved = session["GF_SAVEDWOWDIR"];
                bool maintenance = !string.IsNullOrEmpty(session["Installed"]);

                string root = null;
                string source = null;
                if (maintenance)
                {
                    // repair / uninstall: only ever the folder it was installed into (even if WoW has
                    // gone from there). Never search: uninstall must not find some other WoW.
                    root = Clean(!string.IsNullOrEmpty(given) ? given : saved);
                    if (string.IsNullOrEmpty(root)) root = null;
                    source = "installed here";
                }
                else
                {
                    var candidates = new List<KeyValuePair<string, string>>();
                    Add(candidates, given, "chosen");
                    Add(candidates, saved, "remembered");
                    if (session["GF_NOSEARCH"] != "1")
                    {
                        Add(candidates, UpdaterStateWowPath(), "the updater's settings");
                        foreach (string p in RegistryPaths()) Add(candidates, p, "the registry");
                        foreach (string p in BattleNetPaths()) Add(candidates, p, "Battle.net");
                        foreach (string p in DrivePaths()) Add(candidates, p, "a usual spot");
                    }
                    string firstWow = null, firstWowSource = null;
                    foreach (var c in candidates)
                    {
                        string r = ToWowRoot(c.Key);
                        if (!IsWowRoot(r)) continue;
                        session.Log("GF: WoW candidate " + r + " (from " + c.Value + ")" + (HasForever(r) ? " has _forever_" : ""));
                        if (HasForever(r)) { root = r; source = c.Value; break; }
                        if (firstWow == null) { firstWow = r; firstWowSource = c.Value; }
                    }
                    if (root == null && firstWow != null) { root = firstWow; source = firstWowSource; }
                }

                if (root == null)
                {
                    session.Log("GF: no World of Warcraft folder found");
                    session["WOWDIR"] = Slash(DefaultBrowseStart());
                    SetState(session, null);
                }
                else
                {
                    session.Log("GF: using " + root + " (" + source + ")");
                    session["WOWDIR"] = Slash(root);
                    SetState(session, root);
                }
                return ActionResult.Success;
            }
            catch (Exception e)
            {
                session.Log("GF: FindWow failed: " + e);
                SetState(session, null);
                return ActionResult.Success;
            }
        }

        // After the Browse page (or before Install): forgive picking _forever_, Interface, AddOns or
        // Greenfields instead of the World of Warcraft folder, and re-point the install there.
        [CustomAction]
        public static ActionResult CheckWowDir(Session session)
        {
            try
            {
                string picked = session["WOWDIR"];
                string root = ToWowRoot(picked);
                if (IsWowRoot(root))
                {
                    if (!SamePath(root, picked)) session.Log("GF: " + picked + " -> " + root);
                    // always re-point: after a cancelled Browse the property and the folder can disagree
                    session.SetTargetPath("WOWDIR", Slash(root));
                    SetState(session, root);
                }
                else
                {
                    session.Log("GF: not a WoW folder: " + picked);
                    SetState(session, null);
                    session["GF_WOWSTATE"] = "notwow";
                }
            }
            catch (Exception e)
            {
                session.Log("GF: CheckWowDir failed: " + e);
                session["GF_WOWOK"] = "";
                session["GF_WOWSTATE"] = "notwow";
            }
            return ActionResult.Success;
        }

        static void SetState(Session session, string root)
        {
            session["GF_OLDVER"] = "";
            if (root == null)
            {
                session["GF_WOWOK"] = "";
                session["GF_WOWSTATE"] = "none";
                session["GF_ADDONDIR"] = "";
                return;
            }
            if (!HasForever(root))
            {
                session["GF_WOWOK"] = "";
                session["GF_WOWSTATE"] = "noforever";
                session["GF_ADDONDIR"] = "";
                return;
            }
            string addon = AddonDir(root);
            session["GF_WOWOK"] = "1";
            session["GF_WOWSTATE"] = "found";
            session["GF_ADDONDIR"] = Slash(addon);
            string ver = TocVersion(addon);
            if (ver != null) session["GF_OLDVER"] = ver;
        }

        // ------------------------------------------------------------------ immediate: in use?
        // GF_BLOCKER is empty when it's safe to go ahead. Otherwise GF_BLOCKKIND says why
        // (wow / held / link / denied) and GF_BLOCKER has the detail line for the dialog.
        [CustomAction]
        public static ActionResult CheckInUse(Session session)
        {
            session["GF_BLOCKER"] = "";
            session["GF_BLOCKKIND"] = "";
            try
            {
                string addon = session["GF_ADDONDIR"];
                if (string.IsNullOrEmpty(addon))
                {
                    session.Log("GF: CheckInUse: no addon folder yet");
                    return ActionResult.Success;
                }
                addon = Clean(addon);
                string addons = Path.GetDirectoryName(addon);

                var wow = RunningWow(session, Path.GetDirectoryName(Path.GetDirectoryName(Path.GetDirectoryName(addons))));
                if (wow.Count > 0)
                {
                    Block(session, "wow", "WoW is still open (" + string.Join(", ", wow) + ").");
                    return ActionResult.Success;
                }

                if (Directory.Exists(addon) && IsLink(addon))
                {
                    Block(session, "link", addon + " is linked to another folder (a developer copy), so the installer won't touch it.");
                    return ActionResult.Success;
                }

                string held = null;
                if (Directory.Exists(addon)) held = FirstHeld(addon, addons);
                if (held != null)
                {
                    Block(session, "held", "Something has " + held + " open.");
                    return ActionResult.Success;
                }

                string denied = CannotWrite(addons);
                if (denied != null)
                {
                    Block(session, "denied", "Windows won't let this installer write into " + denied + ".");
                    return ActionResult.Success;
                }
                session.Log("GF: CheckInUse: all clear");
            }
            catch (Exception e)
            {
                // a broken check must never stop an install; Windows Installer still reports real failures
                session.Log("GF: CheckInUse failed (ignored): " + e);
            }
            return ActionResult.Success;
        }

        static void Block(Session session, string kind, string detail)
        {
            session.Log("GF: blocked (" + kind + "): " + detail);
            session["GF_BLOCKKIND"] = kind;
            session["GF_BLOCKER"] = detail;
        }

        // WoW game clients running from this WoW folder. A WoW started from some other install
        // doesn't hold these files, so it doesn't count; one whose path Windows won't tell us does.
        static List<string> RunningWow(Session session, string root)
        {
            var found = new List<string>();
            string rootSlash = string.IsNullOrEmpty(root) ? null : Slash(root);
            foreach (Process p in Process.GetProcesses())
            {
                try
                {
                    string name = p.ProcessName;
                    if (!name.StartsWith("wow", StringComparison.OrdinalIgnoreCase)) continue;
                    string path = ImagePath(p);
                    bool here = rootSlash != null && path != null && path.StartsWith(rootSlash, StringComparison.OrdinalIgnoreCase);
                    // an unfamiliar Wow*.exe counts only if it sits right in a flavor folder, like the
                    // game itself (not helpers such as _forever_\Utils\WowVoiceProxy.exe)
                    bool client = here && SamePath(Path.GetDirectoryName(Path.GetDirectoryName(path)), root);
                    bool isWow = WowProcess.IsMatch(name) ? (path == null || rootSlash == null || here) : client;
                    if (!isWow)
                    {
                        if (WowProcess.IsMatch(name)) session.Log("GF: " + name + " is running from another folder (" + path + "), so it doesn't count");
                        continue;
                    }
                    if (!found.Contains(name + ".exe")) found.Add(name + ".exe");
                }
                catch (Exception e) { session.Log("GF: couldn't look at a process: " + e.Message); }
                finally { p.Dispose(); }
            }
            return found;
        }

        // The first folder or file under the Greenfields folder that something else has open, as a
        // path starting at AddOns (e.g. "AddOns\Greenfields\Core"), or null.
        static string FirstHeld(string addon, string addons)
        {
            var stack = new Stack<string>();
            stack.Push(addon);
            while (stack.Count > 0)
            {
                string dir = stack.Pop();
                if (!CanOpenExclusive(dir, true)) return Shown(dir, addons);
                string[] files, dirs;
                try { files = Directory.GetFiles(dir); dirs = Directory.GetDirectories(dir); }
                catch (UnauthorizedAccessException) { return Shown(dir, addons); }
                foreach (string f in files)
                    if (!CanOpenExclusive(f, false)) return Shown(f, addons);
                foreach (string d in dirs)
                    if (!IsLink(d)) stack.Push(d);
            }
            return null;
        }

        static string Shown(string path, string addons)
        {
            string parent = Path.GetDirectoryName(addons);
            return (parent != null && path.StartsWith(parent + "\\", StringComparison.OrdinalIgnoreCase))
                ? path.Substring(parent.Length + 1) : path;
        }

        // Proves Windows lets us create files where the addon goes (the nearest folder that exists).
        static string CannotWrite(string addons)
        {
            string dir = addons;
            while (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) dir = Path.GetDirectoryName(dir);
            if (string.IsNullOrEmpty(dir)) return null;
            string probe = Path.Combine(dir, "Greenfields.gfmsi-check-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".tmp");
            try
            {
                using (new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1, FileOptions.DeleteOnClose)) { }
                return null;
            }
            catch (UnauthorizedAccessException) { return dir; }
            catch (IOException) { return null; }   // odd, but not a permissions problem
            finally { try { if (File.Exists(probe)) File.Delete(probe); } catch { } }
        }

        // ------------------------------------------------------------------ deferred: auto updates
        [CustomAction]
        public static ActionResult EnableAutoUpdates(Session session)
        {
            try
            {
                CustomActionData data = session.CustomActionData;
                string script = data.ContainsKey("SCRIPT") ? data["SCRIPT"] : null;
                string wow = data.ContainsKey("WOWDIR") ? Clean(data["WOWDIR"]) : null;
                if (string.IsNullOrEmpty(script) || !File.Exists(script))
                {
                    session.Log("GF: updater script missing, can't turn on auto updates: " + script);
                    return ActionResult.Success;
                }
                string args = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -InstallSchedule -Quiet";
                if (!string.IsNullOrEmpty(wow)) args += " -WowPath " + Quote(wow);
                int code = Run(session, PowerShell(), args, Path.GetDirectoryName(script), 300);
                // exit 1 can just mean GitHub was unreachable for the first check; the task is still made
                session.Log("GF: Turn On Auto Updates finished with exit code " + code);
            }
            catch (Exception e) { session.Log("GF: EnableAutoUpdates failed (ignored): " + e); }
            return ActionResult.Success;
        }

        [CustomAction]
        public static ActionResult RemoveAutoUpdates(Session session)
        {
            try
            {
                int code = Run(session, SystemTool("schtasks.exe"), "/Delete /TN " + Quote(TaskName) + " /F", null, 60);
                session.Log("GF: removing the auto update task: exit code " + code + (code != 0 ? " (fine if it wasn't on)" : ""));
            }
            catch (Exception e) { session.Log("GF: RemoveAutoUpdates failed (ignored): " + e); }
            return ActionResult.Success;
        }

        [CustomAction]
        public static ActionResult RemoveUpdaterData(Session session)
        {
            try
            {
                string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                if (string.IsNullOrEmpty(local)) return ActionResult.Success;
                string dir = Path.Combine(local, "GreenfieldsUpdater");
                if (Directory.Exists(dir))
                {
                    DeleteTree(session, dir);
                    session.Log("GF: removed " + dir);
                }
            }
            catch (Exception e) { session.Log("GF: RemoveUpdaterData failed (ignored): " + e); }
            return ActionResult.Success;
        }

        // ------------------------------------------------------------------ WoW folder helpers
        static void Add(List<KeyValuePair<string, string>> list, string path, string source)
        {
            path = Clean(path);
            if (string.IsNullOrEmpty(path)) return;
            foreach (var c in list) if (SamePath(c.Key, path)) return;
            list.Add(new KeyValuePair<string, string>(path, source));
        }

        static string Clean(string path)
        {
            if (path == null) return null;
            path = path.Trim().Trim('"').Trim().Replace('/', '\\');
            while (path.Length > 3 && path.EndsWith("\\")) path = path.Substring(0, path.Length - 1);
            return path;
        }

        static string Slash(string path)
        {
            path = Clean(path);
            return path.EndsWith("\\") ? path : path + "\\";
        }

        static bool SamePath(string a, string b)
        {
            return string.Equals(Clean(a), Clean(b), StringComparison.OrdinalIgnoreCase);
        }

        static string ToWowRoot(string dir)
        {
            dir = Clean(dir);
            if (string.IsNullOrEmpty(dir)) return dir;
            for (int i = 0; i < 4 && !string.IsNullOrEmpty(dir); i++)
            {
                if (IsWowRoot(dir)) return dir;
                string leaf = Path.GetFileName(dir);
                if (leaf == null || !Regex.IsMatch(leaf, @"^(_.+_|Interface|AddOns|Greenfields)$", RegexOptions.IgnoreCase)) break;
                dir = Path.GetDirectoryName(dir);
            }
            return dir;
        }

        static bool IsWowRoot(string dir)
        {
            if (string.IsNullOrEmpty(dir)) return false;
            try
            {
                if (!Directory.Exists(dir)) return false;
                foreach (string f in Flavors) if (Directory.Exists(Path.Combine(dir, f))) return true;
            }
            catch { }
            return false;
        }

        static bool HasForever(string root)
        {
            try { return !string.IsNullOrEmpty(root) && Directory.Exists(Path.Combine(root, Primary)); }
            catch { return false; }
        }

        static string AddonDir(string root)
        {
            return Path.Combine(root, Primary, "Interface", "AddOns", AddonName);
        }

        static string TocVersion(string addonDir)
        {
            try
            {
                string toc = Path.Combine(addonDir, AddonName + ".toc");
                if (!File.Exists(toc)) return null;
                int n = 0;
                foreach (string line in File.ReadLines(toc))
                {
                    Match m = Regex.Match(line, @"^\s*##\s*Version:\s*(\S+)");
                    if (m.Success) return m.Groups[1].Value;
                    if (++n > 40) break;
                }
            }
            catch { }
            return null;
        }

        static string DefaultBrowseStart()
        {
            string p = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
            if (string.IsNullOrEmpty(p)) p = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            return string.IsNullOrEmpty(p) ? @"C:\" : p;
        }

        static string UpdaterStateWowPath()
        {
            try
            {
                string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                string state = Path.Combine(local, "GreenfieldsUpdater", "state.json");
                if (!File.Exists(state)) return null;
                Match m = Regex.Match(File.ReadAllText(state), "\"wowPath\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
                if (m.Success) return Regex.Unescape(m.Groups[1].Value);
            }
            catch { }
            return null;
        }

        static IEnumerable<string> RegistryPaths()
        {
            var found = new List<string>();
            string[] keys =
            {
                @"SOFTWARE\Blizzard Entertainment\World of Warcraft",
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\World of Warcraft"
            };
            foreach (RegistryView view in new[] { RegistryView.Registry32, RegistryView.Registry64 })
            {
                foreach (string k in keys)
                {
                    try
                    {
                        using (RegistryKey hive = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view))
                        using (RegistryKey key = hive.OpenSubKey(k))
                        {
                            if (key == null) continue;
                            foreach (string v in new[] { "InstallPath", "InstallLocation", "GamePath" })
                            {
                                string s = key.GetValue(v) as string;
                                if (!string.IsNullOrEmpty(s)) found.Add(s);
                            }
                        }
                    }
                    catch { }
                }
            }
            return found;
        }

        // Battle.net keeps its installs in product.db (protobuf); the paths are plain UTF-8 inside it.
        static IEnumerable<string> BattleNetPaths()
        {
            var found = new List<string>();
            try
            {
                string data = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
                string db = Path.Combine(data, "Battle.net", "Agent", "product.db");
                if (!File.Exists(db)) return found;
                byte[] bytes;
                using (var fs = new FileStream(db, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (fs.Length > 16 * 1024 * 1024) return found;
                    bytes = new byte[fs.Length];
                    int read = 0;
                    while (read < bytes.Length)
                    {
                        int n = fs.Read(bytes, read, bytes.Length - read);
                        if (n <= 0) break;
                        read += n;
                    }
                }
                string text = Encoding.UTF8.GetString(bytes);
                foreach (Match m in Regex.Matches(text, @"[A-Za-z]:[\\/][^\x00-\x1f""<>|*?]{0,240}?World of Warcraft", RegexOptions.IgnoreCase))
                    found.Add(m.Value);
            }
            catch { }
            return found;
        }

        static IEnumerable<string> DrivePaths()
        {
            var found = new List<string>();
            foreach (DriveInfo d in DriveInfo.GetDrives())
            {
                try
                {
                    // fixed disks only: a disconnected network drive or empty card reader can hang
                    if (d.DriveType != DriveType.Fixed || !d.IsReady) continue;
                    foreach (string s in DriveSpots) found.Add(Path.Combine(d.RootDirectory.FullName, s));
                }
                catch { }
            }
            return found;
        }

        // ------------------------------------------------------------------ file system helpers
        static bool IsLink(string path)
        {
            try { return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0; }
            catch { return false; }
        }

        static void DeleteTree(Session session, string path)
        {
            // never follows a junction or symlink: a link is removed, not what it points at
            FileAttributes a = File.GetAttributes(path);
            bool link = (a & FileAttributes.ReparsePoint) != 0;
            if ((a & FileAttributes.Directory) != 0)
            {
                if (!link)
                {
                    foreach (string f in Directory.GetFiles(path)) DeleteTree(session, f);
                    foreach (string d in Directory.GetDirectories(path)) DeleteTree(session, d);
                }
                try { if ((a & FileAttributes.ReadOnly) != 0) File.SetAttributes(path, a & ~FileAttributes.ReadOnly); } catch { }
                try { Directory.Delete(path, false); }
                catch (Exception e) { session.Log("GF: couldn't remove " + path + ": " + e.Message); }
            }
            else
            {
                try
                {
                    if ((a & FileAttributes.ReadOnly) != 0) File.SetAttributes(path, a & ~FileAttributes.ReadOnly);
                    File.Delete(path);
                }
                catch (Exception e) { session.Log("GF: couldn't remove " + path + ": " + e.Message); }
            }
        }

        const uint FILE_READ_DATA = 0x0001;          // FILE_LIST_DIRECTORY for folders
        const uint FILE_SHARE_NONE = 0;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        const int ERROR_SHARING_VIOLATION = 32;
        const int ERROR_LOCK_VIOLATION = 33;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
                                                 uint disposition, uint flags, IntPtr template);

        // True unless another program has this file or folder open. Opening it with no sharing at
        // all fails while anyone else holds a handle with read, write or delete access - which is
        // what a File Explorer window watching a folder, or a program "standing in" it, does.
        static bool CanOpenExclusive(string path, bool folder)
        {
            uint flags = FILE_FLAG_OPEN_REPARSE_POINT | (folder ? FILE_FLAG_BACKUP_SEMANTICS : 0);
            using (SafeFileHandle h = CreateFileW(@"\\?\" + path, FILE_READ_DATA, FILE_SHARE_NONE, IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero))
            {
                if (!h.IsInvalid) return true;
                int err = Marshal.GetLastWin32Error();
                return !(err == ERROR_SHARING_VIOLATION || err == ERROR_LOCK_VIOLATION);
            }
        }

        const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr h);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool QueryFullProcessImageNameW(IntPtr process, int flags, StringBuilder name, ref int size);

        static string ImagePath(Process p)
        {
            IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, p.Id);
            if (h == IntPtr.Zero) return null;
            try
            {
                var sb = new StringBuilder(1024);
                int size = sb.Capacity;
                return QueryFullProcessImageNameW(h, 0, sb, ref size) ? sb.ToString(0, size) : null;
            }
            finally { CloseHandle(h); }
        }

        // ------------------------------------------------------------------ running tools
        static string Quote(string s)
        {
            // a trailing backslash would escape the closing quote
            while (s.EndsWith("\\") && s.Length > 3) s = s.Substring(0, s.Length - 1);
            return "\"" + s + "\"";
        }

        static string SystemTool(string exe)
        {
            string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            // a 32-bit installer on 64-bit Windows: Sysnative reaches the real (64-bit) System32
            string sysnative = Path.Combine(win, "Sysnative", exe);
            if (!Environment.Is64BitProcess && Environment.Is64BitOperatingSystem && File.Exists(sysnative)) return sysnative;
            return Path.Combine(win, "System32", exe);
        }

        static string PowerShell()
        {
            return SystemTool(@"WindowsPowerShell\v1.0\powershell.exe");
        }

        static int Run(Session session, string exe, string args, string workDir, int timeoutSeconds)
        {
            session.Log("GF: running " + exe + " " + args);
            var psi = new ProcessStartInfo(exe, args)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WorkingDirectory = string.IsNullOrEmpty(workDir) ? Environment.GetFolderPath(Environment.SpecialFolder.Windows) : workDir
            };
            var output = new StringBuilder();
            using (var p = new Process { StartInfo = psi })
            {
                p.OutputDataReceived += (s, e) => { if (e.Data != null) lock (output) output.AppendLine(e.Data); };
                p.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (output) output.AppendLine(e.Data); };
                p.Start();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                if (!p.WaitForExit(timeoutSeconds * 1000))
                {
                    try { p.Kill(); } catch { }
                    session.Log("GF: gave up waiting after " + timeoutSeconds + "s");
                    return -1;
                }
                p.WaitForExit();
                lock (output)
                {
                    foreach (string line in output.ToString().Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries))
                        session.Log("GF:   " + line);
                }
                return p.ExitCode;
            }
        }
    }
}
