// VST3 plugins, through Steinberg's interfaces (native/third_party/vst3, MIT since 3.8). Only the
// interface headers are used, not the SDK's hosting library: every host-side object is here.
//
// Interfaces are compared by their raw ids (`X_iid`, which the headers define inline), so nothing
// needs the SDK's FUID class or its generated `X::iid` symbols.

#include "hosted_plugin.h"
#include "library.h"

#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstattributes.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivsthostapplication.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <map>
#include <unordered_map>
#include <variant>

namespace fs = std::filesystem;
using namespace Steinberg;
using namespace Steinberg::Vst;

namespace dawkit {

// The kind of window a plugin's view is put in, here.
#ifdef _WIN32
static const FIDString WINDOW_TYPE = kPlatformTypeHWND;
#else
static const FIDString WINDOW_TYPE = kPlatformTypeX11EmbedWindowID;
#endif

namespace {

// --- COM plumbing -------------------------------------------------------------------------------

template <class I>
const TUID &iid_of();
#define DAWKIT_IID(NS, I)                \
	template <>                          \
	const TUID &iid_of<NS::I>() {        \
		return NS::I##_iid;              \
	}
DAWKIT_IID(Steinberg, FUnknown)
DAWKIT_IID(Steinberg, IBStream)
DAWKIT_IID(Steinberg, IPlugFrame)
DAWKIT_IID(Steinberg, IPluginFactory2)
DAWKIT_IID(Steinberg, IPluginFactory3)
DAWKIT_IID(Steinberg::Linux, IRunLoop)
DAWKIT_IID(Steinberg::Vst, IHostApplication)
DAWKIT_IID(Steinberg::Vst, IComponentHandler)
DAWKIT_IID(Steinberg::Vst, IComponentHandler2)
DAWKIT_IID(Steinberg::Vst, IMessage)
DAWKIT_IID(Steinberg::Vst, IAttributeList)
DAWKIT_IID(Steinberg::Vst, IParamValueQueue)
DAWKIT_IID(Steinberg::Vst, IParameterChanges)
DAWKIT_IID(Steinberg::Vst, IEventList)

bool same(const TUID a, const TUID b) {
	return std::memcmp(a, b, sizeof(TUID)) == 0;
}

// One reference-counted object answering for each of `Is`.
template <class Self, class First, class... Rest>
class Com : public First, public Rest... {
public:
	tresult PLUGIN_API queryInterface(const TUID id, void **obj) override {
		if (same(id, iid_of<FUnknown>()) || same(id, iid_of<First>())) {
			*obj = static_cast<First *>(this);
			addRef();
			return kResultOk;
		}
		void *found = nullptr;
		((found = found ? found : (same(id, iid_of<Rest>()) ? static_cast<Rest *>(this) : nullptr)), ...);
		if (found) {
			*obj = found;
			addRef();
			return kResultOk;
		}
		*obj = nullptr;
		return kNoInterface;
	}
	uint32 PLUGIN_API addRef() override { return ++refs; }
	uint32 PLUGIN_API release() override {
		uint32 r = --refs;
		if (r == 0) {
			delete static_cast<Self *>(this);
		}
		return r;
	}
	virtual ~Com() = default;

private:
	std::atomic<uint32> refs{ 1 };
};

template <class I>
I *query(FUnknown *from) {
	if (!from) {
		return nullptr;
	}
	void *out = nullptr;
	if (from->queryInterface(iid_of<I>(), &out) != kResultOk) {
		return nullptr;
	}
	return (I *)out;
}

template <class T>
void drop(T *&p) {
	if (p) {
		p->release();
		p = nullptr;
	}
}

std::string utf8(const char16 *s) {
	std::string out;
	for (int i = 0; s && s[i]; i++) {
		uint32_t c = (uint16_t)s[i];
		if (c >= 0xD800 && c < 0xDC00 && s[i + 1]) {
			c = 0x10000 + ((c - 0xD800) << 10) + ((uint16_t)s[i + 1] - 0xDC00);
			i++;
		}
		if (c < 0x80) {
			out += (char)c;
		} else if (c < 0x800) {
			out += (char)(0xC0 | (c >> 6));
			out += (char)(0x80 | (c & 63));
		} else if (c < 0x10000) {
			out += (char)(0xE0 | (c >> 12));
			out += (char)(0x80 | ((c >> 6) & 63));
			out += (char)(0x80 | (c & 63));
		} else {
			out += (char)(0xF0 | (c >> 18));
			out += (char)(0x80 | ((c >> 12) & 63));
			out += (char)(0x80 | ((c >> 6) & 63));
			out += (char)(0x80 | (c & 63));
		}
	}
	return out;
}

void to_utf16(const std::string &s, String128 out) {
	size_t n = 0;
	for (size_t i = 0; i < s.size() && n < 127; i++) {
		out[n++] = (char16)(unsigned char)s[i];
	}
	out[n] = 0;
}

std::string hex_of(const TUID id) {
	static const char *digits = "0123456789ABCDEF";
	std::string out;
	for (int i = 0; i < 16; i++) {
		out += digits[((unsigned char)id[i]) >> 4];
		out += digits[((unsigned char)id[i]) & 15];
	}
	return out;
}

bool tuid_of(const std::string &hex, TUID out) {
	if (hex.size() != 32) {
		return false;
	}
	for (int i = 0; i < 16; i++) {
		out[i] = (char)std::stoi(hex.substr(i * 2, 2), nullptr, 16);
	}
	return true;
}

// --- what the host hands the plugin ----------------------------------------------------------

class AttributeList : public Com<AttributeList, IAttributeList> {
public:
	using Value = std::variant<int64, double, std::u16string, std::vector<uint8_t>>;
	std::map<std::string, Value> values;

