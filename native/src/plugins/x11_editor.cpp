#include "editor_window.h"
#include "library.h"

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>

#include <X11/keysym.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <map>
#include <set>
#include <spawn.h>
#include <sys/wait.h>
#include <poll.h>
#include <thread>
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>

namespace dawkit {

namespace {

#define DAWKIT_XLIB(X)                                                                                 \
	X(XOpenDisplay) X(XCreateWindow) X(XDestroyWindow) X(XMapWindow) X(XResizeWindow)                  \
	X(XGetWindowAttributes) X(XGetImage) X(XTranslateCoordinates) X(XSendEvent) X(XFlush) X(XSync)     \
	X(XSetErrorHandler) X(XQueryTree) X(XFree) X(XKeysymToKeycode) X(XPending) X(XNextEvent)           \
	X(XSelectInput) X(XMoveWindow) X(XReparentWindow) X(XAddToSaveSet) X(XRemoveFromSaveSet)            \
	X(XInternAtom) X(XGetWindowProperty) X(XMoveResizeWindow) X(XGetInputFocus) X(XSetInputFocus)  \
	X(XChangeProperty)

struct Xlib {
#define DAWKIT_XLIB_FIELD(n) decltype(&::n) n = nullptr;
	DAWKIT_XLIB(DAWKIT_XLIB_FIELD)
#undef DAWKIT_XLIB_FIELD
	Library lib;
	Display *dpy = nullptr;
	std::string missing;

