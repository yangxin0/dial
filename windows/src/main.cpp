// The dial on Windows: a layered, topmost window that never takes the
// focus, with an app ring around a microphone button. Clicking the button
// records through dial-core; the arrows turn the ring and scroll the app
// in front while the pointer is over the dial. dial-core (next to this
// exe) does the speech, the decision and the learned ring.
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define _WIN32_WINNT 0x0A00
#ifndef _USE_MATH_DEFINES
#define _USE_MATH_DEFINES
#endif
// windows.h's min/max macros break std::min; GDI+'s headers want plain
// min/max, so they get the std ones.
#define NOMINMAX
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
using std::max;
using std::min;

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <windowsx.h>
#include <objidl.h>
#include <gdiplus.h>
#include <shellapi.h>
#include <shlobj.h>
#include <dwmapi.h>
#include <mmdeviceapi.h>
#include <audioclient.h>

#include "json.h"

#ifndef AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
#define AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM 0x80000000
#endif
#ifndef AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY
#define AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY 0x08000000
#endif
#ifndef DWMWA_CLOAKED
#define DWMWA_CLOAKED 14
#endif

using namespace Gdiplus;

static const wchar_t* kVersion = L"0.1.0";
static const int kDefaultPort = 47831;
static const int kWidth = 200, kHeight = 240;
static const float kOuter = 86, kInner = 50, kButton = 40;
static const int kMaxSlots = 8;
static const int kChunkBytes = 6400;  // 200 ms of 16 kHz 16-bit mono

enum { WM_CORE_LINE = WM_APP + 1, WM_CORE_STATE = WM_APP + 2, WM_AUDIO_CHUNK = WM_APP + 3 };
enum Phase { Idle, Listening, Thinking };

// MARK: - Strings

static std::string narrow(const std::wstring& w) {
    if (w.empty()) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, 0);
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

static std::wstring widen(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w(n, 0);
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
    return w;
}

static std::string base64(const std::vector<char>& data) {
    static const char* chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve((data.size() + 2) / 3 * 4);
    size_t i = 0;
    while (i + 2 < data.size()) {
        uint32_t v = ((unsigned char)data[i] << 16) | ((unsigned char)data[i + 1] << 8) | (unsigned char)data[i + 2];
        out += chars[(v >> 18) & 63]; out += chars[(v >> 12) & 63]; out += chars[(v >> 6) & 63]; out += chars[v & 63];
        i += 3;
    }
    if (i + 1 == data.size()) {
        uint32_t v = (unsigned char)data[i] << 16;
        out += chars[(v >> 18) & 63]; out += chars[(v >> 12) & 63]; out += "==";
    } else if (i + 2 == data.size()) {
        uint32_t v = ((unsigned char)data[i] << 16) | ((unsigned char)data[i + 1] << 8);
        out += chars[(v >> 18) & 63]; out += chars[(v >> 12) & 63]; out += chars[(v >> 6) & 63]; out += '=';
    }
    return out;
}

// MARK: - Apps

struct AppInfo {
    std::string id;     // the exe's path, lowercased; or a Start Menu shortcut's
    std::wstring name;
    bool running = false;
    bool active = false;
    HWND window = nullptr;
    std::wstring path;
    std::shared_ptr<Bitmap> icon;
};

static std::wstring fileDescription(const std::wstring& path) {
    DWORD handle = 0;
    DWORD size = GetFileVersionInfoSizeW(path.c_str(), &handle);
    if (!size) return L"";
    std::vector<char> data(size);
    if (!GetFileVersionInfoW(path.c_str(), 0, size, data.data())) return L"";
    struct { WORD language, codepage; }* translations = nullptr;
    UINT count = 0;
    if (!VerQueryValueW(data.data(), L"\\VarFileInfo\\Translation", (void**)&translations, &count) || count < 4) return L"";
    wchar_t key[64];
    swprintf(key, 64, L"\\StringFileInfo\\%04x%04x\\FileDescription", translations[0].language, translations[0].codepage);
    wchar_t* value = nullptr;
    if (!VerQueryValueW(data.data(), key, (void**)&value, &count) || !value || !count) return L"";
    return std::wstring(value);
}

static std::wstring baseName(const std::wstring& path) {
    size_t slash = path.find_last_of(L"\\/");
    std::wstring name = slash == std::wstring::npos ? path : path.substr(slash + 1);
    size_t dot = name.find_last_of(L'.');
    if (dot != std::wstring::npos) name = name.substr(0, dot);
    return name;
}

static std::shared_ptr<Bitmap> iconOf(const std::wstring& path) {
    SHFILEINFOW info = {};
    if (!SHGetFileInfoW(path.c_str(), 0, &info, sizeof info, SHGFI_ICON | SHGFI_LARGEICON) || !info.hIcon) return nullptr;
    auto bitmap = std::shared_ptr<Bitmap>(Bitmap::FromHICON(info.hIcon));
    DestroyIcon(info.hIcon);
    return bitmap;
}

struct AppList {
    std::vector<AppInfo> running;
    std::vector<AppInfo> installed;
    std::map<std::string, std::shared_ptr<Bitmap>> icons;
    HWND self = nullptr;