	tresult PLUGIN_API setInt(AttrID id, int64 v) override {
		values[id] = v;
		return kResultOk;
	}
	tresult PLUGIN_API getInt(AttrID id, int64 &v) override {
		auto it = values.find(id);
		if (it == values.end() || !std::holds_alternative<int64>(it->second)) return kResultFalse;
		v = std::get<int64>(it->second);
		return kResultOk;
	}
	tresult PLUGIN_API setFloat(AttrID id, double v) override {
		values[id] = v;
		return kResultOk;
	}
	tresult PLUGIN_API getFloat(AttrID id, double &v) override {
		auto it = values.find(id);
		if (it == values.end() || !std::holds_alternative<double>(it->second)) return kResultFalse;
		v = std::get<double>(it->second);
		return kResultOk;
	}
	tresult PLUGIN_API setString(AttrID id, const TChar *s) override {
		std::u16string v;
		for (int i = 0; s && s[i]; i++) v += (char16_t)s[i];
		values[id] = v;
		return kResultOk;
	}
	tresult PLUGIN_API getString(AttrID id, TChar *s, uint32 size) override {
		auto it = values.find(id);
		if (it == values.end() || !std::holds_alternative<std::u16string>(it->second)) return kResultFalse;
		const std::u16string &v = std::get<std::u16string>(it->second);
		uint32 chars = size / sizeof(TChar);
		if (chars == 0) return kResultFalse;
		uint32 n = std::min<uint32>((uint32)v.size(), chars - 1);
		for (uint32 i = 0; i < n; i++) s[i] = (TChar)v[i];
		s[n] = 0;
		return kResultOk;
	}
	tresult PLUGIN_API setBinary(AttrID id, const void *data, uint32 size) override {
		values[id] = std::vector<uint8_t>((const uint8_t *)data, (const uint8_t *)data + size);
		return kResultOk;
	}
	tresult PLUGIN_API getBinary(AttrID id, const void *&data, uint32 &size) override {
		auto it = values.find(id);
		if (it == values.end() || !std::holds_alternative<std::vector<uint8_t>>(it->second)) return kResultFalse;
		const auto &v = std::get<std::vector<uint8_t>>(it->second);
		data = v.data();
		size = (uint32)v.size();
		return kResultOk;
	}
};

class Message : public Com<Message, IMessage> {
public:
	Message() { attrs = new AttributeList(); }
	~Message() override { attrs->release(); }
	FIDString PLUGIN_API getMessageID() override { return id.c_str(); }
	void PLUGIN_API setMessageID(FIDString v) override { id = v ? v : ""; }
	IAttributeList *PLUGIN_API getAttributes() override { return attrs; }

private:
	std::string id;
	AttributeList *attrs;
};

class HostApplication : public Com<HostApplication, IHostApplication> {
public:
	tresult PLUGIN_API getName(String128 name) override {
		to_utf16("dawkit", name);
		return kResultOk;
	}
	tresult PLUGIN_API createInstance(TUID cid, TUID id, void **obj) override {
		if (same(cid, iid_of<IMessage>()) && same(id, iid_of<IMessage>())) {
			*obj = static_cast<IMessage *>(new Message());
			return kResultOk;
		}
		if (same(cid, iid_of<IAttributeList>()) && same(id, iid_of<IAttributeList>())) {
			*obj = static_cast<IAttributeList *>(new AttributeList());
			return kResultOk;
		}
		*obj = nullptr;
		return kResultFalse;
	}
};

HostApplication *host_application() {
	static HostApplication *host = new HostApplication();
	return host;
}

class MemoryStream : public Com<MemoryStream, IBStream> {
public:
	std::vector<uint8_t> data;
	int64 at = 0;

	tresult PLUGIN_API read(void *buffer, int32 bytes, int32 *done) override {
		int64 n = std::max<int64>(0, std::min<int64>(bytes, (int64)data.size() - at));
		if (n > 0) std::memcpy(buffer, data.data() + at, (size_t)n);
		at += n;
		if (done) *done = (int32)n;
		return kResultOk;
	}
	tresult PLUGIN_API write(void *buffer, int32 bytes, int32 *done) override {
		if (bytes < 0) return kInvalidArgument;
		if (at + bytes > (int64)data.size()) data.resize((size_t)(at + bytes));
		std::memcpy(data.data() + at, buffer, (size_t)bytes);
		at += bytes;
		if (done) *done = bytes;
		return kResultOk;
	}
	tresult PLUGIN_API seek(int64 pos, int32 mode, int64 *result) override {
		int64 to = mode == kIBSeekSet ? pos : mode == kIBSeekCur ? at + pos : (int64)data.size() + pos;
		if (to < 0) return kInvalidArgument;
		at = to;
		if (result) *result = at;
		return kResultOk;
	}
	tresult PLUGIN_API tell(int64 *pos) override {
		if (pos) *pos = at;
		return kResultOk;
	}
};

// A block's parameter changes, from a pool made once so the audio thread never allocates.
class ParamQueue : public Com<ParamQueue, IParamValueQueue> {
public:
	ParamID id = 0;
	int32 count = 0;
	static constexpr int MAX = 64;
	int32 offsets[MAX];
	ParamValue values[MAX];

	ParamID PLUGIN_API getParameterId() override { return id; }
	int32 PLUGIN_API getPointCount() override { return count; }
	tresult PLUGIN_API getPoint(int32 i, int32 &offset, ParamValue &value) override {
		if (i < 0 || i >= count) return kResultFalse;
		offset = offsets[i];
		value = values[i];
		return kResultOk;
	}
	tresult PLUGIN_API addPoint(int32 offset, ParamValue value, int32 &index) override {
		// A second change at the same sample replaces the first.
		for (int32 i = 0; i < count; i++) {
			if (offsets[i] == offset) {
				values[i] = value;
				index = i;
				return kResultOk;
			}
		}
		if (count >= MAX) return kResultFalse;
		int32 at = count;
		while (at > 0 && offsets[at - 1] > offset) {
			offsets[at] = offsets[at - 1];
			values[at] = values[at - 1];
			at--;
		}
		offsets[at] = offset;
		values[at] = value;
		count++;
		index = at;
		return kResultOk;
	}
};

class ParamChanges : public Com<ParamChanges, IParameterChanges> {
public:
	static constexpr int MAX = 512;
	ParamQueue *queues[MAX];
	int32 used = 0;