	static Xlib &get() {
		static Xlib x;
		return x;
	}

private:
	Xlib() {
		// Before any plugin's toolkit starts: GTK then takes a sent click as one from the pointer
		// it knows, where otherwise it waits for one from an input device that never comes.
		setenv("GDK_CORE_DEVICE_EVENTS", "1", 0);
		if (!lib.open_any({ "libX11.so.6", "libX11.so" })) {
			missing = "there is no Xlib, so plugins have no windows";
			return;
		}
		bool all = true;
#define DAWKIT_XLIB_LOAD(n)           \
	if (!lib.get(#n, n)) {            \
		all = false;                  \
		missing = "Xlib has no " #n;  \
	}
		DAWKIT_XLIB(DAWKIT_XLIB_LOAD)
#undef DAWKIT_XLIB_LOAD
		if (!all) {
			return;
		}
		lib.leak();
		dpy = XOpenDisplay(nullptr);
		if (!dpy) {
			missing = "there is no X display, so plugins have no windows";
			return;
		}
		// A window gone between asking about it and using it is not worth dying for.
		XSetErrorHandler([](Display *, XErrorEvent *) { return 0; });
		// Every window that appears, to catch a plugin's menus as they open.
		XSelectInput(dpy, DefaultRootWindow(dpy), SubstructureNotifyMask);
	}
};

double seconds() {
	return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

// The process a window says it belongs to, or 0.
long pid_of(Xlib &X, Window w) {
	static Atom pid_atom = X.XInternAtom(X.dpy, "_NET_WM_PID", False);
	Atom type;
	int format;
	unsigned long n, after;
	unsigned char *data = nullptr;
	long pid = 0;
	if (X.XGetWindowProperty(X.dpy, w, pid_atom, 0, 1, False, XA_CARDINAL, &type, &format, &n, &after, &data) == Success &&
			data && n == 1 && format == 32) {
		pid = (long)*(unsigned long *)data;
	}
	if (data) X.XFree(data);
	return pid;
}

// The processes drawing in `w` and the windows under it, a few levels down: the plugin's own (this
// one), or yabridge's Wine host.
void pids_in(Xlib &X, Window w, std::set<long> &out, int depth) {
	if (long p = pid_of(X, w)) out.insert(p);
	if (depth >= 3) return;
	Window root, parent, *kids = nullptr;
	unsigned int n = 0;
	if (!X.XQueryTree(X.dpy, w, &root, &parent, &kids, &n)) return;
	for (unsigned int i = 0; i < n; i++) pids_in(X, kids[i], out, depth + 1);
	if (kids) X.XFree(kids);
}

// The first window under `w` drawn by another process (yabridge's Wine host's), or 0.
Window first_of_another(Xlib &X, Window w, int depth) {
	long p = pid_of(X, w);
	if (p && p != (long)getpid()) return w;
	if (depth >= 3) return 0;
	Window root, parent, *kids = nullptr, found = 0;
	unsigned int n = 0;
	if (!X.XQueryTree(X.dpy, w, &root, &parent, &kids, &n)) return 0;
	for (unsigned int i = 0; i < n && !found; i++) found = first_of_another(X, kids[i], depth + 1);
	if (kids) X.XFree(kids);
	return found;
}

// Whether `w` asks for no title bar or frame (Motif's hints, which Wine and GTK set for menus).
bool undecorated(Xlib &X, Window w) {
	static Atom motif = X.XInternAtom(X.dpy, "_MOTIF_WM_HINTS", False);
	Atom type;
	int format;
	unsigned long n, after;
	unsigned char *data = nullptr;
	bool bare = false;
	if (X.XGetWindowProperty(X.dpy, w, motif, 0, 5, False, AnyPropertyType, &type, &format, &n, &after, &data) == Success &&
			data && format == 32 && n >= 3) {
		unsigned long *hints = (unsigned long *)data;
		bare = (hints[0] & 2) && hints[2] == 0; // MWM_HINTS_DECORATIONS, and none of them
	}
	if (data) X.XFree(data);
	return bare;
}

// Whether `w` is a window of its own (a file browser, a settings page), left on the desktop to be
// used there: it says it is an ordinary window or a dialog, and has a title bar. A menu says it is
// one, or nothing, or (Wine's) that it is an ordinary window with no frame at all.
bool is_a_window_of_its_own(Xlib &X, Window w) {
	static Atom type_atom = X.XInternAtom(X.dpy, "_NET_WM_WINDOW_TYPE", False);
	static Atom normal = X.XInternAtom(X.dpy, "_NET_WM_WINDOW_TYPE_NORMAL", False);
	static Atom dialog = X.XInternAtom(X.dpy, "_NET_WM_WINDOW_TYPE_DIALOG", False);
	Atom type;
	int format;
	unsigned long n, after;
	unsigned char *data = nullptr;
	bool own = false;
	if (X.XGetWindowProperty(X.dpy, w, type_atom, 0, 8, False, XA_ATOM, &type, &format, &n, &after, &data) == Success &&
			data && format == 32 && n > 0) {
		Atom first = (Atom)((unsigned long *)data)[0];
		own = first == normal || first == dialog;
	}
	if (data) X.XFree(data);
	return own && !undecorated(X, w);
}

// The editors open now, for a menu to find the one it came from.
std::vector<EditorWindow *> &open_editors() {
	static std::vector<EditorWindow *> all;
	return all;
}

// Where each window on the screen asked to be when it was made, before any window manager placed
// it: a menu's own idea of where it goes. Forgotten as it maps (or after a while, if it never does).
struct Asked {
	int x, y;
	double at;
};
std::map<Window, Asked> &asked_at() {
	static std::map<Window, Asked> all;
	return all;
}

// --- Hyprland ------------------------------------------------------------------------------------
//
// A menu Wine draws for a plugin (JUCE's, under yabridge) is a window the window manager places,
// and it does not survive being taken from it: moved into a window of ours, Wine works out where it
// now is and the plugin closes it; given the focus, the plugin's own window loses it and the plugin
// closes it too. So on Hyprland a rule puts those -- an .exe's window titled "menu" or not at all --
// on a special workspace nobody looks at, as they map, without focus or animation, and they are
// read and worked where they are. The rule is on only while a plugin's window is being used here,
// and switches itself off a few seconds after it was last renewed, so a program that stops without
// saying so does not leave every Wine program's menus going missing.

bool on_hyprland() {
	static int on = -1;
	if (on < 0) {
		on = getenv("HYPRLAND_INSTANCE_SIGNATURE") && !getenv("DAWKIT_NO_HYPRLAND_RULE") ? 1 : 0;
	}
	return on == 1;
}

const char *HYPR_MENU_RULE = R"lua(
if not dawkit_menu_rule then
	dawkit_menu_rule = hl.window_rule({
		name = "dawkit-menus",
		match = { class = [[^.*\.exe$]], title = [[^(menu)?$]], xwayland = true },
		workspace = "special:dawkit silent",
		no_initial_focus = true,
		no_anim = true,
	})
end
dawkit_menu_rule:set_enabled(true)
dawkit_menu_rule_turn = (dawkit_menu_rule_turn or 0) + 1
local turn = dawkit_menu_rule_turn
hl.timer(function()
	if dawkit_menu_rule_turn == turn then dawkit_menu_rule:set_enabled(false) end
end, { timeout = 4000, type = "oneshot" })
)lua";

// When the rule was last renewed, in seconds.
double hypr_renewed = -1e9;

// The rule on (again) for the next few seconds, at most once a second. Waits for it: the press it
// comes before may open a menu.
void keep_menus_hidden() {
	if (!on_hyprland() || seconds() - hypr_renewed < 1.0) return;
	hypr_renewed = seconds();
	const char *argv[] = { "hyprctl", "eval", HYPR_MENU_RULE, nullptr };
	posix_spawn_file_actions_t quiet;
	posix_spawn_file_actions_init(&quiet);
	posix_spawn_file_actions_addopen(&quiet, 1, "/dev/null", O_WRONLY, 0);
	posix_spawn_file_actions_addopen(&quiet, 2, "/dev/null", O_WRONLY, 0);
	pid_t pid;
	if (posix_spawnp(&pid, "hyprctl", &quiet, nullptr, (char *const *)argv, environ) == 0) {
		waitpid(pid, nullptr, 0);
	} else {
		hypr_renewed = 1e18; // no hyprctl: never again
	}
	posix_spawn_file_actions_destroy(&quiet);
}

// Wine takes the window the window manager last named active to be the one in front, and a plugin
// whose window is not in front closes its menus as they open (it was switched away from). The
// plugin's window here is never focused -- the host's is -- so from just before a press until its
// menus close, Wine's window in ours is named active, as it would be after a click on a desktop.
// The window manager names its own again as each menu maps, and Wine reads that within a
// millisecond, so a thread of its own, on a connection of its own, names the plugin's again as soon
// as it changes. Once the menus close, the window manager's choice stands.
struct Active {
	std::atomic<unsigned long> window{ 0 };
	std::atomic<double> until{ 0 };
	Atom atom = 0;