    static BOOL CALLBACK enumWindow(HWND hwnd, LPARAM lparam) {
        auto* out = (std::vector<HWND>*)lparam;
        if (!IsWindowVisible(hwnd) || GetWindow(hwnd, GW_OWNER) != nullptr) return TRUE;
        if (GetWindowTextLengthW(hwnd) == 0) return TRUE;
        LONG ex = GetWindowLongW(hwnd, GWL_EXSTYLE);
        if (ex & WS_EX_TOOLWINDOW) return TRUE;
        int cloaked = 0;
        if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof cloaked)) && cloaked) return TRUE;
        wchar_t cls[64] = {};
        GetClassNameW(hwnd, cls, 64);
        if (!wcscmp(cls, L"Progman") || !wcscmp(cls, L"Shell_TrayWnd") || !wcscmp(cls, L"Windows.UI.Core.CoreWindow")) return TRUE;
        out->push_back(hwnd);
        return TRUE;
    }

    static std::wstring exeOf(HWND hwnd) {
        DWORD pid = 0;
        GetWindowThreadProcessId(hwnd, &pid);
        HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (!process) return L"";
        wchar_t path[MAX_PATH * 2];
        DWORD size = MAX_PATH * 2;
        std::wstring out;
        if (QueryFullProcessImageNameW(process, 0, path, &size)) out.assign(path, size);
        CloseHandle(process);
        return out;
    }

    // The running apps in Z order (the most recently used first), one per
    // executable, with the frontmost marked.
    void refresh() {
        std::vector<HWND> windows;
        EnumWindows(enumWindow, (LPARAM)&windows);
        HWND front = GetForegroundWindow();
        std::vector<AppInfo> list;
        for (HWND hwnd : windows) {
            if (hwnd == self) continue;
            std::wstring exe = exeOf(hwnd);
            if (exe.empty()) continue;
            std::string id = narrow(exe);
            std::transform(id.begin(), id.end(), id.begin(), [](unsigned char c) { return (char)tolower(c); });
            bool seen = false;
            for (auto& a : list) if (a.id == id) { seen = true; if (hwnd == front) { a.active = true; a.window = hwnd; } }
            if (seen) continue;
            AppInfo app;
            app.id = id;
            app.path = exe;
            app.window = hwnd;
            app.running = true;
            app.active = hwnd == front;
            app.name = fileDescription(exe);
            if (app.name.empty()) app.name = baseName(exe);
            auto it = icons.find(id);
            if (it == icons.end()) it = icons.emplace(id, iconOf(exe)).first;
            app.icon = it->second;
            list.push_back(app);
        }
        // The frontmost app first, the rest in Z order.
        std::stable_sort(list.begin(), list.end(), [](const AppInfo& a, const AppInfo& b) { return a.active && !b.active; });
        running = list;
    }

    static void scanShortcuts(const std::wstring& folder, std::vector<AppInfo>& out, int depth) {
        if (depth > 3 || out.size() > 200) return;
        WIN32_FIND_DATAW found;
        HANDLE h = FindFirstFileW((folder + L"\\*").c_str(), &found);
        if (h == INVALID_HANDLE_VALUE) return;
        do {
            std::wstring name = found.cFileName;
            if (name == L"." || name == L"..") continue;
            std::wstring path = folder + L"\\" + name;
            if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) { scanShortcuts(path, out, depth + 1); continue; }
            if (name.size() > 4 && _wcsicmp(name.c_str() + name.size() - 4, L".lnk") == 0) {
                std::wstring title = name.substr(0, name.size() - 4);
                if (title.find(L"Uninstall") != std::wstring::npos || title.find(L"卸载") != std::wstring::npos) continue;
                AppInfo app;
                app.id = narrow(path);
                app.path = path;
                app.name = title;
                out.push_back(app);
            }
        } while (FindNextFileW(h, &found));
        FindClose(h);
    }

    // The Start Menu's shortcuts: names to open by voice.
    void scanInstalled() {
        std::vector<AppInfo> list;
        wchar_t path[MAX_PATH];
        if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_COMMON_PROGRAMS, nullptr, 0, path))) scanShortcuts(path, list, 0);
        if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_PROGRAMS, nullptr, 0, path))) scanShortcuts(path, list, 0);
        std::sort(list.begin(), list.end(), [](const AppInfo& a, const AppInfo& b) { return _wcsicmp(a.name.c_str(), b.name.c_str()) < 0; });
        installed = list;
    }

    const AppInfo* find(const std::string& id) const {
        for (auto& a : running) if (a.id == id) return &a;
        for (auto& a : installed) if (a.id == id) return &a;
        return nullptr;
    }

    // Brings a window to the front from a window that never has the focus:
    // the foreground lock yields to the thread that owns the foreground
    // window, so borrow its input for the call.
    static void bringToFront(HWND hwnd) {
        if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        DWORD foreground = GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
        DWORD self = GetCurrentThreadId();
        bool attached = foreground && foreground != self && AttachThreadInput(foreground, self, TRUE);
        SetForegroundWindow(hwnd);
        BringWindowToTop(hwnd);
        if (attached) AttachThreadInput(foreground, self, FALSE);
        if (GetForegroundWindow() != hwnd) {
            // The old trick: a tap of Alt unlocks SetForegroundWindow.
            keybd_event(VK_MENU, 0, KEYEVENTF_EXTENDEDKEY, 0);
            keybd_event(VK_MENU, 0, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, 0);
            SetForegroundWindow(hwnd);
        }
    }

    void activate(const std::string& id) {
        const AppInfo* app = find(id);
        if (!app) return;
        if (app->running && app->window) { bringToFront(app->window); return; }
        ShellExecuteW(nullptr, L"open", app->path.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    }

    json::Value records() const {
        json::Array items;
        for (auto& a : running) {
            json::Object o{{"id", a.id}, {"name", narrow(a.name)}, {"running", true}};
            if (a.active) o["active"] = true;
            items.push_back(o);
        }
        for (auto& a : installed) {
            bool dup = false;
            for (auto& r : running) if (_wcsicmp(r.name.c_str(), a.name.c_str()) == 0) dup = true;
            if (dup) continue;
            items.push_back(json::Object{{"id", a.id}, {"name", narrow(a.name)}, {"running", false}});
        }
        return items;
    }
};