	ParamChanges() {
		for (int i = 0; i < MAX; i++) queues[i] = new ParamQueue();
	}
	~ParamChanges() override {
		for (int i = 0; i < MAX; i++) queues[i]->release();
	}
	void clear() { used = 0; }
	int32 PLUGIN_API getParameterCount() override { return used; }
	IParamValueQueue *PLUGIN_API getParameterData(int32 i) override { return i >= 0 && i < used ? queues[i] : nullptr; }
	IParamValueQueue *PLUGIN_API addParameterData(const ParamID &id, int32 &index) override {
		for (int32 i = 0; i < used; i++) {
			if (queues[i]->id == id) {
				index = i;
				return queues[i];
			}
		}
		if (used >= MAX) return nullptr;
		ParamQueue *q = queues[used];
		q->id = id;
		q->count = 0;
		index = used++;
		return q;
	}
};

class EventList : public Com<EventList, IEventList> {
public:
	static constexpr int MAX = 1024;
	Steinberg::Vst::Event events[MAX];
	int32 used = 0;
	void clear() { used = 0; }
	int32 PLUGIN_API getEventCount() override { return used; }
	tresult PLUGIN_API getEvent(int32 i, Steinberg::Vst::Event &e) override {
		if (i < 0 || i >= used) return kResultFalse;
		e = events[i];
		return kResultOk;
	}
	tresult PLUGIN_API addEvent(Steinberg::Vst::Event &e) override {
		if (used >= MAX) return kResultFalse;
		events[used++] = e;
		return kResultOk;
	}
};

class Vst3Plugin;

// The plugin's window is in this host's, and its run loop is the host's (Linux plugins ask for it).
class Frame : public Com<Frame, IPlugFrame, Linux::IRunLoop> {
public:
	Vst3Plugin *owner = nullptr;
	struct Handler {
		FUnknown *handler;
		int loop_id;
	};
	std::vector<Handler> handlers;

	~Frame() override { forget_all(); }
	void forget_all() {
		for (Handler &h : handlers) {
			RunLoop::get().remove(h.loop_id);
			h.handler->release();
		}
		handlers.clear();
	}

	tresult PLUGIN_API resizeView(IPlugView *view, ViewRect *size) override;

