// .NET Framework Windows launcher. Embedded, transparent scripts; no obfuscation.
// Does not install anything on startup, kill processes or send game messages.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class LOLPallasApp {
    static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
    static readonly string[] FileNames = {
        "Edit-Hotkeys-GUI.ps1", "Manage-Pallas-Portable.ps1", "messages.example.json", "README.md",
        "lib/HotkeyTools.ps1", "lib/LibraryTools.ps1", "lib/ShoutTools.ps1", "lib/PortableTools.ps1",
        "lib/StandaloneTools.ps1", "lib/hotkeys-ui.zh-CN.json", "patches/original-to-portable.json",
        "patches/v2-to-portable.json", "patches/portable-v3-to-fixed.json", "patches/portable-fixed-to-compatible.json", "package-manifest.json"
    };
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 4194304 };
    static string Sid { get { return WindowsIdentity.GetCurrent().User.Value; } }
    static string OwnExe { get { return Assembly.GetExecutingAssembly().Location; } }
    static string UserRoot { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LOLPallasPortable"); } }
    static string Digest(byte[] data) { using (var sha = SHA256.Create()) { return BitConverter.ToString(sha.ComputeHash(data)).Replace("-", "").ToLowerInvariant(); } }
    static byte[] Resource(string name) {
        using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)) {
            if (stream == null) throw new InvalidDataException("Missing embedded resource: " + name);
            using (var output = new MemoryStream()) { stream.CopyTo(output); return output.ToArray(); }
        }
    }
    static byte[] Payload(out string hash) {
        hash = Utf8.GetString(Resource("LOLPallas.Payload.sha256")).Trim();
        byte[] zip = Resource("LOLPallas.Payload.zip");
        if (!Regex.IsMatch(hash, "^[a-f0-9]{64}$") || Digest(zip) != hash) throw new InvalidDataException("Embedded package checksum mismatch.");
        return zip;
    }
    static string PlainPath(string path) {
        string full = Path.GetFullPath(path);
        if (full.StartsWith(@"\\", StringComparison.Ordinal)) throw new IOException("Network paths are unsupported.");
        string at = full;
        while (!String.IsNullOrEmpty(at)) {
            if ((File.Exists(at) || Directory.Exists(at)) && (File.GetAttributes(at) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Linked/reparse path refused: " + at);
            string next = Path.GetDirectoryName(at);
            if (next == at) break; at = next;
        }
        return full;
    }
    static string Under(string root, string name) {
        string full = PlainPath(Path.Combine(root, name.Replace('/', Path.DirectorySeparatorChar)));
        string prefix = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) || full.Length >= 260)
            throw new IOException("Invalid/overlong application file path.");
        return full;
    }
    static string Quote(string value) {
        if (Regex.IsMatch(value, "[\x00-\x1f\"]")) throw new ArgumentException("Invalid command argument.");
        return "\"" + Regex.Replace(value, @"(\\+)$", "$1$1") + "\"";
    }
    static Dictionary<string, byte[]> Unpack(byte[] payload) {
        var files = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        var allowed = new HashSet<string>(FileNames, StringComparer.Ordinal);
        long total = 0;
        using (var input = new MemoryStream(payload)) using (var zip = new ZipArchive(input, ZipArchiveMode.Read)) {
            foreach (var entry in zip.Entries) {
                string name = entry.FullName.Replace('\\', '/');
                if (name.EndsWith("/", StringComparison.Ordinal)) continue;
                const string prefix = "LOLPallasApp/";
                if (!name.StartsWith(prefix, StringComparison.Ordinal)) throw new InvalidDataException("Unexpected package root.");
                name = name.Substring(prefix.Length);
                if (!allowed.Contains(name) || files.ContainsKey(name) || entry.Length > 4194304 || (total += entry.Length) > 4194304)
                    throw new InvalidDataException("Unexpected/duplicate/oversized package file.");
                using (var stream = entry.Open()) using (var output = new MemoryStream()) { stream.CopyTo(output); files.Add(name, output.ToArray()); }
            }
        }
        if (files.Count != FileNames.Length) throw new InvalidDataException("Incomplete embedded package.");
        var manifest = Json.Deserialize<Dictionary<string, object>>(Utf8.GetString(files["package-manifest.json"]));
        if ((string)manifest["release"] != "single-exe-v1-TEST" || (bool)manifest["game_send_verified"] ||
            (bool)manifest["personal_messages_included"] || (bool)manifest["full_proprietary_binaries_included"])
            throw new InvalidDataException("Unexpected package scope.");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (object item in (System.Collections.IEnumerable)manifest["files"]) {
            var record = (Dictionary<string, object>)item;
            string name = (string)record["path"];
            if (name == "package-manifest.json" || !files.ContainsKey(name) || !seen.Add(name) ||
                Digest(files[name]) != ((string)record["sha256"]).ToLowerInvariant() || files[name].LongLength != Convert.ToInt64(record["bytes"]))
                throw new InvalidDataException("Embedded file checksum mismatch.");
        }
        if (seen.Count != files.Count - 1) throw new InvalidDataException("Incomplete package manifest.");
        return files;
    }
    static void VerifyCache(string root, Dictionary<string, byte[]> files) {
        PlainPath(root);
        foreach (var file in files) {
            string path = Under(root, file.Key);
            if (!File.Exists(path) || Digest(File.ReadAllBytes(path)) != Digest(file.Value))
                throw new InvalidDataException("Application cache missing/modified; refused to run: " + path);
        }
    }
    static string EnsureAssets(string baseRoot) {
        string hash; var files = Unpack(Payload(out hash));
        string app = PlainPath(Path.Combine(baseRoot, "App"));
        string root = Under(app, "v1-" + hash.Substring(0, 24));
        using (var mutex = new Mutex(false, "Local\\LOLPallasCache-" + Sid + "-" + hash.Substring(0, 24))) {
            bool held = false;
            try {
                try { held = mutex.WaitOne(5000); } catch (AbandonedMutexException) { held = true; }
                if (!held) throw new IOException("Another application extraction is running.");
                if (Directory.Exists(root)) { VerifyCache(root, files); return root; }
                Directory.CreateDirectory(app);
                string stage = Under(app, "stage-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(stage);
                foreach (var file in files) {
                    string destination = Under(stage, file.Key);
                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    using (var stream = new FileStream(destination, FileMode.CreateNew, FileAccess.Write)) { stream.Write(file.Value, 0, file.Value.Length); stream.Flush(true); }
                }
                VerifyCache(stage, files);
                // Both fully resolved move targets are confined to this owned application directory.
                Under(app, Path.GetFileName(stage)); Under(app, Path.GetFileName(root));
                Directory.Move(stage, root); VerifyCache(root, files); return root;
            } finally { if (held) mutex.ReleaseMutex(); }
        }
    }
    sealed class RunResult { public int code; public string output; public string error; }
    static string Shell {
        get {
            string exe = Path.Combine(Environment.GetEnvironmentVariable("SystemRoot"), @"System32\WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(exe)) throw new FileNotFoundException("Windows PowerShell 5.1 is required.");
            return exe;
        }
    }
    static RunResult RunPowerShell(string script, string arguments) {
        var start = new ProcessStartInfo(Shell, "-NoProfile -STA -ExecutionPolicy Bypass -File " + Quote(script) + " " + arguments) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Utf8, StandardErrorEncoding = Utf8, WorkingDirectory = Path.GetDirectoryName(script)
        };
        // This app uses Windows PowerShell 5.1 built-ins only. A non-PowerShell
        // intermediary can retain a PS7 module path and break Security loading.
        // Limit ONLY this child's environment; never change user/system settings.
        string modules = PlainPath(Path.Combine(Path.GetDirectoryName(Shell), "Modules"));
        if (!Directory.Exists(modules)) throw new DirectoryNotFoundException("Windows PowerShell system modules are required.");
        start.EnvironmentVariables["PSModulePath"] = modules;
        using (var process = Process.Start(start)) {
            Task<string> output = process.StandardOutput.ReadToEndAsync(), error = process.StandardError.ReadToEndAsync();
            process.WaitForExit(); return new RunResult { code = process.ExitCode, output = output.Result, error = error.Result };
        }
    }
    static RunResult Backend(string assets, string mode, string wegame, string source, bool consent) {
        string args = "-Mode " + mode + " -SchemePath " + Quote(source) + " -ExpectedSid " + Quote(Sid);
        if (!String.IsNullOrEmpty(wegame)) args += " -WeGameRoot " + Quote(wegame);
        if (consent) args += " -AcceptUnsignedExperiment";
        return RunPowerShell(Under(assets, "Manage-Pallas-Portable.ps1"), args);
    }
    static Dictionary<string, string> Parse(string[] args) {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var allowed = new HashSet<string> { "--action", "--wegame", "--scheme", "--job", "--sid", "--consent" };
        for (int i = 0; i < args.Length; i++) {
            string name = args[i]; if (!allowed.Contains(name) || values.ContainsKey(name)) throw new ArgumentException("Invalid/duplicate operation option.");
            if (name == "--consent") { values.Add(name, "true"); continue; }
            if (++i == args.Length) throw new ArgumentException("Missing operation value.");
            values.Add(name, args[i]);
        }
        foreach (string name in new[] { "--action", "--wegame", "--scheme", "--job", "--sid" })
            if (!values.ContainsKey(name)) throw new ArgumentException("Missing operation option: " + name);
        if (!Regex.IsMatch(values["--action"], "^(install|apply|restore|status|validate)$") ||
            !Regex.IsMatch(values["--job"], "^[a-f0-9]{32}$") || values["--sid"] != Sid ||
            (values["--action"] == "install") != values.ContainsKey("--consent"))
            throw new ArgumentException("Invalid action/consent or elevation changed Windows accounts. Use the same Windows user.");
        return values;
    }
    static int Execute(string[] args, string baseRoot) {
        var options = Parse(args); string mode = options["--action"];
        string wegame = Utf8.GetString(Convert.FromBase64String(options["--wegame"]));
        string source = PlainPath(Utf8.GetString(Convert.FromBase64String(options["--scheme"])));
        string editor = PlainPath(Path.Combine(baseRoot, "Editor"));
        if (!source.Equals(Under(editor, "messages.json"), StringComparison.OrdinalIgnoreCase)) throw new IOException("Operation source must be this user's editor messages.json.");
        string jobs = Under(editor, "jobs"); Directory.CreateDirectory(jobs);
        string resultFile = Under(jobs, options["--job"] + ".json");
        if (File.Exists(resultFile) || Directory.Exists(resultFile)) throw new IOException("An operation result already exists; refused overwrite.");
        RunResult result;
        try { result = Backend(EnsureAssets(baseRoot), mode, wegame, source, options.ContainsKey("--consent")); }
        catch (Exception e) { result = new RunResult { code = 1, output = "", error = e.Message }; }
        var record = new Dictionary<string, object> { {"job",options["--job"]}, {"sid",Sid}, {"mode",mode},
            {"exit_code",result.code}, {"output",result.output}, {"error",result.error} };
        byte[] bytes = Utf8.GetBytes(Json.Serialize(record));
        using (var stream = new FileStream(resultFile,FileMode.CreateNew,FileAccess.Write)) { stream.Write(bytes,0,bytes.Length); stream.Flush(true); }
        return result.code;
    }
    static int OpenEditor() {
        string assets = EnsureAssets(UserRoot);
        string editor = PlainPath(Path.Combine(UserRoot,"Editor")); Directory.CreateDirectory(editor);
        using (var mutex = new Mutex(false,"Local\\LOLPallasEditor-" + Sid)) {
            bool held = false;
            try {
                try { held = mutex.WaitOne(0); } catch (AbandonedMutexException) { held = true; }
                if (!held) { MessageBox.Show("\u7f16\u8f91\u5668\u5df2\u5728\u8fd0\u884c\uff0c\u8bf7\u4f7f\u7528\u5df2\u6253\u5f00\u7684\u7a97\u53e3\u3002", "LOLPallas"); return 0; }
                RunResult result = RunPowerShell(Under(assets,"Edit-Hotkeys-GUI.ps1"), "-Portable -Standalone -SourcePath " + Quote(Under(editor,"messages.json")) +
                    " -HostExecutable " + Quote(OwnExe) + " -HostExecutableHash " + Digest(File.ReadAllBytes(OwnExe)));
                if (result.code != 0) throw new IOException(result.output + "\r\n" + result.error);
                return 0;
            } finally { if (held) mutex.ReleaseMutex(); }
        }
    }
    static void Check(bool condition, string label) { if (!condition) throw new Exception("Self-test failed: " + label); }
    static void Refuse(Action action, string label) { bool refused = false; try { action(); } catch { refused = true; } Check(refused,label); }
    static int SelfTest() {
        string fixture = PlainPath(Path.Combine(Path.GetTempPath(), "LOLPallasExeTest-" + Guid.NewGuid().ToString("N")));
        string assets = EnsureAssets(fixture); Check(EnsureAssets(fixture) == assets,"cache reuse");
        Check(Quote(@"D:\") == String.Concat((char)34,"D:",new string((char)92,2),(char)34), "trailing slash quoting");
        Refuse(delegate { Quote("bad\"arg"); },"reject argument quote");
        Refuse(delegate { Under(assets,"../outside.ps1"); },"reject traversal");
        Refuse(delegate { PlainPath(@"\\server\share\app"); },"reject UNC");
        Refuse(delegate { Parse(new[]{"--action","install"}); },"reject incomplete action");
        Refuse(delegate { Parse(new[]{"--action","validate","--wegame","","--scheme","","--job",new string('a',32),"--sid","foreign"}); },"reject other account");
        string ownFixture = Under(assets,"messages.example.json");
        RunResult validation = Backend(assets,"Validate","",ownFixture,false); Check(validation.code == 0,"embedded PS validation");
        string securityProbe = Under(fixture,"security-module-probe.ps1");
        File.WriteAllText(securityProbe, "$ErrorActionPreference = 'Stop'\r\n[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)\r\n" +
            "Import-Module Microsoft.PowerShell.Security -ErrorAction Stop\r\n" +
            "$cmd = Get-Command Get-AuthenticodeSignature -CommandType Cmdlet\r\n" +
            "if (-not ($cmd.Module.ModuleBase.Equals($PSHOME,[StringComparison]::OrdinalIgnoreCase) -or $cmd.Module.ModuleBase.StartsWith(($PSHOME + '\\'),[StringComparison]::OrdinalIgnoreCase))) { throw 'Wrong Security module' }\r\n" +
            "if ((Get-AuthenticodeSignature -LiteralPath $PSCommandPath).Status.ToString() -ne 'NotSigned') { throw 'Own unsigned probe expected' }\r\n", Utf8);
        string inheritedModules = Environment.GetEnvironmentVariable("PSModulePath");
        RunResult security;
        try {
            Environment.SetEnvironmentVariable("PSModulePath", Under(fixture,"wrong-version-modules"));
            security = RunPowerShell(securityProbe, "");
        } finally { Environment.SetEnvironmentVariable("PSModulePath", inheritedModules); }
        Check(security.code == 0,"system PS5 Security module and real signature API despite inherited module pollution");
        RunResult gui = RunPowerShell(Under(assets,"Edit-Hotkeys-GUI.ps1"),"-Portable -Standalone -SelfTest"); Check(gui.code == 0,"detached embedded GUI");
        string editor = Under(fixture,"Editor"), source = Under(editor,"messages.json");
        RunResult initialize = RunPowerShell(Under(assets,"Edit-Hotkeys-GUI.ps1"),"-Portable -Standalone -InitializeOnly -SourcePath " + Quote(source) +
            " -HostExecutable " + Quote(OwnExe) + " -HostExecutableHash " + Digest(File.ReadAllBytes(OwnExe)));
        Check(initialize.code == 0 && File.Exists(source) && !File.Exists(Under(assets,"messages.json")),"source parameter uses persistent editor directory, not resource cache");
        string job = Guid.NewGuid().ToString("N");
        string[] action = {"--action","validate","--wegame","","--scheme",Convert.ToBase64String(Utf8.GetBytes(source)),"--job",job,"--sid",Sid};
        Check(Execute(action,fixture) == 0,"native action to PowerShell to structured result chain");
        var result = Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Under(editor,"jobs/" + job + ".json"),Utf8));
        Check((string)result["job"] == job && (string)result["sid"] == Sid && Convert.ToInt32(result["exit_code"]) == 0,"job/SID/result readback");
        Refuse(delegate { Execute(action,fixture); },"cannot overwrite operation result");
        // Corrupt only an owned isolated fixture, never production cache/data/components.
        File.WriteAllBytes(ownFixture,new byte[]{1,2,3});
        Refuse(delegate { EnsureAssets(fixture); },"reject modified cache without overwriting it");
        Check(File.ReadAllBytes(ownFixture).Length == 3,"modified fixture retained");
        Console.WriteLine(Json.Serialize(new { passed = true, checks = 16, fixture = fixture, gui = gui.output, validation = validation.output,
            no_live_install_or_game_sends = true, no_proprietary_dll_loaded = true })); return 0;
    }
    [STAThread]
    static int Main(string[] args) {
        bool test = args.Length == 1 && args[0] == "--self-test";
        try {
            try {
                Console.OutputEncoding = new UTF8Encoding(false);
                Console.SetError(new StreamWriter(Console.OpenStandardError(), Utf8) { AutoFlush = true });
            } catch (IOException) { }
            if (!Environment.Is64BitOperatingSystem || !Environment.Is64BitProcess) throw new PlatformNotSupportedException("64-bit Windows is required.");
            if (test) return SelfTest();
            if (args.Length != 0) return Execute(args,UserRoot);
            Application.EnableVisualStyles(); return OpenEditor();
        } catch (Exception e) {
            if (args.Length != 0) { try { Console.Error.WriteLine(test ? e.ToString() : e.Message); } catch (IOException) { } }
            else MessageBox.Show("\u7a0b\u5e8f\u672a\u80fd\u7ee7\u7eed\uff1a\r\n" + e.Message, "LOLPallas", MessageBoxButtons.OK,MessageBoxIcon.Warning);
            return 1;
        }
    }
}