// MARK: - Input to the app in front

namespace input {

static HWND frontTarget(POINT* where) {
    HWND front = GetForegroundWindow();
    if (!front) return nullptr;
    RECT r;
    if (!GetWindowRect(front, &r)) return nullptr;
    POINT p = {(r.left + r.right) / 2, (r.top + r.bottom) / 2};
    if (where) *where = p;
    HWND under = WindowFromPoint(p);
    return under ? under : front;
}

static void scroll(int lines) {
    POINT p;
    HWND target = frontTarget(&p);
    if (!target) return;
    PostMessageW(target, WM_MOUSEWHEEL, MAKEWPARAM(0, (short)(lines * WHEEL_DELTA)), MAKELPARAM(p.x, p.y));
}

static void key(WORD vk, bool ctrl = false) {
    INPUT in[4] = {};
    int n = 0;
    if (ctrl) { in[n].type = INPUT_KEYBOARD; in[n].ki.wVk = VK_CONTROL; n++; }
    in[n].type = INPUT_KEYBOARD; in[n].ki.wVk = vk; n++;
    in[n].type = INPUT_KEYBOARD; in[n].ki.wVk = vk; in[n].ki.dwFlags = KEYEVENTF_KEYUP; n++;
    if (ctrl) { in[n].type = INPUT_KEYBOARD; in[n].ki.wVk = VK_CONTROL; in[n].ki.dwFlags = KEYEVENTF_KEYUP; n++; }
    SendInput(n, in, sizeof(INPUT));
}

static void pageTop() { key(VK_HOME); }
static void pageBottom() { key(VK_END); }
static void closeWindow() { key('W', true); }

static void type(const std::wstring& text) {
    std::vector<INPUT> in;
    for (wchar_t c : text) {
        INPUT down = {};
        down.type = INPUT_KEYBOARD;
        down.ki.wScan = c;
        down.ki.dwFlags = KEYEVENTF_UNICODE;
        INPUT up = down;
        up.ki.dwFlags |= KEYEVENTF_KEYUP;
        in.push_back(down);
        in.push_back(up);
    }
    for (size_t i = 0; i < in.size(); i += 40) {
        SendInput((UINT)std::min<size_t>(40, in.size() - i), &in[i], sizeof(INPUT));
        Sleep(4);
    }
}

}  // namespace input

// MARK: - The core

struct Core {
    HWND owner = nullptr;
    int port = kDefaultPort;
    SOCKET sock = INVALID_SOCKET;
    std::atomic<bool> connected{false};
    std::atomic<bool> stopping{false};
    std::thread reader;
    std::mutex sendMu;
    PROCESS_INFORMATION process = {};
    int attempts = 0;

    void start() {
        WSADATA wsa;
        WSAStartup(MAKEWORD(2, 2), &wsa);
        connect();
    }

    void stop() {
        stopping = true;
        drop();
        if (process.hProcess) {
            TerminateProcess(process.hProcess, 0);
            CloseHandle(process.hProcess);
            CloseHandle(process.hThread);
            process = {};
        }
        if (reader.joinable()) reader.join();
        WSACleanup();
    }

    void drop() {
        connected = false;
        if (sock != INVALID_SOCKET) {
            closesocket(sock);
            sock = INVALID_SOCKET;
        }
    }

    void connect() {
        if (stopping) return;
        if (reader.joinable()) reader.join();
        SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        sockaddr_in addr = {};
        addr.sin_family = AF_INET;
        addr.sin_port = htons((u_short)port);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (::connect(s, (sockaddr*)&addr, sizeof addr) != 0) {
            closesocket(s);
            attempts++;
            if (attempts == 1 || (attempts % 10 == 0 && !processAlive())) launch();
            SetTimer(owner, 2, (UINT)std::min(300 * attempts, 3000), nullptr);
            return;
        }
        attempts = 0;
        sock = s;
        connected = true;
        reader = std::thread([this, s] { read(s); });
        PostMessageW(owner, WM_CORE_STATE, 1, 0);
    }

    bool processAlive() {
        if (!process.hProcess) return false;
        DWORD code = 0;
        return GetExitCodeProcess(process.hProcess, &code) && code == STILL_ACTIVE;
    }

    // dial-core.exe next to this exe.
    void launch() {
        if (processAlive()) return;
        wchar_t path[MAX_PATH];
        GetModuleFileNameW(nullptr, path, MAX_PATH);
        std::wstring dir = path;
        size_t slash = dir.find_last_of(L"\\/");
        dir = dir.substr(0, slash);
        std::wstring exe = dir + L"\\dial-core.exe";
        std::wstring cmd = L"\"" + exe + L"\"";
        STARTUPINFOW si = {};
        si.cb = sizeof si;
        PROCESS_INFORMATION pi = {};
        if (CreateProcessW(exe.c_str(), &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, dir.c_str(), &si, &pi)) {
            process = pi;
        }
    }

    void read(SOCKET s) {
        std::string buffer;
        char chunk[65536];
        while (!stopping) {
            int n = recv(s, chunk, sizeof chunk, 0);
            if (n <= 0) break;
            buffer.append(chunk, n);
            size_t nl;
            while ((nl = buffer.find('\n')) != std::string::npos) {
                std::string line = buffer.substr(0, nl);
                buffer.erase(0, nl + 1);
                if (!line.empty()) PostMessageW(owner, WM_CORE_LINE, 0, (LPARAM) new std::string(line));
            }
        }
        if (!stopping) PostMessageW(owner, WM_CORE_STATE, 0, 0);
    }