	tresult PLUGIN_API registerEventHandler(Linux::IEventHandler *handler, Linux::FileDescriptor fd) override {
		if (!handler) return kInvalidArgument;
		handler->addRef();
		int id = RunLoop::get().add_fd(fd, [handler, fd]() { handler->onFDIsSet(fd); });
		handlers.push_back({ handler, id });
		return kResultOk;
	}
	tresult PLUGIN_API unregisterEventHandler(Linux::IEventHandler *handler) override { return forget(handler); }
	tresult PLUGIN_API registerTimer(Linux::ITimerHandler *handler, Linux::TimerInterval ms) override {
		if (!handler) return kInvalidArgument;
		handler->addRef();
		int id = RunLoop::get().add_timer((int)ms, [handler]() { handler->onTimer(); });
		handlers.push_back({ handler, id });
		return kResultOk;
	}
	tresult PLUGIN_API unregisterTimer(Linux::ITimerHandler *handler) override { return forget(handler); }

private:
	tresult forget(FUnknown *handler) {
		bool found = false;
		for (auto it = handlers.begin(); it != handlers.end();) {
			if (it->handler == handler) {
				RunLoop::get().remove(it->loop_id);
				it->handler->release();
				it = handlers.erase(it);
				found = true;
			} else {
				++it;
			}
		}
		return found ? kResultOk : kInvalidArgument;
	}
};

class Handler : public Com<Handler, IComponentHandler, IComponentHandler2> {
public:
	Vst3Plugin *owner = nullptr;
	tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
	tresult PLUGIN_API performEdit(ParamID id, ParamValue value) override;
	tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
	tresult PLUGIN_API restartComponent(int32 flags) override;
	tresult PLUGIN_API setDirty(TBool) override { return kResultOk; }
	tresult PLUGIN_API requestOpenEditor(FIDString) override { return kResultFalse; }
	tresult PLUGIN_API startGroupEdit() override { return kResultOk; }
	tresult PLUGIN_API finishGroupEdit() override { return kResultOk; }
};

// --- the module -------------------------------------------------------------------------------

struct Vst3Module {
	Library lib;
	IPluginFactory *factory = nullptr;
	std::string path;
	bool entered = false;
	~Vst3Module() {
		drop(factory);
		if (entered) {
			bool (*exit_fn)() = nullptr;
			if (lib.get("ModuleExit", exit_fn)) {
				exit_fn();
			}
		}
	}
};

// The binary inside a bundle: Contents/<arch>-linux/<name>.so, or a plain .so given directly.
std::string binary_of(const std::string &path) {
	std::error_code ec;
	if (!fs::is_directory(path, ec)) {
		return path;
	}
#if defined(_WIN32)
	const char *arch = "x86_64-win";
	const char *ext = ".vst3";
#elif defined(__aarch64__)
	const char *arch = "aarch64-linux";
	const char *ext = ".so";
#else
	const char *arch = "x86_64-linux";
	const char *ext = ".so";
#endif
	fs::path dir = fs::path(path) / "Contents" / arch;
	fs::path wanted = dir / (fs::path(path).stem().string() + ext);
	if (fs::exists(wanted, ec)) {
		return wanted.string();
	}
	for (fs::directory_iterator it(dir, ec), end; !ec && it != end; it.increment(ec)) {
		if (it->path().extension() == ext) {
			return it->path().string();
		}
	}
	return "";
}

std::map<std::string, std::weak_ptr<Vst3Module>> &vst3_modules() {
	static std::map<std::string, std::weak_ptr<Vst3Module>> m;
	return m;
}

std::shared_ptr<Vst3Module> open_vst3(const std::string &path, std::string &problem) {
	auto &all = vst3_modules();
	auto it = all.find(path);
	if (it != all.end()) {
		if (auto had = it->second.lock()) {
			return had;
		}
	}
	std::string binary = binary_of(path);
	if (binary.empty()) {
		problem = path + " has no binary for this system";
		return nullptr;
	}
	auto m = std::make_shared<Vst3Module>();
	m->path = path;
	if (!m->lib.open(binary, problem)) {
		return nullptr;
	}
#ifndef _WIN32
	bool (*entry)(void *) = nullptr;
	if (m->lib.get("ModuleEntry", entry)) {
		if (!entry(m->lib.native())) {
			problem = path + " would not start (ModuleEntry)";
			return nullptr;
		}
		m->entered = true;
	}
#else
	bool (*entry)() = nullptr;
	if (m->lib.get("InitDll", entry)) {
		entry();
	}
#endif
	IPluginFactory *(*get_factory)() = nullptr;
	if (!m->lib.get("GetPluginFactory", get_factory)) {
		problem = path + " has no GetPluginFactory";
		return nullptr;
	}
	m->factory = get_factory();
	if (!m->factory) {
		problem = path + " gave no plugin factory";
		return nullptr;
	}
	if (auto *f3 = query<IPluginFactory3>(m->factory)) {
		f3->setHostContext(host_application());
		f3->release();
	}
	// Some plugins cannot be unloaded and loaded again in one process (static state, threads they
	// started); the code stays, and only the factory is let go.
	m->lib.leak();
	all[path] = m;
	return m;
}

PluginInfo info_of(const Vst3Module &m, IPluginFactory *f, int32 index, bool &is_audio) {
	PluginInfo info;
	info.format = "VST3";
	info.path = m.path;
	is_audio = false;
	PFactoryInfo factory_info;
	f->getFactoryInfo(&factory_info);
	info.vendor = factory_info.vendor;
	IPluginFactory2 *f2 = query<IPluginFactory2>(f);
	if (f2) {
		PClassInfo2 ci;
			if (f2->getClassInfo2(index, &ci) == kResultOk) {
			is_audio = std::strcmp(ci.category, kVstAudioEffectClass) == 0;
			info.id = hex_of(ci.cid);
			info.name = ci.name;
			if (ci.vendor[0]) info.vendor = ci.vendor;
			info.version = ci.version;
			info.category = ci.subCategories;
		}
		f2->release();
	}
	if (info.id.empty()) {
		PClassInfo ci;
			if (f->getClassInfo(index, &ci) == kResultOk) {
			is_audio = std::strcmp(ci.category, kVstAudioEffectClass) == 0;
			info.id = hex_of(ci.cid);
			info.name = ci.name;
		}
	}
	info.instrument = info.category.find("Instrument") != std::string::npos;
	info.has_editor = true;
	return info;
}

// --- the plugin -------------------------------------------------------------------------------

class Vst3Plugin final : public HostedPlugin {
public:
	explicit Vst3Plugin(std::shared_ptr<Vst3Module> m) : module(std::move(m)) {
		handler = new Handler();
		handler->owner = this;
		frame = new Frame();
		frame->owner = this;
	}

	~Vst3Plugin() override {
		editor_close();
		deactivate();
		if (component_point && controller_point) {
			component_point->disconnect(controller_point);
			controller_point->disconnect(component_point);
		}
		drop(component_point);
		drop(controller_point);
		drop(mapping);
		if (controller) {
			controller->setComponentHandler(nullptr);
			if (separate_controller) {
				controller->terminate();
			}
		}
		drop(controller);
		drop(processor);
		if (component) {
			component->terminate();
		}
		drop(component);
		handler->owner = nullptr;
		frame->owner = nullptr;
		frame->forget_all();
		drop(handler);
		drop(frame);
		for (Bus &b : in_buses) b.free();
		for (Bus &b : out_buses) b.free();
		drop(in_changes);
		drop(out_changes);
		drop(in_events);
	}

	bool load(const std::string &id_hex, std::string &why) {
		TUID cid;
		if (!tuid_of(id_hex, cid)) {
			why = "not a VST3 class id: " + id_hex;
			return false;
		}
		IPluginFactory *f = module->factory;
		int32 n = f->countClasses();
		for (int32 i = 0; i < n; i++) {
			bool is_audio = false;
			PluginInfo info = info_of(*module, f, i, is_audio);
			if (info.id == id_hex) {
				description = info;
			}
		}
		if (description.id.empty()) {
			why = "no plugin " + id_hex + " in " + module->path;
			return false;
		}
		void *obj = nullptr;
		if (f->createInstance((FIDString)cid, (FIDString)iid_of_component(), &obj) != kResultOk || !obj) {
			why = description.name + " could not be made";
			return false;
		}
		component = (IComponent *)obj;
		if (component->initialize(host_application()) != kResultOk) {
			why = description.name + " would not initialise";
			drop(component);
			return false;
		}
		processor = query_processor(component);
		if (!processor) {
			why = description.name + " does not process audio";
			return false;
		}
		// The controller: the component itself, or a class of its own that it names.
		controller = query_controller(component);
		if (!controller) {
			TUID ccid;
			if (component->getControllerClassId(ccid) == kResultOk) {
				void *cobj = nullptr;
				if (f->createInstance((FIDString)ccid, (FIDString)iid_of_controller(), &cobj) == kResultOk && cobj) {
					controller = (IEditController *)cobj;
					if (controller->initialize(host_application()) != kResultOk) {
						drop(controller);
					} else {
						separate_controller = true;
					}
				}
			}
		}
		if (controller && separate_controller) {
			component_point = query_point(component);
			controller_point = query_point(controller);
			if (component_point && controller_point) {
				component_point->connect(controller_point);
				controller_point->connect(component_point);
			}
		}
		if (controller) {
			controller->setComponentHandler(handler);
			MemoryStream *s = new MemoryStream();
			if (component->getState(s) == kResultOk) {
				s->at = 0;
				controller->setComponentState(s);
			}
			s->release();
			mapping = query_mapping(controller);
		}
		in_changes = new ParamChanges();
		out_changes = new ParamChanges();
		in_events = new EventList();
		read_buses();
		read_params();
		description.instrument = description.instrument || (inputs == 0 && event_inputs > 0);
		return true;
	}

