#include "x11_editor.h"
#include "library.h"

#include <X11/Xlib.h>
#include <X11/Xutil.h>

#include <cstdlib>
#include <cstring>

namespace dawkit {

namespace {

#define DAWKIT_XLIB(X)                                                                                 \
	X(XOpenDisplay) X(XCreateWindow) X(XDestroyWindow) X(XMapWindow) X(XResizeWindow)                  \
	X(XGetWindowAttributes) X(XGetImage) X(XTranslateCoordinates) X(XSendEvent) X(XFlush) X(XSync)     \
	X(XSetErrorHandler) X(XQueryTree) X(XFree) X(XKeysymToKeycode) X(XPending) X(XNextEvent)           \
	X(XSelectInput) X(XMoveWindow)

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
	}
};

// Off every screen, for as long as the compositor leaves it there.
constexpr int HOLDER_X = -30000;

} // namespace

bool X11Editor::available(std::string *why) {
	Xlib &X = Xlib::get();
	if (!X.dpy && why) {
		*why = X.missing;
	}
	return X.dpy != nullptr;
}

bool X11Editor::create(int w, int h, std::string &why) {
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
	return true;
}

void X11Editor::resize(int w, int h) {
	Xlib &X = Xlib::get();
	if (!holder || w <= 0 || h <= 0 || (w == width && h == height)) {
		return;
	}
	width = w;
	height = h;
	X.XResizeWindow(X.dpy, holder, (unsigned)w, (unsigned)h);
	if (unsigned long c = content(); c && c != holder) {
		X.XResizeWindow(X.dpy, c, (unsigned)w, (unsigned)h);
	}
	X.XFlush(X.dpy);
}

void X11Editor::destroy() {
	Xlib &X = Xlib::get();
	if (holder && X.dpy) {
		X.XDestroyWindow(X.dpy, holder);
		X.XSync(X.dpy, False);
	}
	holder = target = entered = told_window = 0;
	last.clear();
}

// The plugin's window in ours: the biggest one showing, or ours when it has put none there yet.
unsigned long X11Editor::content() {
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

void X11Editor::pump() {
	Xlib &X = Xlib::get();
	if (!X.dpy) return;
	while (X.XPending(X.dpy)) {
		XEvent e;
		X.XNextEvent(X.dpy, &e);
	}
	if (!holder) return;
	// A plugin that sizes its own window, without saying so through the format's own call.
	unsigned long c = content();
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
void X11Editor::tell_where(unsigned long w) {
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

bool X11Editor::capture(std::vector<uint8_t> &rgba, int &w, int &h, bool &same) {
	Xlib &X = Xlib::get();
	same = false;
	if (!holder) return false;
	target = content();
	XWindowAttributes a;
	if (!target || !X.XGetWindowAttributes(X.dpy, target, &a) || a.width < 1 || a.height < 1) {
		return false;
	}
	XImage *img = X.XGetImage(X.dpy, target, 0, 0, (unsigned)a.width, (unsigned)a.height, AllPlanes, ZPixmap);
	if (!img) {
		return false;
	}
	size_t size = (size_t)a.width * a.height * 4;
	std::vector<uint8_t> px(size);
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
	w = a.width;
	h = a.height;
	if (last.size() == size && std::memcmp(last.data(), px.data(), size) == 0) {
		same = true;
		return true;
	}
	last = px;
	rgba = std::move(px);
	return true;
}

// The deepest window under (x, y), and the point in its own coordinates: it is the one listening.
unsigned long X11Editor::under(int x, int y, int &cx, int &cy) {
	Xlib &X = Xlib::get();
	Window w = target, child = 0;
	int bx, by;
	for (int i = 0; i < 8; i++) {
		if (!X.XTranslateCoordinates(X.dpy, target, w, x, y, &bx, &by, &child) || !child) break;
		w = child;
	}
	X.XTranslateCoordinates(X.dpy, target, w, x, y, &cx, &cy, &child);
	return w;
}

// GDK and Wine hand a click to the window they last saw the pointer go into; nothing real ever
// goes into one kept off the screen, so it is said to, once, before the first thing that needs it.
void X11Editor::enter(unsigned long w, int cx, int cy, int rx, int ry) {
	Xlib &X = Xlib::get();
	if (w == entered) return;
	XEvent e;
	std::memset(&e, 0, sizeof e);
	e.xcrossing.type = EnterNotify;
	e.xcrossing.display = X.dpy;
	e.xcrossing.window = w;
	e.xcrossing.root = DefaultRootWindow(X.dpy);
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

void X11Editor::pointer_move(int x, int y) {
	Xlib &X = Xlib::get();
	if (!holder) return;
	if (!target) target = content();
	int cx, cy, rx, ry;
	Window dummy;
	Window w = under(x, y, cx, cy);
	tell_where(target);
	X.XTranslateCoordinates(X.dpy, target, DefaultRootWindow(X.dpy), x, y, &rx, &ry, &dummy);
	enter(w, cx, cy, rx, ry);
	XEvent e;
	std::memset(&e, 0, sizeof e);
	e.xmotion.type = MotionNotify;
	e.xmotion.display = X.dpy;
	e.xmotion.window = w;
	e.xmotion.root = DefaultRootWindow(X.dpy);
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

void X11Editor::send_button(int x, int y, int button, bool down) {
	Xlib &X = Xlib::get();
	if (!holder) return;
	if (!target) target = content();
	int cx, cy, rx, ry;
	Window dummy;
	Window w = under(x, y, cx, cy);
	tell_where(target);
	X.XTranslateCoordinates(X.dpy, target, DefaultRootWindow(X.dpy), x, y, &rx, &ry, &dummy);
	enter(w, cx, cy, rx, ry);
	XEvent e;
	std::memset(&e, 0, sizeof e);
	e.xbutton.type = down ? ButtonPress : ButtonRelease;
	e.xbutton.display = X.dpy;
	e.xbutton.window = w;
	e.xbutton.root = DefaultRootWindow(X.dpy);
	e.xbutton.x = cx;
	e.xbutton.y = cy;
	e.xbutton.x_root = rx;
	e.xbutton.y_root = ry;
	e.xbutton.button = (unsigned)button;
	e.xbutton.state = held;
	e.xbutton.same_screen = True;
	e.xbutton.time = CurrentTime;
	X.XSendEvent(X.dpy, w, True, down ? ButtonPressMask : ButtonReleaseMask, &e);
	unsigned int mask = button == 1 ? Button1Mask : button == 2 ? Button2Mask : button == 3 ? Button3Mask : 0;
	held = down ? (held | mask) : (held & ~mask);
	X.XFlush(X.dpy);
}

void X11Editor::pointer_button(int x, int y, int button, bool down) {
	send_button(x, y, button, down);
}

void X11Editor::wheel(int x, int y, int notches) {
	int button = notches > 0 ? 4 : 5;
	for (int i = 0; i < std::abs(notches); i++) {
		send_button(x, y, button, true);
		send_button(x, y, button, false);
	}
}

void X11Editor::key(unsigned long keysym, bool down, unsigned int modifiers) {
	Xlib &X = Xlib::get();
	if (!holder) return;
	if (!target) target = content();
	// To whatever the pointer last went into: the plugin's own idea of focus follows it.
	Window w = entered ? entered : target;
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