    void send(const json::Value& message) {
        if (!connected) return;
        std::string line = json::serialize(message) + "\n";
        std::lock_guard<std::mutex> lock(sendMu);
        size_t at = 0;
        while (at < line.size()) {
            int n = ::send(sock, line.data() + at, (int)(line.size() - at), 0);
            if (n <= 0) break;
            at += n;
        }
    }
};

// MARK: - The microphone (WASAPI, converted to 16 kHz 16-bit mono)

struct MicCapture {
    HWND owner = nullptr;
    std::thread thread;
    std::atomic<bool> running{false};

    bool start() {
        if (running) return true;
        running = true;
        thread = std::thread([this] { capture(); });
        return true;
    }

    void stop() {
        running = false;
        if (thread.joinable()) thread.join();
    }

    void capture() {
        CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        IMMDeviceEnumerator* enumerator = nullptr;
        IMMDevice* device = nullptr;
        IAudioClient* client = nullptr;
        IAudioCaptureClient* capture = nullptr;
        std::vector<char> pending;
        bool failed = true;
        do {
            if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), (void**)&enumerator))) break;
            if (FAILED(enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device))) break;
            if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&client))) break;
            WAVEFORMATEX fmt = {};
            fmt.wFormatTag = WAVE_FORMAT_PCM;
            fmt.nChannels = 1;
            fmt.nSamplesPerSec = 16000;
            fmt.wBitsPerSample = 16;
            fmt.nBlockAlign = 2;
            fmt.nAvgBytesPerSec = 32000;
            if (FAILED(client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                                          10000000, 0, &fmt, nullptr))) break;
            if (FAILED(client->GetService(__uuidof(IAudioCaptureClient), (void**)&capture))) break;
            if (FAILED(client->Start())) break;
            failed = false;
            while (running) {
                Sleep(40);
                UINT32 packet = 0;
                while (SUCCEEDED(capture->GetNextPacketSize(&packet)) && packet > 0) {
                    BYTE* data = nullptr;
                    UINT32 frames = 0;
                    DWORD flags = 0;
                    if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) break;
                    size_t bytes = frames * 2;
                    if (flags & AUDCLNT_BUFFERFLAGS_SILENT) pending.insert(pending.end(), bytes, 0);
                    else pending.insert(pending.end(), (char*)data, (char*)data + bytes);
                    capture->ReleaseBuffer(frames);
                    while (pending.size() >= (size_t)kChunkBytes) {
                        auto* chunk = new std::vector<char>(pending.begin(), pending.begin() + kChunkBytes);
                        pending.erase(pending.begin(), pending.begin() + kChunkBytes);
                        PostMessageW(owner, WM_AUDIO_CHUNK, 0, (LPARAM)chunk);
                    }
                    if (!running) break;
                }
            }
            if (!pending.empty()) PostMessageW(owner, WM_AUDIO_CHUNK, 1, (LPARAM) new std::vector<char>(pending));
            client->Stop();
        } while (false);
        if (failed) PostMessageW(owner, WM_AUDIO_CHUNK, 2, 0);
        if (capture) capture->Release();
        if (client) client->Release();
        if (device) device->Release();
        if (enumerator) enumerator->Release();
        CoUninitialize();
    }
};

// MARK: - The dial

struct Dial {
    HWND hwnd = nullptr;
    HHOOK hook = nullptr;
    Core core;
    MicCapture mic;
    AppList apps;
    Phase phase = Idle;
    std::vector<std::string> ring;
    std::string activeID;
    std::wstring transcript, hint;
    bool hintIsError = false;
    bool armed = false;
    bool tracking = false;
    bool coreListening = false;
    bool micRunning = false;
    std::vector<std::vector<char>> pendingAudio;
    std::map<std::string, bool> ready;
    float pulse = 0;
    POINT dragStart = {};
    bool dragging = false, pressed = false;
    int wheelX = 0, wheelY = 0;
    bool dark = false;

    POINT center() const { return {kWidth / 2, 8 + (int)kOuter}; }