	// --- the main thread ----------------------------------------------------------------------

	bool activate(double rate, int max_block) override {
		if (active.load()) {
			return true;
		}
		this->rate = rate;
		this->max_block = max_block;
		ProcessSetup setup;
		setup.processMode = kRealtime;
		setup.symbolicSampleSize = kSample32;
		setup.maxSamplesPerBlock = max_block;
		setup.sampleRate = rate;
		if (processor->setupProcessing(setup) != kResultOk) {
			problem = description.name + " would not run at this rate and block size";
			return false;
		}
		for (Bus &b : in_buses) b.alloc(max_block);
		for (Bus &b : out_buses) b.alloc(max_block);
		if (component->setActive(true) != kResultOk) {
			problem = description.name + " would not start";
			return false;
		}
		processor->setProcessing(true);
		samples = 0;
		active.store(true);
		return true;
	}

	void deactivate() override {
		if (!active.load()) {
			return;
		}
		active.store(false);
		processor->setProcessing(false);
		component->setActive(false);
	}

	void set_normalized(int i, double value) override {
		if (i < 0 || i >= param_count()) {
			return;
		}
		value = std::clamp(value, 0.0, 1.0);
		store_value(i, value, false);
		if (controller) {
			controller->setParamNormalized(params[i].format_id, value);
		}
		queue_to_audio(i, value);
	}

	std::string param_text(int i, double value) override {
		if (!controller || i < 0 || i >= param_count()) {
			return "";
		}
		String128 s;
		std::memset(s, 0, sizeof s);
		if (controller->getParamStringByValue(params[i].format_id, value, s) != kResultOk) {
			return "";
		}
		std::string out = utf8(s);
		if (!params[i].unit.empty() && out.find(params[i].unit) == std::string::npos) {
			out += " " + params[i].unit;
		}
		return out;
	}

	// The state as a .vstpreset: the format DAWproject files keep a VST3's state in, so a project
	// saved here opens with its plugins as they were in any DAW that reads them.
	bool get_state(std::vector<uint8_t> &out) override {
		MemoryStream *comp = new MemoryStream();
		bool ok = component->getState(comp) == kResultOk;
		MemoryStream *cont = new MemoryStream();
		bool has_cont = controller && controller->getState(cont) == kResultOk && !cont->data.empty();
		if (ok) {
			out.clear();
			put("VST3", out);
			put_i32(1, out);
			put(description.id, out); // 32 ASCII hex digits
			size_t list_at_pos = out.size();
			put_i64(0, out);
			int64 comp_at = (int64)out.size();
			out.insert(out.end(), comp->data.begin(), comp->data.end());
			int64 cont_at = (int64)out.size();
			if (has_cont) {
				out.insert(out.end(), cont->data.begin(), cont->data.end());
			}
			int64 list_at = (int64)out.size();
			put("List", out);
			put_i32(has_cont ? 2 : 1, out);
			put("Comp", out);
			put_i64(comp_at, out);
			put_i64((int64)comp->data.size(), out);
			if (has_cont) {
				put("Cont", out);
				put_i64(cont_at, out);
				put_i64((int64)cont->data.size(), out);
			}
			std::memcpy(out.data() + list_at_pos, &list_at, 8);
		}
		comp->release();
		cont->release();
		return ok;
	}

	bool set_state(const std::vector<uint8_t> &in) override {
		std::vector<uint8_t> comp, cont;
		if (in.size() >= 48 && std::memcmp(in.data(), "VST3", 4) == 0) {
			int64 list_at = 0;
			std::memcpy(&list_at, in.data() + 40, 8);
			if (list_at < 48 || list_at + 8 > (int64)in.size() || std::memcmp(in.data() + list_at, "List", 4) != 0) {
				problem = "a .vstpreset with no chunk list";
				return false;
			}
			int32 count = 0;
			std::memcpy(&count, in.data() + list_at + 4, 4);
			for (int32 i = 0; i < count; i++) {
				int64 at = list_at + 8 + i * 20;
				if (at + 20 > (int64)in.size()) break;
				int64 off = 0, size = 0;
				std::memcpy(&off, in.data() + at + 4, 8);
				std::memcpy(&size, in.data() + at + 12, 8);
				if (off < 0 || size < 0 || off + size > (int64)in.size()) continue;
				std::vector<uint8_t> chunk(in.begin() + off, in.begin() + off + size);
				if (std::memcmp(in.data() + at, "Comp", 4) == 0) comp = chunk;
				if (std::memcmp(in.data() + at, "Cont", 4) == 0) cont = chunk;
			}
		} else {
			comp = in; // a bare component state, as some DAWs keep it
		}
		MemoryStream *s = new MemoryStream();
		s->data = comp;
		bool ok = component->setState(s) == kResultOk;
		if (controller) {
			s->at = 0;
			controller->setComponentState(s);
			if (!cont.empty()) {
				MemoryStream *c = new MemoryStream();
				c->data = cont;
				controller->setState(c);
				c->release();
			}
		}
		s->release();
		refresh_values(true);
		return ok;
	}

