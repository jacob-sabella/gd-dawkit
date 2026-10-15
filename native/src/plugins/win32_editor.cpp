// A plugin's window on Windows: put in a tool window of ours off the desktop (no taskbar button,
// never activated), read back with PrintWindow, which draws a window wherever it is -- GPU-drawn
// ones too, with PW_RENDERFULLCONTENT -- and worked by mouse messages posted to the window under
// the point. Plugin windows are run by the thread's own message loop: Godot's, which takes every
// message for the main thread, its windows' and these alike.

#include "editor_window.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>

#ifndef PW_RENDERFULLCONTENT
#define PW_RENDERFULLCONTENT 0x00000002
#endif

namespace dawkit {

namespace {

const wchar_t *CLASS = L"DawKitPluginHolder";
// Off every screen. Not -32000: that is where Windows puts a minimised window, and a plugin that
// asks whether it is minimised stops drawing.
constexpr int HOLDER_X = -20000;
constexpr int HOLDER_Y = -20000;

bool registered() {
	static bool done = false;
	if (!done) {
		WNDCLASSEXW wc;
		std::memset(&wc, 0, sizeof wc);
		wc.cbSize = sizeof wc;
		wc.lpfnWndProc = DefWindowProcW;
		wc.hInstance = GetModuleHandleW(nullptr);
		wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
		wc.lpszClassName = CLASS;
		done = RegisterClassExW(&wc) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
	}
	return done;
}

HWND hwnd(uintptr_t w) {
	return (HWND)w;
}

// --- where the pointer is, as a plugin sees it -----------------------------------------------
//
// JUCE (and others) take a click only where WindowFromPoint finds their own window at the
// click's screen point, and off every screen the system finds no window at all. So WindowFromPoint
// is steered, once, for the whole process: a point inside one of our windows is the plugin window
// under it, any other point is asked of the system's own NtUserWindowFromPoint, as user32's
// WindowFromPoint would have. Not each plugin's imports: some resolve theirs as they run.

std::vector<HWND> holders;

// Windows passes the point packed in the first argument; Wine splits it over two. Both are given.
using SystemWindowFromPointFn = HWND(WINAPI *)(ULONG_PTR packed, LONG y);
SystemWindowFromPointFn system_window_from_point = nullptr;

HWND WINAPI steered_WindowFromPoint(POINT p) {
	for (HWND h : holders) {
		RECT r;
		if (GetWindowRect(h, &r) && PtInRect(&r, p)) {
			HWND w = h;
			POINT c = p;
			ScreenToClient(h, &c);
			for (int i = 0; i < 16; i++) {
				HWND child = ChildWindowFromPointEx(w, c, CWP_SKIPINVISIBLE | CWP_SKIPDISABLED | CWP_SKIPTRANSPARENT);
				if (!child || child == w) break;
				MapWindowPoints(w, child, &c, 1);
				w = child;
			}
			return w;
		}
	}
	return system_window_from_point(((ULONG_PTR)(DWORD)p.y << 32) | (DWORD)p.x, p.y);
}

void steer_window_from_point() {
	static bool tried = false;
	if (tried) {
		return;
	}
	tried = true;
#if defined(__x86_64__) || defined(_M_X64)
	HMODULE win32u = LoadLibraryW(L"win32u.dll");
	HMODULE user32 = GetModuleHandleW(L"user32.dll");
	if (!win32u || !user32) {
		return; // before Windows 10: plugin windows show, but some take no clicks
	}
	system_window_from_point = (SystemWindowFromPointFn)(void *)GetProcAddress(win32u, "NtUserWindowFromPoint");
	BYTE *at = (BYTE *)(void *)GetProcAddress(user32, "WindowFromPoint");
	// Functions start 16 bytes apart at the least: the 12 of `mov rax, steered; jmp rax` fit.
	if (!system_window_from_point || !at || ((uintptr_t)at & 15) != 0) {
		return;
	}
	BYTE jump[12] = { 0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xE0 };
	void *to = (void *)steered_WindowFromPoint;
	std::memcpy(jump + 2, &to, sizeof to);
	DWORD was;
	if (VirtualProtect(at, sizeof jump, PAGE_EXECUTE_READWRITE, &was)) {
		std::memcpy(at, jump, sizeof jump);
		VirtualProtect(at, sizeof jump, was, &was);
		FlushInstructionCache(GetCurrentProcess(), at, sizeof jump);
	}
#endif
}

// The windows we work are subclassed, for two things the real mouse would otherwise undo:
//  - A window that asks to hear when the mouse leaves (TrackMouseEvent, as JUCE's do) is told at
//    once, since the real cursor is nowhere near it, and takes a click as a drag that wandered off.
//    Only the leaves we send ourselves reach it.
//  - A window that takes the mouse capture as a button goes down would take the real mouse from
//    the game's own window for as long as it held it. The capture is given straight back, and the
//    window is not told it lost it.
const wchar_t *OLD_PROC = L"DawKitOldProc";
bool giving_back = false;

// Our own leave, posted so it comes after the moves already on their way.
UINT leave_message() {
	static UINT m = RegisterWindowMessageW(L"DawKitMouseLeave");
	return m;
}

LRESULT CALLBACK worked(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
	WNDPROC old = (WNDPROC)GetPropW(w, OLD_PROC);
	if (!old) {
		return DefWindowProcW(w, msg, wp, lp);
	}
	if (msg == WM_MOUSELEAVE || (msg == WM_CAPTURECHANGED && giving_back)) {
		return 0;
	}
	if (msg == leave_message()) {
		return CallWindowProcW(old, w, WM_MOUSELEAVE, 0, 0);
	}
	if (msg == WM_NCDESTROY) {
		SetWindowLongPtrW(w, GWLP_WNDPROC, (LONG_PTR)old);
		RemovePropW(w, OLD_PROC);
		return CallWindowProcW(old, w, msg, wp, lp);
	}
	LRESULT r = CallWindowProcW(old, w, msg, wp, lp);
	if ((msg == WM_LBUTTONDOWN || msg == WM_MBUTTONDOWN || msg == WM_RBUTTONDOWN) && GetCapture() == w) {
		giving_back = true;
		ReleaseCapture();
		giving_back = false;
	}
	return r;
}

void subclass(HWND w) {
	if (!w || GetPropW(w, OLD_PROC)) {
		return;
	}
	LONG_PTR old = GetWindowLongPtrW(w, GWLP_WNDPROC);
	if (old && old != (LONG_PTR)worked) {
		SetPropW(w, OLD_PROC, (HANDLE)old);
		SetWindowLongPtrW(w, GWLP_WNDPROC, (LONG_PTR)worked);
	}
}

WPARAM held_flags(unsigned int held) {
	WPARAM f = 0;
	if (held & 1) f |= MK_LBUTTON;
	if (held & 2) f |= MK_MBUTTON;
	if (held & 4) f |= MK_RBUTTON;
	return f;
}

} // namespace

bool EditorWindow::available(std::string *why) {
	if (!registered()) {
		if (why) *why = "no window class could be registered for plugin windows";
		return false;
	}
	return true;
}

bool EditorWindow::create(int w, int h, std::string &why) {
	destroy();
	if (!registered()) {
		why = "no window class could be registered for plugin windows";
		return false;
	}
	width = w > 0 ? w : 400;
	height = h > 0 ? h : 300;
	HWND made = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, CLASS, L"", WS_POPUP | WS_CLIPCHILDREN,
			HOLDER_X, HOLDER_Y, width, height, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
	if (!made) {
		why = "no window could be made for the plugin";
		return false;
	}
	holder = (uintptr_t)made;
	holders.push_back(made);
	steer_window_from_point();
	ShowWindow(made, SW_SHOWNOACTIVATE);
	return true;
}

void EditorWindow::resize(int w, int h) {
	if (!holder || w <= 0 || h <= 0 || (w == width && h == height)) {
		return;
	}
	width = w;
	height = h;
	SetWindowPos(hwnd(holder), nullptr, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

void EditorWindow::destroy() {
	if (holder) {
		holders.erase(std::remove(holders.begin(), holders.end(), hwnd(holder)), holders.end());
		DestroyWindow(hwnd(holder));
	}
	holder = target = entered = told_window = 0;
	last.clear();
}

// The plugin's window in ours: its first child, or ours when it has put none there yet.
uintptr_t EditorWindow::content() {
	if (!holder) return 0;
	HWND child = GetWindow(hwnd(holder), GW_CHILD);
	return child ? (uintptr_t)child : holder;
}

void EditorWindow::pump() {
	if (!holder) return;
	// A plugin that sizes its own window, without saying so through the format's own call.
	HWND c = hwnd(content());
	RECT r;
	if (c != hwnd(holder) && GetWindowRect(c, &r)) {
		int w = r.right - r.left, h = r.bottom - r.top;
		if (w > 1 && h > 1 && (w != width || h != height)) {
			width = w;
			height = h;
			SetWindowPos(hwnd(holder), nullptr, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
		}
	}
}

void EditorWindow::tell_where(uintptr_t) {}
void EditorWindow::enter(uintptr_t, int, int, int, int) {}

bool EditorWindow::capture(std::vector<uint8_t> &rgba, int &w, int &h, bool &same) {
	same = false;
	if (!holder) return false;
	RECT r;
	GetClientRect(hwnd(holder), &r);
	w = r.right - r.left;
	h = r.bottom - r.top;
	if (w < 1 || h < 1) return false;
	HDC screen = GetDC(nullptr);
	HDC dc = CreateCompatibleDC(screen);
	BITMAPINFO bi;
	std::memset(&bi, 0, sizeof bi);
	bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth = w;
	bi.bmiHeader.biHeight = -h; // top-down
	bi.bmiHeader.biPlanes = 1;
	bi.bmiHeader.biBitCount = 32;
	bi.bmiHeader.biCompression = BI_RGB;
	void *bits = nullptr;
	HBITMAP bmp = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
	bool ok = false;
	if (bmp && bits) {
		HGDIOBJ old = SelectObject(dc, bmp);
		ok = PrintWindow(hwnd(holder), dc, PW_RENDERFULLCONTENT) != 0;
		if (!ok) {
			// An older system, or a window that will not print itself: what it last painted.
			ok = PrintWindow(hwnd(holder), dc, 0) != 0;
		}
		GdiFlush();
		if (ok) {
			size_t size = (size_t)w * h * 4;
			std::vector<uint8_t> px(size);
			const uint8_t *in = (const uint8_t *)bits;
			for (size_t i = 0; i < size; i += 4) {
				px[i + 0] = in[i + 2];
				px[i + 1] = in[i + 1];
				px[i + 2] = in[i + 0];
				px[i + 3] = 0xff;
			}
			if (last.size() == size && std::memcmp(last.data(), px.data(), size) == 0) {
				same = true;
			} else {
				last = px;
				rgba = std::move(px);
			}
		}
		SelectObject(dc, old);
		DeleteObject(bmp);
	}
	DeleteDC(dc);
	ReleaseDC(nullptr, screen);
	return ok;
}

// The deepest window under (x, y) of ours, and the point in its own client coordinates. Ready to
// be worked: subclassed, and the window the pointer was in before told it has left.
uintptr_t EditorWindow::under(int x, int y, int &cx, int &cy, int &rx, int &ry) {
	HWND w = hwnd(holder);
	POINT p{ x, y };
	for (int i = 0; i < 16; i++) {
		HWND child = ChildWindowFromPointEx(w, p, CWP_SKIPINVISIBLE | CWP_SKIPDISABLED | CWP_SKIPTRANSPARENT);
		if (!child || child == w) break;
		MapWindowPoints(w, child, &p, 1);
		w = child;
	}
	cx = p.x;
	cy = p.y;
	POINT screen{ x, y };
	ClientToScreen(hwnd(holder), &screen);
	rx = screen.x;
	ry = screen.y;
	subclass(w);
	if (target && target != (uintptr_t)w && IsWindow(hwnd(target))) {
		PostMessageW(hwnd(target), leave_message(), 0, 0);
	}
	target = (uintptr_t)w;
	return (uintptr_t)w;
}

void EditorWindow::pointer_move(int x, int y) {
	if (!holder) return;
	int cx, cy, rx, ry;
	HWND w;
	if (entered && held) {
		w = hwnd(entered);
		// Dragging: the window the button went down in keeps the pointer, as a captured mouse does.
		POINT p{ x, y };
		MapWindowPoints(hwnd(holder), w, &p, 1);
		cx = p.x;
		cy = p.y;
	} else {
		w = hwnd(under(x, y, cx, cy, rx, ry));
	}
	PostMessageW(w, WM_MOUSEMOVE, held_flags(held), MAKELPARAM(cx, cy));
}

void EditorWindow::send_button(int x, int y, int button, bool down) {
	if (!holder) return;
	int cx, cy, rx, ry;
	HWND w = hwnd(under(x, y, cx, cy, rx, ry));
	if (!down && entered) {
		w = hwnd(entered);
		POINT p{ x, y };
		MapWindowPoints(hwnd(holder), w, &p, 1);
		cx = p.x;
		cy = p.y;
	}
	unsigned int bit = button == 1 ? 1 : button == 2 ? 2 : button == 3 ? 4 : 0;
	held = down ? (held | bit) : (held & ~bit);
	UINT msg = button == 1 ? (down ? WM_LBUTTONDOWN : WM_LBUTTONUP)
			: button == 2 ? (down ? WM_MBUTTONDOWN : WM_MBUTTONUP)
			: (down ? WM_RBUTTONDOWN : WM_RBUTTONUP);
	PostMessageW(w, msg, held_flags(held), MAKELPARAM(cx, cy));
	entered = held ? (uintptr_t)w : 0;
}

void EditorWindow::pointer_button(int x, int y, int button, bool down) {
	send_button(x, y, button, down);
}

void EditorWindow::wheel(int x, int y, int notches) {
	if (!holder || notches == 0) return;
	int cx, cy, rx, ry;
	HWND w = hwnd(under(x, y, cx, cy, rx, ry));
	// The wheel's point is on the screen, not in the window.
	POINT p{ x, y };
	ClientToScreen(hwnd(holder), &p);
	PostMessageW(w, WM_MOUSEWHEEL, MAKEWPARAM(held_flags(held), (short)(notches * WHEEL_DELTA)), MAKELPARAM(p.x, p.y));
}

void EditorWindow::key(unsigned long keysym, bool down, unsigned int modifiers) {
	if (!holder) return;
	HWND w = hwnd(entered ? entered : content());
	// X keysyms are Latin-1 for the printable keys; the rest are left to the plugin's knobs.
	if (keysym >= 0x20 && keysym < 0x100) {
		SHORT vk = VkKeyScanW((WCHAR)keysym);
		if (vk != -1) {
			PostMessageW(w, down ? WM_KEYDOWN : WM_KEYUP, LOBYTE(vk), down ? 1 : 0xC0000001);
		}
		if (down) {
			PostMessageW(w, WM_CHAR, (WPARAM)keysym, 1);
		}
		return;
	}
	struct Named {
		unsigned long sym;
		UINT vk;
	};
	static const Named named[] = { { 0xff08, VK_BACK }, { 0xff09, VK_TAB }, { 0xff0d, VK_RETURN },
		{ 0xff1b, VK_ESCAPE }, { 0xffff, VK_DELETE }, { 0xff51, VK_LEFT }, { 0xff52, VK_UP }, { 0xff53, VK_RIGHT },
		{ 0xff54, VK_DOWN }, { 0xff50, VK_HOME }, { 0xff57, VK_END } };
	for (const Named &n : named) {
		if (n.sym == keysym) {
			PostMessageW(w, down ? WM_KEYDOWN : WM_KEYUP, n.vk, down ? 1 : 0xC0000001);
			if (down && (n.vk == VK_BACK || n.vk == VK_RETURN || n.vk == VK_ESCAPE || n.vk == VK_TAB)) {
				PostMessageW(w, WM_CHAR, n.vk == VK_RETURN ? '\r' : n.vk == VK_BACK ? '\b' : n.vk == VK_TAB ? '\t' : 27, 1);
			}
		}
	}
	(void)modifiers;
}

} // namespace dawkit
