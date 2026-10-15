#pragma once

// A shared library opened at run time: a plugin's code, or a system library the engine only uses
// when it is there (lilv, Xlib), so the engine itself never fails to load for want of one.

#include <string>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace dawkit {

class Library {
public:
	Library() = default;
	Library(const Library &) = delete;
	Library &operator=(const Library &) = delete;
	~Library() { close(); }

	bool open(const std::string &path, std::string &problem) {
		close();
#ifdef _WIN32
		handle = (void *)LoadLibraryA(path.c_str());
		if (!handle) {
			problem = "could not load " + path;
		}
#else
		handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
		if (!handle) {
			const char *why = dlerror();
			problem = why ? why : ("could not load " + path);
		}
#endif
		return handle != nullptr;
	}

	// The first of `names` that opens.
	bool open_any(std::initializer_list<const char *> names) {
		std::string ignored;
		for (const char *n : names) {
			if (open(n, ignored)) {
				return true;
			}
		}
		return false;
	}

	void *symbol(const char *name) const {
		if (!handle) {
			return nullptr;
		}
#ifdef _WIN32
		return (void *)GetProcAddress((HMODULE)handle, name);
#else
		return dlsym(handle, name);
#endif
	}

	template <typename T>
	bool get(const char *name, T &out) const {
		out = reinterpret_cast<T>(symbol(name));
		return out != nullptr;
	}

	bool is_open() const { return handle != nullptr; }
	void *native() const { return handle; }

	void close() {
		if (!handle) {
			return;
		}
#ifdef _WIN32
		FreeLibrary((HMODULE)handle);
#else
		dlclose(handle);
#endif
		handle = nullptr;
	}

	// Keep the code in memory for good: some plugins cannot be unloaded and reloaded safely.
	void leak() { handle = nullptr; }

private:
	void *handle = nullptr;
};

} // namespace dawkit