	int latency() const override { return processor && active.load() ? (int)processor->getLatencySamples() : 0; }
	int tail_samples() const override {
		if (!processor || !active.load()) return 0;
		uint32 t = processor->getTailSamples();
		return t > (uint32)INT32_MAX ? INT32_MAX : (int)t;
	}

	void main_thread() override {
		int32 flags = restart_flags.exchange(0);
		if (flags & (kReloadComponent | kIoChanged)) {
			if (active.load()) {
				double r = rate;
				int b = max_block;
				deactivate();
				read_buses();
				activate(r, b);
			}
		}
		if (flags & kParamTitlesChanged) {
			read_params();
			mark_rescanned();
		} else if (flags & kParamValuesChanged) {
			refresh_values(true);
		}
	}

	bool editor_supported() override {
		if (!controller) return false;
		if (editor_known >= 0) return editor_known == 1;
		IPlugView *v = controller->createView(ViewType::kEditor);
		editor_known = v && v->isPlatformTypeSupported(WINDOW_TYPE) == kResultTrue ? 1 : 0;
		if (v) v->release();
		return editor_known == 1;
	}

	bool editor_open(uintptr_t parent, int &width, int &height) override {
		editor_close();
		if (!controller) {
			problem = description.name + " has no window";
			return false;
		}
		view = controller->createView(ViewType::kEditor);
		if (!view) {
			problem = description.name + " has no window";
			return false;
		}
		if (view->isPlatformTypeSupported(WINDOW_TYPE) != kResultTrue) {
			problem = description.name + " has no window this host can show";
			drop(view);
			return false;
		}
		view->setFrame(frame);
		ViewRect r;
		if (view->getSize(&r) == kResultOk) {
			width = r.getWidth();
			height = r.getHeight();
		}
		if (view->attached((void *)(uintptr_t)parent, WINDOW_TYPE) != kResultOk) {
			problem = description.name + " would not go into the window it was given";
			view->setFrame(nullptr);
			drop(view);
			return false;
		}
		ViewRect after;
		if (view->getSize(&after) == kResultOk && after.getWidth() > 0) {
			width = after.getWidth();
			height = after.getHeight();
		}
		return true;
	}

	void editor_close() override {
		if (view) {
			view->removed();
			view->setFrame(nullptr);
			drop(view);
		}
	}

	// --- the audio thread ---------------------------------------------------------------------

	void process(const float *const *in, float *const *out, int frames, const Event *events, int event_count,
			const Transport &t) override {
		if (!active.load() || frames > max_block) {
			for (int c = 0; c < outputs; c++) std::memset(out[c], 0, sizeof(float) * frames);
			return;
		}
		in_changes->clear();
		out_changes->clear();
		in_events->clear();
		ParamChange pc;
		while (to_audio.pop(pc)) {
			if (pc.index >= 0 && pc.index < param_count()) {
				int32 qi = 0;
				if (IParamValueQueue *q = in_changes->addParameterData(params[pc.index].format_id, qi)) {
					int32 pi = 0;
					q->addPoint(0, pc.value, pi);
				}
			}
		}
		for (int e = 0; e < event_count; e++) {
			const Event &ev = events[e];
			if (ev.kind == Event::NOTE_ON || ev.kind == Event::NOTE_OFF) {
				Steinberg::Vst::Event v;
				std::memset(&v, 0, sizeof v);
				v.busIndex = 0;
				v.sampleOffset = ev.offset;
				v.flags = Steinberg::Vst::Event::kIsLive;
				if (ev.kind == Event::NOTE_ON) {
					v.type = Steinberg::Vst::Event::kNoteOnEvent;
					v.noteOn.channel = ev.channel;
					v.noteOn.pitch = ev.key;
					v.noteOn.velocity = (float)ev.value;
					v.noteOn.noteId = -1;
				} else {
					v.type = Steinberg::Vst::Event::kNoteOffEvent;
					v.noteOff.channel = ev.channel;
					v.noteOff.pitch = ev.key;
					v.noteOff.velocity = (float)ev.value;
					v.noteOff.noteId = -1;
				}
				in_events->addEvent(v);
			} else if (mapping) {
				// A controller or a bend is a parameter in VST3: whichever the plugin maps it to.
				CtrlNumber cc = ev.kind == Event::PITCH_BEND ? (CtrlNumber)kPitchBend
						: ev.kind == Event::ALL_NOTES_OFF ? (CtrlNumber)123 : (CtrlNumber)ev.key;
				ParamID id = 0;
				if (mapping->getMidiControllerAssignment(0, ev.channel, cc, id) == kResultOk) {
					double v = ev.kind == Event::PITCH_BEND ? (ev.value + 1.0) * 0.5 : ev.value;
					int32 qi = 0;
					if (IParamValueQueue *q = in_changes->addParameterData(id, qi)) {
						int32 pi = 0;
						q->addPoint(ev.offset, std::clamp(v, 0.0, 1.0), pi);
					}
				}
			}
		}

		ProcessContext ctx;
		std::memset(&ctx, 0, sizeof ctx);
		ctx.state = ProcessContext::kTempoValid | ProcessContext::kTimeSigValid |
				ProcessContext::kProjectTimeMusicValid | ProcessContext::kBarPositionValid |
				ProcessContext::kContTimeValid | (t.playing ? ProcessContext::kPlaying : 0);
		ctx.sampleRate = rate;
		ctx.projectTimeSamples = (TSamples)std::llround(t.seconds * rate);
		ctx.continousTimeSamples = samples;
		ctx.projectTimeMusic = t.beats;
		ctx.barPositionMusic = t.bar_start;
		ctx.tempo = t.tempo;
		ctx.timeSigNumerator = t.numerator;
		ctx.timeSigDenominator = t.denominator;

		// The main buses get the host's buffers; any others, silence and somewhere to write.
		for (size_t b = 0; b < in_buses.size(); b++) {
			Bus &bus = in_buses[b];
			for (int c = 0; c < bus.channels; c++) {
				if (b == 0 && c < inputs && in) {
					bus.pointers[c] = const_cast<float *>(in[std::min(c, inputs - 1)]);
				} else {
					std::memset(bus.scratch[c], 0, sizeof(float) * frames);
					bus.pointers[c] = bus.scratch[c];
				}
			}
			bus.buffers.numChannels = bus.channels;
			bus.buffers.silenceFlags = 0;
			bus.buffers.channelBuffers32 = bus.pointers.data();
			in_buffers[b] = bus.buffers;
		}
		for (size_t b = 0; b < out_buses.size(); b++) {
			Bus &bus = out_buses[b];
			for (int c = 0; c < bus.channels; c++) {
				bus.pointers[c] = (b == 0 && c < outputs) ? out[c] : bus.scratch[c];
			}
			bus.buffers.numChannels = bus.channels;
			bus.buffers.silenceFlags = 0;
			bus.buffers.channelBuffers32 = bus.pointers.data();
			out_buffers[b] = bus.buffers;
		}

		ProcessData d;
		d.processMode = kRealtime;
		d.symbolicSampleSize = kSample32;
		d.numSamples = frames;
		d.numInputs = (int32)in_buses.size();
		d.numOutputs = (int32)out_buses.size();
		d.inputs = in_buses.empty() ? nullptr : in_buffers.data();
		d.outputs = out_buses.empty() ? nullptr : out_buffers.data();
		d.inputParameterChanges = in_changes;
		d.outputParameterChanges = out_changes;
		d.inputEvents = event_inputs > 0 ? in_events : nullptr;
		d.outputEvents = nullptr;
		d.processContext = &ctx;
		if (processor->process(d) != kResultOk) {
			for (int c = 0; c < outputs; c++) std::memset(out[c], 0, sizeof(float) * frames);
		}
		samples += frames;

		for (int32 i = 0; i < out_changes->used; i++) {
			ParamQueue *q = out_changes->queues[i];
			if (q->count > 0) {
				auto it = by_id.find(q->id);
				if (it != by_id.end()) {
					store_value(it->second, q->values[q->count - 1], true);
				}
			}
		}
	}

