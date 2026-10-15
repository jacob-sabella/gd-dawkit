#pragma once

// A plugin's own window, kept where no one sees it and shown as a picture instead.
//
// The plugin is given a window of ours to put its window in (CLAP's, VST3's and LV2's way of
// embedding one), far off every screen, so nothing appears on the desktop. The picture is read
// back from it, and the pointer is sent into it, never faked, so nothing else on the desktop is
// ever clicked by mistake. One implementation a system:
//
//   x11_editor.cpp     an override-redirect X window; XGetImage; XSendEvent. Xlib is opened at run
//                      time: without it (no X server) there are no windows, and plugins still play.
//   win32_editor.cpp   a tool window off the desktop; PrintWindow; posted mouse messages.

#include <cstdint>
#include <string>
#include <vector>

namespace dawkit {

class EditorWindow {
public:
	// Whether plugin windows can be kept here (on Linux, whether there is an X display).
	static bool available(std::string *why = nullptr);

	EditorWindow() = default;
	EditorWindow(const EditorWindow &) = delete;
	EditorWindow &operator=(const EditorWindow &) = delete;
	~EditorWindow() { destroy(); }

	// The window for the plugin to embed in, `width` by `height` (it is resized to fit whatever the
	// plugin puts in it).
	bool create(int width, int height, std::string &why);
	uintptr_t window() const { return holder; }
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
	uintptr_t content();
	uintptr_t under(int x, int y, int &cx, int &cy);
	void tell_where(uintptr_t w);
	void enter(uintptr_t w, int cx, int cy, int rx, int ry);
	void send_button(int x, int y, int button, bool down);

	uintptr_t holder = 0;
	uintptr_t target = 0;
	uintptr_t entered = 0;
	uintptr_t told_window = 0;
	int told_x = 0, told_y = 0;
	int width = 0, height = 0;
	unsigned int held = 0;
	std::vector<uint8_t> last;
};

} // namespace dawkit