    static bool darkMode() {
        DWORD value = 1, size = sizeof value;
        if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                         L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size) == ERROR_SUCCESS) return value == 0;
        return false;
    }

    // MARK: Messages from the core

    void handleLine(const std::string& line) {
        json::Value m;
        if (!json::parse(line, m) || !m.isObject()) return;
        std::string type = m["type"].str();
        if (type == "hello") {
            ready.clear();
            if (m["ready"].isObject()) for (auto& [k, v] : *m["ready"].o) ready[k] = v.boolean();
            if (!ready["voice"]) showHint(L"Open Dial Settings to add your 豆包 key.", true);
            else if (!ready["jev"]) showHint(L"Ready. Without a Jev key, a few plain rules tell commands from text.");
            else showHint(L"Ready.");
        } else if (type == "ring") {
            ring.clear();
            for (auto& id : m["ring"].items()) ring.push_back(id.str());
            redraw();
        } else if (type == "state") {
            std::string p = m["phase"].str();
            if (p == "listening") {
                coreListening = true;
                auto pending = std::move(pendingAudio);
                pendingAudio.clear();
                for (auto& chunk : pending) sendAudio(chunk);
                if (phase == Listening && !micRunning) { core.send(json::Object{{"type", "stop"}}); setPhase(Thinking); }
            } else if (p == "idle") {
                coreListening = false;
                if (micRunning) { mic.stop(); micRunning = false; }
                setPhase(Idle);
            } else if (p == "thinking") {
                coreListening = false;
                setPhase(Thinking);
            }
        } else if (type == "heard") {
            transcript = widen(m["text"].str());
            redraw();
        } else if (type == "result") {
            act(m);
        } else if (type == "error") {
            if (micRunning) { mic.stop(); micRunning = false; }
            pendingAudio.clear();
            setPhase(Idle);
            showHint(widen(m["message"].str("Something went wrong.")), true);
        }
    }

    void act(const json::Value& m) {
        if (m["intent"].str() != "command") {
            std::string text = m["text"].str();
            if (text.empty()) text = m["transcript"].str();
            if (text.empty()) { showHint(L"Didn't hear anything."); return; }
            input::type(widen(text));
            showHint(widen(text));
            return;
        }
        std::string action = m["action"].str();
        if (action == "switch_app" || action == "open_app") {
            std::string id = m["app"].str();
            if (id.empty()) { showHint(widen(m["message"].str("Which app?")), true); return; }
            apps.activate(id);
            learned(id);
            showHint(L"→ " + widen(m["appName"].str(id)));
        } else if (action == "scroll_up") { input::scroll(10); showHint(L"↑ scroll"); }
        else if (action == "scroll_down") { input::scroll(-10); showHint(L"↓ scroll"); }
        else if (action == "page_top") { input::pageTop(); showHint(L"⤒ top"); }
        else if (action == "page_bottom") { input::pageBottom(); showHint(L"⤓ bottom"); }
        else if (action == "close_window") { input::closeWindow(); showHint(L"Ctrl+W"); }
        else showHint(widen(m["message"].str("That sounded like a command the dial doesn't know.")), true);
    }

    // MARK: The ring

    void sendApps() {
        apps.refresh();
        core.send(json::Object{{"type", "apps"}, {"apps", apps.records()}});
        for (auto& a : apps.running) if (a.active) activeID = a.id;
        redraw();
    }

    void learned(const std::string& id) {
        core.send(json::Object{{"type", "switched"}, {"app", id}});
    }

    void pick(const std::string& id) {
        apps.activate(id);
        activeID = id;
        learned(id);
        redraw();
    }

    void turnRing(int delta) {
        if (ring.empty()) { showHint(L"No apps on the ring yet."); return; }
        int current = -1;
        for (size_t i = 0; i < ring.size(); i++) if (ring[i] == activeID) current = (int)i;
        if (current < 0) current = delta > 0 ? -1 : 0;
        int next = ((current + delta) % (int)ring.size() + (int)ring.size()) % (int)ring.size();
        pick(ring[next]);
    }

    // MARK: Listening

    void toggleListening() {
        if (phase == Idle) startListening();
        else if (phase == Listening) stopListening();
    }

    void startListening() {
        if (!core.connected) { showHint(L"dial-core isn't running yet.", true); return; }
        if (!ready["voice"]) { showHint(L"Set up the speech engine in Dial Settings first.", true); return; }
        pendingAudio.clear();
        coreListening = false;
        transcript.clear();
        mic.owner = hwnd;
        mic.start();
        micRunning = true;
        setPhase(Listening);
        core.send(json::Object{{"type", "start"}});
    }

    void stopListening() {
        if (micRunning) { mic.stop(); micRunning = false; }
        // The thread's last chunk arrives as a message; the stop goes
        // after it on the queue.
        PostMessageW(hwnd, WM_AUDIO_CHUNK, 3, 0);
        setPhase(Thinking);
    }

    void cancelListening() {
        if (phase == Idle) return;
        if (micRunning) { mic.stop(); micRunning = false; }
        pendingAudio.clear();
        core.send(json::Object{{"type", "cancel"}});
        setPhase(Idle);
        transcript.clear();
        redraw();
    }

    void sendAudio(const std::vector<char>& chunk) {
        if (!coreListening) {
            pendingAudio.push_back(chunk);
            if (pendingAudio.size() > 50) pendingAudio.erase(pendingAudio.begin());
            return;
        }
        core.send(json::Object{{"type", "audio"}, {"pcm", base64(chunk)}});
    }

    void audioMessage(WPARAM what, LPARAM lparam) {
        if (what == 0 || what == 1) {
            std::unique_ptr<std::vector<char>> chunk((std::vector<char>*)lparam);
            if (chunk && !chunk->empty() && phase != Idle) sendAudio(*chunk);
        } else if (what == 2) {
            showHint(L"Can't record: no microphone, or no permission (Settings ▸ Privacy ▸ Microphone).", true);
            micRunning = false;
            cancelListening();
        } else if (what == 3) {
            core.send(json::Object{{"type", "stop"}});
        }
    }

    void setPhase(Phase p) {
        phase = p;
        if (p == Idle) KillTimer(hwnd, 1);
        else SetTimer(hwnd, 1, 33, nullptr);
        redraw();
    }

    void showHint(const std::wstring& text, bool error = false) {
        hint = text;
        hintIsError = error;
        SetTimer(hwnd, 3, error ? 8000 : 4000, nullptr);
        redraw();
    }

    // MARK: Keys, while the pointer is over the dial

    bool handleKey(DWORD vk) {
        if (!armed) return false;
        if (GetAsyncKeyState(VK_CONTROL) < 0 || GetAsyncKeyState(VK_MENU) < 0 || GetAsyncKeyState(VK_LWIN) < 0) return false;
        switch (vk) {
            case VK_LEFT: turnRing(-1); return true;
            case VK_RIGHT: turnRing(1); return true;
            case VK_UP: input::scroll(3); return true;
            case VK_DOWN: input::scroll(-3); return true;
            case VK_SPACE: case VK_RETURN: toggleListening(); return true;
            case VK_ESCAPE: cancelListening(); return true;
        }
        return false;
    }

    // MARK: Geometry

    PointF slotCenter(int index, int count) const {
        float angle = (float)M_PI / 2 - (float)index * 2 * (float)M_PI / (float)count;
        float radius = (kOuter + kInner) / 2;
        POINT c = center();
        return PointF(c.x + radius * cosf(angle), c.y - radius * sinf(angle));
    }

    int slotAt(POINT p) const {
        POINT c = center();
        float dx = (float)(p.x - c.x), dy = (float)(c.y - p.y);
        float d = sqrtf(dx * dx + dy * dy);
        if (d < kInner || d > kOuter || ring.empty()) return -1;
        float angle = atan2f(dy, dx);
        float turn = ((float)M_PI / 2 - angle) / (2 * (float)M_PI);
        while (turn < 0) turn += 1;
        int n = (int)std::min<size_t>(ring.size(), kMaxSlots);
        return (int)floorf(turn * n + 0.5f) % n;
    }

    bool inButton(POINT p) const {
        POINT c = center();
        float dx = (float)(p.x - c.x), dy = (float)(p.y - c.y);
        return sqrtf(dx * dx + dy * dy) <= kButton;
    }

    // MARK: Drawing, into a layered window

    void redraw() {
        if (!hwnd) return;
        dark = darkMode();
        HDC screen = GetDC(nullptr);
        HDC memory = CreateCompatibleDC(screen);
        BITMAPINFO bmi = {};
        bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = kWidth;
        bmi.bmiHeader.biHeight = -kHeight;
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB;
        void* bits = nullptr;
        HBITMAP bitmap = CreateDIBSection(memory, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
        HGDIOBJ old = SelectObject(memory, bitmap);
        {
            Graphics g(memory);
            g.SetSmoothingMode(SmoothingModeAntiAlias);
            g.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
            g.SetInterpolationMode(InterpolationModeHighQualityBicubic);
            g.Clear(Color(0, 0, 0, 0));
            paint(g);
        }
        POINT origin = {0, 0};
        SIZE size = {kWidth, kHeight};
        BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
        RECT r;
        GetWindowRect(hwnd, &r);
        POINT at = {r.left, r.top};
        UpdateLayeredWindow(hwnd, screen, &at, &size, memory, &origin, 0, &blend, ULW_ALPHA);
        SelectObject(memory, old);
        DeleteObject(bitmap);
        DeleteDC(memory);
        ReleaseDC(nullptr, screen);
    }

    void paint(Graphics& g) {
        Color surface = dark ? Color(240, 36, 36, 40) : Color(240, 247, 247, 250);
        Color edge = dark ? Color(30, 255, 255, 255) : Color(30, 0, 0, 0);
        Color accent = dark ? Color(255, 120, 150, 255) : Color(255, 0, 103, 192);
        Color label = dark ? Color(255, 235, 235, 240) : Color(255, 28, 28, 33);
        POINT c = center();

        // The ring, with a soft shadow.
        for (int i = 6; i >= 1; i--) {
            SolidBrush shadow(Color((BYTE)(dark ? 18 : 10), 0, 0, 0));
            g.FillEllipse(&shadow, c.x - kOuter - i, c.y - kOuter - i + 2, (kOuter + i) * 2, (kOuter + i) * 2);
        }
        SolidBrush fill(surface);
        g.FillEllipse(&fill, c.x - kOuter, c.y - kOuter, kOuter * 2, kOuter * 2);
        Pen outline(armed ? accent : edge, armed ? 2.0f : 1.0f);
        g.DrawEllipse(&outline, c.x - kOuter, c.y - kOuter, kOuter * 2, kOuter * 2);

        // The slots.
        int count = (int)std::min<size_t>(ring.size(), kMaxSlots);
        for (int i = 0; i < count; i++) {
            const AppInfo* app = apps.find(ring[i]);
            PointF at = slotCenter(i, count);
            if (ring[i] == activeID) {
                SolidBrush glow(Color(70, accent.GetR(), accent.GetG(), accent.GetB()));
                g.FillEllipse(&glow, at.X - 19, at.Y - 19, 38.0f, 38.0f);
                Pen rim(accent, 1.5f);
                g.DrawEllipse(&rim, at.X - 19, at.Y - 19, 38.0f, 38.0f);
            }
            if (app && app->icon) {
                g.DrawImage(app->icon.get(), at.X - 15, at.Y - 15, 30.0f, 30.0f);
            } else {
                std::wstring initial = app && !app->name.empty() ? app->name.substr(0, 1) : L"?";
                Font font(L"Segoe UI", 14, FontStyleBold);
                SolidBrush brush(label);
                StringFormat format;
                format.SetAlignment(StringAlignmentCenter);
                format.SetLineAlignment(StringAlignmentCenter);
                g.DrawString(initial.c_str(), -1, &font, RectF(at.X - 15, at.Y - 15, 30, 30), &format, &brush);
            }
        }
        if (count == 0) {
            Font font(L"Segoe UI", 8);
            SolidBrush brush(Color(120, label.GetR(), label.GetG(), label.GetB()));
            StringFormat format;
            format.SetAlignment(StringAlignmentCenter);
            g.DrawString(L"← apps →", -1, &font, RectF(0, (float)c.y - kInner - 24, kWidth, 16), &format, &brush);
        }

        // The pulse.
        if (phase != Idle) {
            float grow = 4 + 4 * (1 + sinf(pulse)) / 2;
            Color tint = phase == Listening ? Color(60, 255, 59, 48) : Color(60, 0, 122, 255);
            SolidBrush brush(tint);
            g.FillEllipse(&brush, c.x - kButton - grow, c.y - kButton - grow, (kButton + grow) * 2, (kButton + grow) * 2);
        }

        // The button.
        Color buttonFill = phase == Listening ? Color(255, 255, 59, 48) : phase == Thinking ? Color(255, 0, 122, 255)
                                                                         : dark ? Color(255, 62, 62, 68) : Color(255, 255, 255, 255);
        SolidBrush button(buttonFill);
        g.FillEllipse(&button, c.x - kButton, c.y - kButton, kButton * 2, kButton * 2);
        Pen buttonEdge(edge, 1.0f);
        g.DrawEllipse(&buttonEdge, c.x - kButton, c.y - kButton, kButton * 2, kButton * 2);
        // A microphone, drawn: a capsule, a cradle, a stem.
        Color glyph = phase == Idle ? label : Color(255, 255, 255, 255);
        if (phase == Thinking) {
            SolidBrush dots(glyph);
            for (int i = -1; i <= 1; i++) g.FillEllipse(&dots, c.x + i * 11 - 3.5f, c.y - 3.5f, 7.0f, 7.0f);
        } else {
            SolidBrush brush(glyph);
            Pen pen(glyph, 2.5f);
            pen.SetStartCap(LineCapRound);
            pen.SetEndCap(LineCapRound);
            GraphicsPath capsule;
            capsule.AddArc(c.x - 6.0f, c.y - 16.0f, 12.0f, 12.0f, 180, 180);
            capsule.AddArc(c.x - 6.0f, c.y - 6.0f, 12.0f, 12.0f, 0, 180);
            capsule.CloseFigure();
            g.FillPath(&brush, &capsule);
            g.DrawArc(&pen, c.x - 11.0f, c.y - 10.0f, 22.0f, 22.0f, 10, 160);
            g.DrawLine(&pen, (float)c.x, c.y + 12.0f, (float)c.x, c.y + 17.0f);
            g.DrawLine(&pen, c.x - 6.0f, c.y + 17.0f, c.x + 6.0f, c.y + 17.0f);
        }

        // What was heard, or a hint, underneath.
        std::wstring text = hint.empty() ? transcript : hint;
        if (text.empty()) return;
        bool error = !hint.empty() && hintIsError;
        RectF bubble(6, kHeight - 46, kWidth - 12, 40);
        GraphicsPath path;
        float r = 10;
        path.AddArc(bubble.X, bubble.Y, 2 * r, 2 * r, 180, 90);
        path.AddArc(bubble.GetRight() - 2 * r, bubble.Y, 2 * r, 2 * r, 270, 90);
        path.AddArc(bubble.GetRight() - 2 * r, bubble.GetBottom() - 2 * r, 2 * r, 2 * r, 0, 90);
        path.AddArc(bubble.X, bubble.GetBottom() - 2 * r, 2 * r, 2 * r, 90, 90);
        path.CloseFigure();
        SolidBrush bubbleFill(error ? (dark ? Color(90, 255, 59, 48) : Color(46, 255, 59, 48)) : surface);
        g.FillPath(&bubbleFill, &path);
        Pen bubbleEdge(edge, 1.0f);
        g.DrawPath(&bubbleEdge, &path);
        Font font(L"Segoe UI", 9);
        SolidBrush brush(label);
        StringFormat format;
        format.SetAlignment(StringAlignmentCenter);
        format.SetLineAlignment(StringAlignmentCenter);
        format.SetTrimming(StringTrimmingEllipsisCharacter);
        g.DrawString(text.c_str(), -1, &font, RectF(bubble.X + 8, bubble.Y + 3, bubble.Width - 16, bubble.Height - 6), &format, &brush);
    }

    // MARK: Window position

    void savePosition() {
        RECT r;
        if (!GetWindowRect(hwnd, &r)) return;
        HKEY key;
        if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Dial", 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr) != ERROR_SUCCESS) return;
        DWORD x = (DWORD)r.left, y = (DWORD)r.top;
        RegSetValueExW(key, L"x", 0, REG_DWORD, (BYTE*)&x, sizeof x);
        RegSetValueExW(key, L"y", 0, REG_DWORD, (BYTE*)&y, sizeof y);
        RegCloseKey(key);
    }

    POINT restorePosition() {
        DWORD x = 0, y = 0, size = sizeof x;
        if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Dial", L"x", RRF_RT_REG_DWORD, nullptr, &x, &size) == ERROR_SUCCESS &&
            RegGetValueW(HKEY_CURRENT_USER, L"Software\\Dial", L"y", RRF_RT_REG_DWORD, nullptr, &y, &size) == ERROR_SUCCESS) {
            POINT p = {(LONG)x, (LONG)y};
            if (MonitorFromPoint(p, MONITOR_DEFAULTTONULL)) return p;
        }
        RECT work;
        SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
        return {work.right - kWidth - 24, work.bottom - kHeight - 24};
    }
};