	// From the plugin's window, on whichever thread it edits from.
	void edited(ParamID id, ParamValue value) {
		auto it = by_id.find(id);
		if (it == by_id.end()) return;
		store_value(it->second, value, true);
		queue_to_audio(it->second, value);
	}
	void restart(int32 flags) { restart_flags.fetch_or(flags); }
	void view_resized(IPlugView *v, ViewRect *size) {
		if (v && size) {
			v->onSize(size);
			request_editor_size(size->getWidth(), size->getHeight());
		}
	}

private:
	static const TUID &iid_of_component() { return IComponent_iid; }
	static const TUID &iid_of_controller() { return IEditController_iid; }
	static IAudioProcessor *query_processor(FUnknown *u) {
		void *o = nullptr;
		return u->queryInterface(IAudioProcessor_iid, &o) == kResultOk ? (IAudioProcessor *)o : nullptr;
	}
	static IEditController *query_controller(FUnknown *u) {
		void *o = nullptr;
		return u->queryInterface(IEditController_iid, &o) == kResultOk ? (IEditController *)o : nullptr;
	}
	static IConnectionPoint *query_point(FUnknown *u) {
		void *o = nullptr;
		return u->queryInterface(IConnectionPoint_iid, &o) == kResultOk ? (IConnectionPoint *)o : nullptr;
	}
	static IMidiMapping *query_mapping(FUnknown *u) {
		void *o = nullptr;
		return u->queryInterface(IMidiMapping_iid, &o) == kResultOk ? (IMidiMapping *)o : nullptr;
	}

	static void put(const std::string &s, std::vector<uint8_t> &out) { out.insert(out.end(), s.begin(), s.end()); }
	static void put_i32(int32 v, std::vector<uint8_t> &out) {
		uint8_t b[4];
		std::memcpy(b, &v, 4);
		out.insert(out.end(), b, b + 4);
	}
	static void put_i64(int64 v, std::vector<uint8_t> &out) {
		uint8_t b[8];
		std::memcpy(b, &v, 8);
		out.insert(out.end(), b, b + 8);
	}

	struct Bus {
		int channels = 0;
		std::vector<float *> scratch;
		std::vector<float *> pointers;
		AudioBusBuffers buffers;
		void alloc(int frames) {
			free();
			for (int c = 0; c < channels; c++) scratch.push_back(new float[frames]());
			pointers.assign(channels, nullptr);
		}
		void free() {
			for (float *p : scratch) delete[] p;
			scratch.clear();
		}
	};

