using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace PinSnip;

/// <summary>Everything the app remembers between runs. Only settings live on
/// disk — screenshots and pins never touch it.</summary>
internal sealed class AppSettings
{
    public string CaptureHotkey { get; set; } = "F1";
    public string PinHotkey { get; set; } = "F3";
    public string TogglePinsHotkey { get; set; } = "Shift+F3";
    public bool LaunchAtLogin { get; set; }
    public bool AutoScrollByDefault { get; set; }

    [JsonIgnore]
    public static string Folder => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PinSnip");

    [JsonIgnore]
    public static string FilePath => Path.Combine(Folder, "settings.json");

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true
    };

    public static AppSettings Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return new AppSettings();
            string json = File.ReadAllText(FilePath);
            return JsonSerializer.Deserialize<AppSettings>(json, Options) ?? new AppSettings();
        }
        catch (Exception ex)
        {
            App.Log($"settings load failed: {ex.Message}");
            return new AppSettings();
        }
    }

    public bool Save()
    {
        try
        {
            Directory.CreateDirectory(Folder);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Options));
            return true;
        }
        catch (Exception ex)
        {
            App.Log($"settings save failed: {ex.Message}");
            return false;
        }
    }
}

/// <summary>The HKCU Run entry used for "launch at login". No admin rights and
/// nothing outside the current user's hive.</summary>
internal static class LoginItem
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "PinSnip";

    private static string ExecutablePath =>
        Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "PinSnip.exe");

    public static bool IsEnabled()
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(RunKey, writable: false);
            string? value = key?.GetValue(ValueName) as string;
            return !string.IsNullOrEmpty(value);
        }
        catch
        {
            return false;
        }
    }

    public static void Set(bool enabled)
    {
        try
        {
            using RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            if (enabled)
            {
                key.SetValue(ValueName, $"\"{ExecutablePath}\"");
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }
        }
        catch (Exception ex)
        {
            App.Log($"login item failed: {ex.Message}");
        }
    }
}