	static Active &get() {
		static Active a;
		return a;
	}

	static void name(Display *dpy, Atom atom, unsigned long w) {
		Xlib &X = Xlib::get();
		X.XChangeProperty(dpy, DefaultRootWindow(dpy), atom, XA_WINDOW, 32, PropModeReplace,
				(unsigned char *)&w, 1);
		X.XFlush(dpy);
	}

	// `w` named active until `until`, in seconds.
	void hold(Xlib &X, unsigned long w, double for_seconds) {
		if (!w) return;
		bool again = window.load() == w && until.load() > seconds();
		window = w;
		until = seconds() + for_seconds;
		if (!again) name(X.dpy, atom ? atom : (atom = X.XInternAtom(X.dpy, "_NET_ACTIVE_WINDOW", False)), w);
		start();
	}

	void start() {
		static bool started = false;
		if (started) return;
		started = true;
		std::thread([this] {
			Xlib &X = Xlib::get();
			Display *dpy = X.XOpenDisplay(nullptr);
			if (!dpy) return;
			Atom a = X.XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);
			X.XSelectInput(dpy, DefaultRootWindow(dpy), PropertyChangeMask);
			X.XFlush(dpy);
			pollfd fd{ ConnectionNumber(dpy), POLLIN, 0 };
			for (;;) {
				poll(&fd, 1, 200);
				bool changed = false;
				while (X.XPending(dpy)) {
					XEvent e;
					X.XNextEvent(dpy, &e);
					changed |= e.type == PropertyNotify && e.xproperty.atom == a;
				}
				if (!changed || seconds() > until.load()) continue;
				unsigned long w = window.load(), now = 0;
				Atom type;
				int format;
				unsigned long n, after;
				unsigned char *data = nullptr;
				if (X.XGetWindowProperty(dpy, DefaultRootWindow(dpy), a, 0, 1, False, XA_WINDOW, &type, &format, &n,
							&after, &data) == Success && data && n == 1) {
					now = *(unsigned long *)data;
				}
				if (data) X.XFree(data);
				if (now != w) name(dpy, a, w);
			}
		}).detach();
	}
};

// Whether menus that a window manager places are left where it puts them.
bool menus_stay_put() {
	return on_hyprland() && hypr_renewed < 1e17 && seconds() - hypr_renewed < 4.0;
}

// How soon after a click a window opening is taken as the menu it opened.
constexpr double MENU_WITHIN = 2.0;

// Off every screen, for as long as the compositor leaves it there.
constexpr int HOLDER_X = -30000;

} // namespace

bool EditorWindow::available(std::string *why) {
	Xlib &X = Xlib::get();
	if (!X.dpy && why) {
		*why = X.missing;
	}
	return X.dpy != nullptr;
}

bool EditorWindow::create(int w, int h, std::string &why) {
	Xlib &X = Xlib::get();
	if (!X.dpy) {
		why = X.missing;
		return false;
	}
	destroy();
	width = w > 0 ? w : 400;
	height = h > 0 ? h : 300;
	XSetWindowAttributes at;
	std::memset(&at, 0, sizeof at);
	at.override_redirect = True;
	at.background_pixel = 0;
	at.event_mask = SubstructureNotifyMask | StructureNotifyMask;
	holder = X.XCreateWindow(X.dpy, DefaultRootWindow(X.dpy), HOLDER_X, 0, (unsigned)width, (unsigned)height, 0,
			CopyFromParent, InputOutput, CopyFromParent, CWOverrideRedirect | CWBackPixel | CWEventMask, &at);
	if (!holder) {
		why = "no window could be made for the plugin";
		return false;
	}
	X.XMapWindow(X.dpy, holder);
	X.XSync(X.dpy, False);
	open_editors().push_back(this);
	return true;
}

void EditorWindow::resize(int w, int h) {
	Xlib &X = Xlib::get();
	if (!holder || w <= 0 || h <= 0 || (w == width && h == height)) {
		return;
	}
	width = w;
	height = h;
	X.XResizeWindow(X.dpy, holder, (unsigned)w, (unsigned)h);
	if (uintptr_t c = content(); c && c != holder) {
		X.XResizeWindow(X.dpy, c, (unsigned)w, (unsigned)h);
	}
	X.XFlush(X.dpy);
}

void EditorWindow::destroy() {
	Xlib &X = Xlib::get();
	auto &all = open_editors();
	all.erase(std::remove(all.begin(), all.end(), this), all.end());
	drop_popups();
	if (holder && X.dpy) {
		X.XDestroyWindow(X.dpy, holder);
		X.XSync(X.dpy, False);
	}
	holder = target = entered = told_window = 0;
	last.clear();
}

// The plugin's window in ours: the biggest one showing, or ours when it has put none there yet.
uintptr_t EditorWindow::content() {
	Xlib &X = Xlib::get();
	Window root, parent, *kids = nullptr;
	unsigned int n = 0;
	if (!holder || !X.XQueryTree(X.dpy, holder, &root, &parent, &kids, &n)) {
		return holder;
	}
	Window best = holder;
	long area = 0;
	for (unsigned int i = 0; i < n; i++) {
		XWindowAttributes k;
		if (X.XGetWindowAttributes(X.dpy, kids[i], &k) && k.map_state == IsViewable && (long)k.width * k.height > area) {
			best = kids[i];
			area = (long)k.width * k.height;
		}
	}
	if (kids) X.XFree(kids);
	return best;
}

void EditorWindow::pump() {
	Xlib &X = Xlib::get();
	if (!X.dpy) return;
	while (X.XPending(X.dpy)) {
		XEvent e;
		X.XNextEvent(X.dpy, &e);
		if (e.type == CreateNotify && e.xcreatewindow.parent == DefaultRootWindow(X.dpy)) {
			auto &asked = asked_at();
			double now = seconds();
			for (auto it = asked.begin(); it != asked.end();) {
				it = now - it->second.at > 10 ? asked.erase(it) : std::next(it);
			}
			asked[e.xcreatewindow.window] = { e.xcreatewindow.x, e.xcreatewindow.y, now };
		} else if (e.type == MapNotify && e.xmap.event == DefaultRootWindow(X.dpy)) {
			window_mapped(e.xmap.window);
			asked_at().erase(e.xmap.window);
		}
	}
	if (!holder) return;
	tidy_popups();
	if (!popups.empty() && open_popup()) {
		Active::get().hold(X, first_of_another(X, (Window)holder, 0), 0.5);
	}
	// Wine takes the pointer to be where the last event it was sent put it for a tenth of a second
	// after it last moved, then asks X where the real one is -- on someone's desktop. A menu follows
	// the pointer by asking, and one opened by a press sees the button go up wherever the real
	// pointer is, as if dragged there, and closes. So while a button is held, and while the pointer
	// is over a menu, it is sent again, a pixel to one side and back: the same place again would not
	// count as a move.
	if (pointer_x >= 0 && (held || open_popup_at(pointer_x, pointer_y)) && seconds() - last_motion > 0.04) {
		int x = pointer_x, y = pointer_y;
		pointer_move(x + (nudged ? 0 : 1), y);
		pointer_x = x;
		nudged = !nudged;
	}
	// A plugin that sizes its own window, without saying so through the format's own call.
	uintptr_t c = content();
	XWindowAttributes a;
	if (c && c != holder && X.XGetWindowAttributes(X.dpy, c, &a) && a.width > 1 && a.height > 1 &&
			(a.width != width || a.height != height)) {
		width = a.width;
		height = a.height;
		X.XResizeWindow(X.dpy, holder, (unsigned)width, (unsigned)height);
		X.XFlush(X.dpy);
	}
	// The compositor may move ours, and the plugin's window inside it hears nothing of that.
	if (c && c != holder) {
		tell_where(c);
	}
}

// A window manager tells a window where it is on the screen whenever it moves it, and some
// toolkits (Wine's, which yabridge's plugins draw with; GDK) work a click's place in the window
// out from that. So it is told, the way a window manager would, whenever it is no longer true.
void EditorWindow::tell_where(uintptr_t w) {
	Xlib &X = Xlib::get();
	XWindowAttributes a;
	int rx = 0, ry = 0;
	Window child;
	if (!X.XGetWindowAttributes(X.dpy, w, &a)) return;
	X.XTranslateCoordinates(X.dpy, w, DefaultRootWindow(X.dpy), 0, 0, &rx, &ry, &child);
	if (told_window == w && rx == told_x && ry == told_y) return;
	XEvent e;
	std::memset(&e, 0, sizeof e);
	e.xconfigure.type = ConfigureNotify;
	e.xconfigure.display = X.dpy;
	e.xconfigure.event = w;
	e.xconfigure.window = w;
	e.xconfigure.x = rx;
	e.xconfigure.y = ry;
	e.xconfigure.width = a.width;
	e.xconfigure.height = a.height;
	X.XSendEvent(X.dpy, w, False, StructureNotifyMask, &e);
	X.XFlush(X.dpy);
	told_window = w;
	told_x = rx;
	told_y = ry;
	entered = 0;
}

namespace {

// `w`'s picture, RGBA.
bool read_window(Xlib &X, Window w, std::vector<uint8_t> &px, int &width, int &height) {
	XWindowAttributes a;
	if (!w || !X.XGetWindowAttributes(X.dpy, w, &a) || a.width < 1 || a.height < 1 || a.map_state != IsViewable) {
		return false;
	}
	XImage *img = X.XGetImage(X.dpy, w, 0, 0, (unsigned)a.width, (unsigned)a.height, AllPlanes, ZPixmap);
	if (!img) {
		return false;
	}
	px.resize((size_t)a.width * a.height * 4);
	bool direct = img->bits_per_pixel == 32 && img->byte_order == LSBFirst && img->red_mask == 0xff0000 &&
			img->green_mask == 0xff00 && img->blue_mask == 0xff;
	for (int y = 0; y < a.height; y++) {
		uint8_t *out = px.data() + (size_t)y * a.width * 4;
		if (direct) {
			const uint8_t *in = (const uint8_t *)img->data + (size_t)y * img->bytes_per_line;
			for (int x = 0; x < a.width; x++) {
				out[x * 4 + 0] = in[x * 4 + 2];
				out[x * 4 + 1] = in[x * 4 + 1];
				out[x * 4 + 2] = in[x * 4 + 0];
				out[x * 4 + 3] = 0xff;
			}
		} else {
			for (int x = 0; x < a.width; x++) {
				unsigned long p = XGetPixel(img, x, y);
				out[x * 4 + 0] = (p >> 16) & 0xff;
				out[x * 4 + 1] = (p >> 8) & 0xff;
				out[x * 4 + 2] = p & 0xff;
				out[x * 4 + 3] = 0xff;
			}
		}
	}
	XDestroyImage(img);
	width = a.width;
	height = a.height;
	return true;
}

} // namespace

bool EditorWindow::capture(std::vector<uint8_t> &rgba, int &w, int &h, bool &same) {
	Xlib &X = Xlib::get();
	same = false;
	if (!holder) return false;
	target = content();
	std::vector<uint8_t> px;
	if (!read_window(X, target, px, w, h)) {
		return false;
	}
	// Open menus over it, where they were put.
	std::vector<uint8_t> menu;
	for (const Popup &p : popups) {
		int mw, mh;
		if (!read_window(X, p.window, menu, mw, mh)) continue;
		for (int y = 0; y < mh; y++) {
			int ty = p.y + y;
			if (ty < 0 || ty >= h) continue;
			int x0 = std::max(0, -p.x), x1 = std::min(mw, w - p.x);
			if (x1 <= x0) continue;
			std::memcpy(px.data() + ((size_t)ty * w + p.x + x0) * 4, menu.data() + ((size_t)y * mw + x0) * 4,
					(size_t)(x1 - x0) * 4);
		}
	}
	size_t size = px.size();
	if (last.size() == size && std::memcmp(last.data(), px.data(), size) == 0) {
		same = true;
		return true;
	}
	last = px;
	rgba = std::move(px);
	return true;
}

// --- menus --------------------------------------------------------------------------------------
//
// A plugin's menu (a dropdown, a right-click menu) is a window of its own on the desktop, put
// where the plugin works out the click was -- off every screen -- or, when it keeps menus on a
// screen, or the window manager places it, in the middle of someone's desktop. So a window that
// opens just after a click sent into a plugin's window, from the process drawing it, and is not a
// window of its own (an ordinary one, a dialog: those stay on the desktop, to be used there), is
// taken off the desktop into a window of ours by the plugin's and drawn over the plugin's picture,
// where it would have been: at the click, or where the plugin put it if that is over its window.

void EditorWindow::window_mapped(uintptr_t w) {
	Xlib &X = Xlib::get();
	double now = seconds();
	EditorWindow *from = nullptr;
	for (EditorWindow *e : open_editors()) {
		if (e->holder == w) return;
		for (const Popup &p : e->popups) {
			if (p.holder == w || p.window == w) return;
		}
		if (now - e->last_press <= MENU_WITHIN && (!from || e->last_press > from->last_press)) {
			from = e;
		}
	}
	if (!from || is_a_window_of_its_own(X, (Window)w)) return;
	std::set<long> pids{ (long)getpid() };
	pids_in(X, (Window)from->holder, pids, 0);
	if (!pids.count(pid_of(X, (Window)w))) return;
	from->adopt(w);
}

bool EditorWindow::adopt(uintptr_t w) {
	Xlib &X = Xlib::get();
	Window root = DefaultRootWindow(X.dpy);
	XWindowAttributes a;
	if (!target) target = content();
	if (!X.XGetWindowAttributes(X.dpy, (Window)w, &a) || !target) return false;
	// One the window manager places dies moved; without the rule it is left on the desktop.
	if (!a.override_redirect && !menus_stay_put()) return false;
	bool in_place = !a.override_redirect;
	int ex = 0, ey = 0, mx = 0, my = 0;
	Window child;
	X.XTranslateCoordinates(X.dpy, target, root, 0, 0, &ex, &ey, &child);
	X.XTranslateCoordinates(X.dpy, (Window)w, root, 0, 0, &mx, &my, &child);
	// Where it asked to be, not where a window manager has put it since.
	auto asked = asked_at().find((Window)w);
	if (asked != asked_at().end()) {
		mx = asked->second.x;
		my = asked->second.y;
	}
	Popup p;
	p.window = w;
	p.width = a.width;
	p.height = a.height;
	p.x = mx - ex;
	p.y = my - ey;
	p.origin_x = mx;
	p.origin_y = my;
	// Put where the plugin wanted it only when that is over its window; otherwise at the click.
	if (p.x + p.width <= 0 || p.y + p.height <= 0 || p.x >= width || p.y >= height) {
		p.x = press_x;
		p.y = press_y;
	}
	// Inside the picture, as a window manager keeps a menu on its screen.
	p.x = std::max(0, std::min(p.x, width - p.width));
	p.y = std::max(0, std::min(p.y, height - p.height));
	if (in_place) {
		// Where the window manager put it, out of sight (see on_hyprland).
		popups.push_back(p);
		entered = 0;
		return true;
	}
	XSetWindowAttributes at;
	std::memset(&at, 0, sizeof at);
	at.override_redirect = True;
	p.holder = X.XCreateWindow(X.dpy, root, ex + p.x, ey + p.y, (unsigned)p.width, (unsigned)p.height, 0,
			CopyFromParent, InputOutput, CopyFromParent, CWOverrideRedirect, &at);
	if (!p.holder) return false;
	X.XMapWindow(X.dpy, p.holder);
	// If this process ends without giving it back, the menu goes back to the desktop rather than
	// with our window.
	X.XAddToSaveSet(X.dpy, (Window)w);
	// The focus it had goes with it while it is moved (unmapped and mapped again), and a menu that
	// loses the focus is told to close (Wine sends it WM_CANCELMODE): it is handed straight back.
	Window focused = 0;
	int revert = 0;
	X.XGetInputFocus(X.dpy, &focused, &revert);
	X.XReparentWindow(X.dpy, (Window)w, p.holder, 0, 0);
	X.XMapWindow(X.dpy, (Window)w);
	if (focused == (Window)w) {
		X.XSetInputFocus(X.dpy, (Window)w, RevertToParent, CurrentTime);
	}
	X.XSync(X.dpy, False);
	popups.push_back(p);
	entered = 0;
	return true;
}

// Menus closed and gone are let go; ones still open are kept the size they are, at 0, 0 of ours
// (a window is only read whole while it is inside its parent).
void EditorWindow::tidy_popups() {
	Xlib &X = Xlib::get();
	Window root = DefaultRootWindow(X.dpy);
	for (size_t i = 0; i < popups.size();) {
		Popup &p = popups[i];
		Window up, parent = 0, *kids = nullptr;
		unsigned int n = 0;
		XWindowAttributes a;
		bool there = X.XQueryTree(X.dpy, (Window)p.window, &up, &parent, &kids, &n) &&
				parent == (p.holder ? (Window)p.holder : root) &&
				X.XGetWindowAttributes(X.dpy, (Window)p.window, &a);
		if (kids) X.XFree(kids);
		if (!there || (!p.holder && a.map_state != IsViewable)) {
			if (p.holder) X.XDestroyWindow(X.dpy, (Window)p.holder);
			popups.erase(popups.begin() + (long)i);
			continue;
		}
		if (!p.holder) {
			i++;
			continue;
		}
		bool moved = a.x != 0 || a.y != 0;
		bool sized = a.width != p.width || a.height != p.height;
		if (moved || sized) {
			// A menu that places itself once it is in ours (Wine's does) places itself in the plugin's
			// window's coordinates: it is put there, when that is inside the picture.
			if (moved && a.x + a.width <= width && a.y + a.height <= height) {
				p.x = a.x;
				p.y = a.y;
			}
			p.width = a.width;
			p.height = a.height;
			p.x = std::max(0, std::min(p.x, width - p.width));
			p.y = std::max(0, std::min(p.y, height - p.height));
			int ex = 0, ey = 0;
			Window child;
			X.XTranslateCoordinates(X.dpy, target ? target : holder, root, 0, 0, &ex, &ey, &child);
			X.XMoveResizeWindow(X.dpy, (Window)p.holder, ex + p.x, ey + p.y, (unsigned)std::max(1, a.width),
					(unsigned)std::max(1, a.height));
			X.XMoveWindow(X.dpy, (Window)p.window, 0, 0);
				}
		i++;
	}
	X.XFlush(X.dpy);
}

// Every menu given back to the desktop -- off it, where nobody sees -- and our windows for them gone.
void EditorWindow::drop_popups() {
	Xlib &X = Xlib::get();
	if (!X.dpy) return;
	for (const Popup &p : popups) {
		if (!p.holder) continue;
		X.XReparentWindow(X.dpy, (Window)p.window, DefaultRootWindow(X.dpy), HOLDER_X, 0);
		X.XRemoveFromSaveSet(X.dpy, (Window)p.window);
		X.XDestroyWindow(X.dpy, (Window)p.holder);
	}
	popups.clear();
	X.XSync(X.dpy, False);
}

const EditorWindow::Popup *EditorWindow::open_popup() const {
	Xlib &X = Xlib::get();
	for (auto it = popups.rbegin(); it != popups.rend(); ++it) {
		XWindowAttributes a;
		if (X.XGetWindowAttributes(X.dpy, (Window)it->window, &a) && a.map_state == IsViewable) return &*it;
	}
	return nullptr;
}

const EditorWindow::Popup *EditorWindow::open_popup_at(int x, int y) const {
	Xlib &X = Xlib::get();
	for (auto it = popups.rbegin(); it != popups.rend(); ++it) {
		XWindowAttributes a;
		if (x >= it->x && y >= it->y && x < it->x + it->width && y < it->y + it->height &&
				X.XGetWindowAttributes(X.dpy, (Window)it->window, &a) && a.map_state == IsViewable) {
			return &*it;
		}
	}
	return nullptr;
}

// The deepest window under (x, y) -- in an open menu if one is there -- the point in its own
// coordinates, and on the screen: it is the one listening.
uintptr_t EditorWindow::under(int x, int y, int &cx, int &cy, int &rx, int &ry) {
	Xlib &X = Xlib::get();
	Window base = target;
	int bx = x, by = y;
	const Popup *menu = open_popup_at(x, y);
	in_menu = menu != nullptr;
	if (menu) {
		base = (Window)menu->window;
		bx = x - menu->x;
		by = y - menu->y;
	}
	Window w = base, child = 0;
	int tx, ty;
	for (int i = 0; i < 8; i++) {
		if (!X.XTranslateCoordinates(X.dpy, base, w, bx, by, &tx, &ty, &child) || !child) break;
		w = child;
	}
	X.XTranslateCoordinates(X.dpy, base, w, bx, by, &cx, &cy, &child);
	if (menu) {
		// On the screen where the plugin believes its menu is, not where it is: a menu works out
		// what is under the pointer from that (SWELL's, from the cursor), and it was never told it
		// moved -- a menu is not expected to. Wine has its own idea, which the event's root not
		// being the screen's root makes it use (see `event_root`).
		rx = menu->origin_x + bx;
		ry = menu->origin_y + by;
	} else {
		X.XTranslateCoordinates(X.dpy, base, DefaultRootWindow(X.dpy), bx, by, &rx, &ry, &child);
	}
	return w;
}

// The root an event into `w` names: the screen's, except in a menu, where it is the menu's own
// window. Wine places a point by the event's root position when its root is the screen's, and by
// the point in the window and where it believes the window is otherwise -- which, for a menu taken
// off the desktop, is the only one of the two it agrees with.
static Window event_root(Xlib &X, bool in_menu, Window w) {
	return in_menu ? w : DefaultRootWindow(X.dpy);
}

// GDK and Wine hand a click to the window they last saw the pointer go into; nothing real ever
// goes into one kept off the screen, so it is said to, once, before the first thing that needs it.
void EditorWindow::enter(uintptr_t w, int cx, int cy, int rx, int ry) {
	Xlib &X = Xlib::get();
	if (w == entered) return;
	XEvent e;
	std::memset(&e, 0, sizeof e);
	e.xcrossing.type = EnterNotify;
	e.xcrossing.display = X.dpy;
	e.xcrossing.window = w;
	e.xcrossing.root = event_root(X, in_menu, w);
	e.xcrossing.x = cx;
	e.xcrossing.y = cy;
	e.xcrossing.x_root = rx;
	e.xcrossing.y_root = ry;
	e.xcrossing.mode = NotifyNormal;
	e.xcrossing.detail = NotifyNonlinear;
	e.xcrossing.same_screen = True;
	e.xcrossing.time = CurrentTime;
	X.XSendEvent(X.dpy, w, True, EnterWindowMask, &e);
	entered = w;
}

void EditorWindow::pointer_move(int x, int y) {
	Xlib &X = Xlib::get();
	if (!holder) return;
	if (!target) target = content();
	pointer_x = x;
	pointer_y = y;
	last_motion = seconds();
	keep_menus_hidden();
	int cx, cy, rx, ry;
	tell_where(target);
	Window w = under(x, y, cx, cy, rx, ry);
	enter(w, cx, cy, rx, ry);
	XEvent e;
	std::memset(&e, 0, sizeof e);
	e.xmotion.type = MotionNotify;
	e.xmotion.display = X.dpy;
	e.xmotion.window = w;
	e.xmotion.root = event_root(X, in_menu, w);
	e.xmotion.x = cx;
	e.xmotion.y = cy;
	e.xmotion.x_root = rx;
	e.xmotion.y_root = ry;
	e.xmotion.state = held;
	e.xmotion.same_screen = True;
	e.xmotion.time = CurrentTime;
	X.XSendEvent(X.dpy, w, True, PointerMotionMask | ButtonMotionMask, &e);
	X.XFlush(X.dpy);
}

void EditorWindow::send_button(int x, int y, int button, bool down) {
	Xlib &X = Xlib::get();
	if (!holder) return;
	if (!target) target = content();
	unsigned int mask = button == 1 ? Button1Mask : button == 2 ? Button2Mask : button == 3 ? Button3Mask : 0;
	// A click outside an open menu closes it, as on a desktop, and does nothing else.
	if (swallowing) {
		if (!down) swallowing = false;
		held = down ? (held | mask) : (held & ~mask);
		return;
	}
	const Popup *open = open_popup();
	if (down && open && !open_popup_at(x, y)) {
		for (bool press : { true, false }) {
			XEvent k;
			std::memset(&k, 0, sizeof k);
			k.xkey.type = press ? KeyPress : KeyRelease;
			k.xkey.display = X.dpy;
			k.xkey.window = (Window)open->window;
			k.xkey.root = DefaultRootWindow(X.dpy);
			k.xkey.keycode = X.XKeysymToKeycode(X.dpy, XK_Escape);
			k.xkey.same_screen = True;
			k.xkey.time = CurrentTime;
			X.XSendEvent(X.dpy, (Window)open->window, True, press ? KeyPressMask : KeyReleaseMask, &k);
		}
		X.XFlush(X.dpy);
		swallowing = button <= 3;
		held |= mask;
		return;
	}
	keep_menus_hidden();
	if (down && button <= 3) {
		if (menus_stay_put()) Active::get().hold(X, first_of_another(X, (Window)holder, 0), MENU_WITHIN);
		last_press = seconds();
		press_x = x;
		press_y = y;
	}
	int cx, cy, rx, ry;
	tell_where(target);
	Window w = under(x, y, cx, cy, rx, ry);
	enter(w, cx, cy, rx, ry);
	XEvent e;
	std::memset(&e, 0, sizeof e);
	e.xbutton.type = down ? ButtonPress : ButtonRelease;
	e.xbutton.display = X.dpy;
	e.xbutton.window = w;
	e.xbutton.root = event_root(X, in_menu, w);
	e.xbutton.x = cx;
	e.xbutton.y = cy;
	e.xbutton.x_root = rx;
	e.xbutton.y_root = ry;
	e.xbutton.button = (unsigned)button;
	e.xbutton.state = held;
	e.xbutton.same_screen = True;
	e.xbutton.time = CurrentTime;
	X.XSendEvent(X.dpy, w, True, down ? ButtonPressMask : ButtonReleaseMask, &e);
	held = down ? (held | mask) : (held & ~mask);
	X.XFlush(X.dpy);
}

void EditorWindow::pointer_button(int x, int y, int button, bool down) {
	send_button(x, y, button, down);
}

void EditorWindow::wheel(int x, int y, int notches) {
	int button = notches > 0 ? 4 : 5;
	for (int i = 0; i < std::abs(notches); i++) {
		send_button(x, y, button, true);
		send_button(x, y, button, false);
	}
}

void EditorWindow::key(unsigned long keysym, bool down, unsigned int modifiers) {
	Xlib &X = Xlib::get();
	if (!holder) return;
	if (!target) target = content();
	// To an open menu, or to whatever the pointer last went into: the plugin's own idea of focus
	// follows it.
	const Popup *open = open_popup();
	Window w = open ? (Window)open->window : entered ? entered : target;
	XEvent e;
	std::memset(&e, 0, sizeof e);
	e.xkey.type = down ? KeyPress : KeyRelease;
	e.xkey.display = X.dpy;
	e.xkey.window = w;
	e.xkey.root = DefaultRootWindow(X.dpy);
	e.xkey.state = modifiers | held;
	e.xkey.keycode = X.XKeysymToKeycode(X.dpy, (KeySym)keysym);
	e.xkey.same_screen = True;
	e.xkey.time = CurrentTime;
	X.XSendEvent(X.dpy, w, True, down ? KeyPressMask : KeyReleaseMask, &e);
	X.XFlush(X.dpy);
}

} // namespace dawkit