static Dial* g_dial = nullptr;

static LRESULT CALLBACK keyboardHook(int code, WPARAM wparam, LPARAM lparam) {
    if (code == HC_ACTION && g_dial && (wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN)) {
        auto* k = (KBDLLHOOKSTRUCT*)lparam;
        if (!(k->flags & LLKHF_INJECTED) && g_dial->handleKey(k->vkCode)) return 1;
    }
    return CallNextHookEx(nullptr, code, wparam, lparam);
}

static LRESULT CALLBACK windowProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    Dial* d = g_dial;
    switch (msg) {
        case WM_CORE_LINE: {
            std::unique_ptr<std::string> line((std::string*)lparam);
            if (d && line) d->handleLine(*line);
            return 0;
        }
        case WM_CORE_STATE:
            if (!d) return 0;
            if (wparam == 1) {
                d->core.send(json::Object{{"type", "hello"}, {"platform", "windows"}, {"version", narrow(kVersion)}});
                d->sendApps();
            } else {
                d->core.drop();
                if (d->micRunning) { d->mic.stop(); d->micRunning = false; }
                d->setPhase(Idle);
                d->showHint(L"dial-core went away, reconnecting…", true);
                d->core.connect();
            }
            return 0;
        case WM_AUDIO_CHUNK:
            if (d) d->audioMessage(wparam, lparam);
            return 0;
        case WM_TIMER:
            if (!d) return 0;
            if (wparam == 1) { d->pulse += 0.12f; d->redraw(); }
            else if (wparam == 2) { KillTimer(hwnd, 2); d->core.connect(); }
            else if (wparam == 3) { KillTimer(hwnd, 3); d->hint.clear(); d->redraw(); }
            else if (wparam == 4) { d->sendApps(); }
            return 0;
        case WM_MOUSEMOVE:
            if (d && !d->tracking) {
                TRACKMOUSEEVENT t = {sizeof t, TME_LEAVE, hwnd, 0};
                TrackMouseEvent(&t);
                d->tracking = true;
                d->armed = true;
                d->redraw();
            }
            if (d && d->pressed && !d->dragging) {
                POINT p = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
                if (abs(p.x - d->dragStart.x) > 4 || abs(p.y - d->dragStart.y) > 4) {
                    d->dragging = true;
                    ReleaseCapture();
                    SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
                    d->pressed = false;
                    d->savePosition();
                }
            }
            return 0;
        case WM_MOUSELEAVE:
            if (d) { d->tracking = false; d->armed = false; d->redraw(); }
            return 0;
        case WM_LBUTTONDOWN:
            if (d) {
                d->pressed = true;
                d->dragging = false;
                d->dragStart = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
                SetCapture(hwnd);
            }
            return 0;
        case WM_LBUTTONUP:
            if (d && d->pressed) {
                ReleaseCapture();
                d->pressed = false;
                POINT p = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
                if (d->inButton(p)) d->toggleListening();
                else {
                    int slot = d->slotAt(p);
                    if (slot >= 0 && slot < (int)d->ring.size()) d->pick(d->ring[slot]);
                }
            }
            return 0;
        case WM_EXITSIZEMOVE:
            if (d) d->savePosition();
            return 0;
        case WM_MOUSEWHEEL:
            if (d) {
                d->wheelY += GET_WHEEL_DELTA_WPARAM(wparam);
                if (abs(d->wheelY) >= WHEEL_DELTA) { input::scroll(d->wheelY > 0 ? 3 : -3); d->wheelY = 0; }
            }
            return 0;
        case WM_MOUSEHWHEEL:
            if (d) {
                d->wheelX += GET_WHEEL_DELTA_WPARAM(wparam);
                if (abs(d->wheelX) >= WHEEL_DELTA) { d->turnRing(d->wheelX > 0 ? 1 : -1); d->wheelX = 0; }
            }
            return 0;
        case WM_RBUTTONUP: {
            HMENU menu = CreatePopupMenu();
            AppendMenuW(menu, MF_STRING, 1, L"Listen");
            AppendMenuW(menu, MF_STRING, 2, L"Settings…");
            AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
            AppendMenuW(menu, MF_STRING, 3, L"Quit Dial");
            POINT p;
            GetCursorPos(&p);
            int chosen = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, p.x, p.y, 0, hwnd, nullptr);
            DestroyMenu(menu);
            if (chosen == 1 && d) d->toggleListening();
            if (chosen == 2) {
                wchar_t path[MAX_PATH];
                GetModuleFileNameW(nullptr, path, MAX_PATH);
                std::wstring dir = path;
                dir = dir.substr(0, dir.find_last_of(L"\\/"));
                std::wstring settings = dir + L"\\dial-settings.exe";
                if (GetFileAttributesW(settings.c_str()) != INVALID_FILE_ATTRIBUTES) {
                    ShellExecuteW(nullptr, L"open", settings.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
                } else {
                    wchar_t appdata[MAX_PATH];
                    if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, 0, appdata))) {
                        std::wstring config = std::wstring(appdata) + L"\\dial\\config.json";
                        ShellExecuteW(nullptr, L"open", config.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
                    }
                }
            }
            if (chosen == 3) DestroyWindow(hwnd);
            return 0;
        }
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    GdiplusStartupInput gdiplusInput;
    ULONG_PTR gdiplusToken;
    GdiplusStartup(&gdiplusToken, &gdiplusInput, nullptr);

    Dial dial;
    g_dial = &dial;
    WNDCLASSW wc = {};
    wc.lpfnWndProc = windowProc;
    wc.hInstance = instance;
    wc.lpszClassName = L"DialWindow";
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    RegisterClassW(&wc);
    POINT at = dial.restorePosition();
    dial.hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"DialWindow", L"Dial",
                                WS_POPUP, at.x, at.y, kWidth, kHeight, nullptr, nullptr, instance, nullptr);
    dial.apps.self = dial.hwnd;
    dial.core.owner = dial.hwnd;
    dial.mic.owner = dial.hwnd;
    dial.redraw();
    ShowWindow(dial.hwnd, SW_SHOWNOACTIVATE);
    dial.hook = SetWindowsHookExW(WH_KEYBOARD_LL, keyboardHook, instance, 0);
    dial.apps.scanInstalled();
    dial.core.start();
    SetTimer(dial.hwnd, 4, 2000, nullptr);  // the app list, every two seconds

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (dial.hook) UnhookWindowsHookEx(dial.hook);
    dial.mic.stop();
    dial.core.stop();
    g_dial = nullptr;
    GdiplusShutdown(gdiplusToken);
    return 0;
}