	void read_buses() {
		for (Bus &b : in_buses) b.free();
		for (Bus &b : out_buses) b.free();
		in_buses.clear();
		out_buses.clear();
		inputs = 0;
		outputs = 0;
		int32 n_in = component->getBusCount(kAudio, kInput);
		int32 n_out = component->getBusCount(kAudio, kOutput);
		event_inputs = component->getBusCount(kEvent, kInput);
		std::vector<SpeakerArrangement> in_arr, out_arr;
		for (int32 i = 0; i < n_in; i++) {
			BusInfo bi;
			std::memset(&bi, 0, sizeof bi);
			component->getBusInfo(kAudio, kInput, i, bi);
			in_arr.push_back(i == 0 ? SpeakerArr::kStereo : (bi.channelCount == 1 ? SpeakerArr::kMono : SpeakerArr::kStereo));
		}
		for (int32 i = 0; i < n_out; i++) {
			BusInfo bi;
			std::memset(&bi, 0, sizeof bi);
			component->getBusInfo(kAudio, kOutput, i, bi);
			out_arr.push_back(i == 0 ? SpeakerArr::kStereo : (bi.channelCount == 1 ? SpeakerArr::kMono : SpeakerArr::kStereo));
		}
		processor->setBusArrangements(in_arr.empty() ? nullptr : in_arr.data(), (int32)in_arr.size(),
				out_arr.empty() ? nullptr : out_arr.data(), (int32)out_arr.size());
		// What it settled on, which may not be what it was asked for.
		for (int32 i = 0; i < n_in; i++) {
			SpeakerArrangement a = 0;
			processor->getBusArrangement(kInput, i, a);
			Bus b;
			b.channels = std::max(SpeakerArr::getChannelCount(a), 0);
			in_buses.push_back(b);
			component->activateBus(kAudio, kInput, i, i == 0);
		}
		for (int32 i = 0; i < n_out; i++) {
			SpeakerArrangement a = 0;
			processor->getBusArrangement(kOutput, i, a);
			Bus b;
			b.channels = std::max(SpeakerArr::getChannelCount(a), 0);
			out_buses.push_back(b);
			component->activateBus(kAudio, kOutput, i, i == 0);
		}
		for (int32 i = 0; i < event_inputs; i++) {
			component->activateBus(kEvent, kInput, i, i == 0);
		}
		inputs = in_buses.empty() ? 0 : std::min(in_buses[0].channels, 2);
		outputs = out_buses.empty() ? 0 : std::min(out_buses[0].channels, 2);
		in_buffers.assign(in_buses.size(), AudioBusBuffers());
		out_buffers.assign(out_buses.size(), AudioBusBuffers());
		if (active.load()) {
			for (Bus &b : in_buses) b.alloc(max_block);
			for (Bus &b : out_buses) b.alloc(max_block);
		} else {
			for (Bus &b : in_buses) b.alloc(max_block);
			for (Bus &b : out_buses) b.alloc(max_block);
		}
	}

	void read_params() {
		std::vector<ParamInfo> list;
		by_id.clear();
		if (controller) {
			int32 n = controller->getParameterCount();
			for (int32 i = 0; i < n; i++) {
				ParameterInfo pi;
				std::memset(&pi, 0, sizeof pi);
				if (controller->getParameterInfo(i, pi) != kResultOk) continue;
				ParamInfo p;
				p.name = utf8(pi.title);
				p.unit = utf8(pi.units);
				p.steps = pi.stepCount;
				p.def = pi.defaultNormalizedValue;
				p.min = 0.0;
				p.max = pi.stepCount > 0 ? (double)pi.stepCount : 1.0;
				p.automatable = (pi.flags & ParameterInfo::kCanAutomate) != 0;
				p.read_only = (pi.flags & ParameterInfo::kIsReadOnly) != 0;
				p.hidden = (pi.flags & ParameterInfo::kIsHidden) != 0;
				p.bypass = (pi.flags & ParameterInfo::kIsBypass) != 0;
				p.format_id = pi.id;
				by_id[pi.id] = (int)list.size();
				list.push_back(p);
			}
		}
		set_params(std::move(list));
		refresh_values(false);
	}

	void refresh_values(bool tell) {
		if (!controller) return;
		for (int i = 0; i < param_count(); i++) {
			store_value(i, controller->getParamNormalized(params[i].format_id), tell);
		}
	}

	std::shared_ptr<Vst3Module> module;
	IComponent *component = nullptr;
	IAudioProcessor *processor = nullptr;
	IEditController *controller = nullptr;
	IConnectionPoint *component_point = nullptr;
	IConnectionPoint *controller_point = nullptr;
	IMidiMapping *mapping = nullptr;
	IPlugView *view = nullptr;
	Handler *handler = nullptr;
	Frame *frame = nullptr;
	ParamChanges *in_changes = nullptr;
	ParamChanges *out_changes = nullptr;
	EventList *in_events = nullptr;
	bool separate_controller = false;
	int editor_known = -1;
	std::vector<Bus> in_buses, out_buses;
	std::vector<AudioBusBuffers> in_buffers, out_buffers;
	int32 event_inputs = 0;
	std::unordered_map<ParamID, int> by_id;
	std::atomic<int32> restart_flags{ 0 };
	double rate = 48000.0;
	int max_block = 4096;
	int64 samples = 0;
};

tresult PLUGIN_API Frame::resizeView(IPlugView *view, ViewRect *size) {
	if (owner) owner->view_resized(view, size);
	return kResultOk;
}

tresult PLUGIN_API Handler::performEdit(ParamID id, ParamValue value) {
	if (owner) owner->edited(id, value);
	return kResultOk;
}

tresult PLUGIN_API Handler::restartComponent(int32 flags) {
	if (owner) owner->restart(flags);
	return kResultOk;
}

} // namespace

std::vector<PluginInfo> scan_vst3(const std::string &path, std::string &problem) {
	std::vector<PluginInfo> out;
	auto m = open_vst3(path, problem);
	if (!m) {
		return out;
	}
	int32 n = m->factory->countClasses();
	for (int32 i = 0; i < n; i++) {
		bool is_audio = false;
		PluginInfo info = info_of(*m, m->factory, i, is_audio);
		if (is_audio && !info.id.empty()) {
			out.push_back(info);
		}
	}
	return out;
}

std::unique_ptr<HostedPlugin> load_vst3(const std::string &path, const std::string &id, std::string &problem) {
	auto m = open_vst3(path, problem);
	if (!m) {
		return nullptr;
	}
	auto p = std::make_unique<Vst3Plugin>(m);
	if (!p->load(id, problem)) {
		return nullptr;
	}
	return p;
}

} // namespace dawkit
