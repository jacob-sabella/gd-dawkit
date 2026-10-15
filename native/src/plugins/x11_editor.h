#pragma once

// A plugin's own window, kept where no one sees it and shown as a picture instead.
//
// The plugin is given a window of ours to put its window in (CLAP's, VST3's and LV2's way of
// embedding one): an override-redirect window far off every screen, so no compositor puts it on the
// desktop. The picture is read back with XGetImage, which works on a window no one is looking at;
// the pointer is sent, never faked, so nothing else on the desktop is ever clicked by mistake.
//
// Xlib is opened at run time: without it (no X server, or Wayland with no XWayland) there are no
// plugin windows, and plugins still play with their parameters.

#include <cstdint>
#include <string>
#include <vector>

namespace dawkit {

class X11Editor {
public:
	// Whether there is an X display to keep plugin windows on.
	static bool available(std::string *why = nullptr);

	X11Editor() = default;
	X11Editor(const X11Editor &) = delete;
	X11Editor &operator=(const X11Editor &) = delete;
	~X11Editor() { destroy(); }

	// The window for the plugin to embed in, `width` by `height` (it is resized to fit whatever the
	// plugin puts in it).
	bool create(int width, int height, std::string &why);
	unsigned long window() const { return holder; }
	void resize(int width, int height);
	void destroy();

	// The plugin's window as it is now, RGBA, `width` by `height`. `same` when nothing changed since
	// the last capture (and `rgba` is left as it was). False while there is nothing to show.
	bool capture(std::vector<uint8_t> &rgba, int &width, int &height, bool &same);

	// At (x, y) of the picture. Buttons are X's: 1 left, 2 middle, 3 right.
	void pointer_move(int x, int y);
	void pointer_button(int x, int y, int button, bool down);
	void wheel(int x, int y, int notches);
	// A key, by its X keysym, with shift/control held as `modifiers` (X's ShiftMask, ControlMask...).
	void key(unsigned long keysym, bool down, unsigned int modifiers);

	// Once a frame: follows the plugin's window when it changes size of itself.
	void pump();

private:
	unsigned long content();
	unsigned long under(int x, int y, int &cx, int &cy);
	void tell_where(unsigned long w);
	void enter(unsigned long w, int cx, int cy, int rx, int ry);
	void send_button(int x, int y, int button, bool down);

	unsigned long holder = 0;
	unsigned long target = 0;
	unsigned long entered = 0;
	unsigned long told_window = 0;
	int told_x = 0, told_y = 0;
	int width = 0, height = 0;
	unsigned int held = 0;
	std::vector<uint8_t> last;
};

} // namespace dawkit
