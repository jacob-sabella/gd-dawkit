// LV2 plugins, through lilv (ISC), which is opened at run time: a system without it has no LV2
// plugins, and the engine still loads. Only lilv's header is vendored (native/third_party/lilv).
//
// Plugin windows are X11 ones (ui:X11UI), embedded through ui:parent. A plugin whose only window is
// a GTK or Qt widget would need suil to put it in one; those show their parameters instead.

#include "hosted_plugin.h"
#include "library.h"

#include "lilv/lilv.h"
#include "lv2/atom/atom.h"
#include "lv2/atom/forge.h"
#include "lv2/atom/util.h"
#include "lv2/buf-size/buf-size.h"
#include "lv2/core/lv2.h"
#include "lv2/data-access/data-access.h"
#include "lv2/instance-access/instance-access.h"
#include "lv2/log/log.h"
#include "lv2/midi/midi.h"
#include "lv2/options/options.h"
#include "lv2/parameters/parameters.h"
#include "lv2/port-props/port-props.h"
#include "lv2/state/state.h"
#include "lv2/time/time.h"
#include "lv2/ui/ui.h"
#include "lv2/units/units.h"
#include "lv2/urid/urid.h"
#include "lv2/worker/worker.h"

#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <deque>
#include <thread>
#include <unordered_map>

namespace dawkit {

namespace {

// --- lilv, as far as it is there ---------------------------------------------------------------

#define DAWKIT_LILV(X)                                                                                \
	X(lilv_world_new) X(lilv_world_load_all) X(lilv_world_get_all_plugins) X(lilv_world_get)          \
	X(lilv_world_find_nodes) X(lilv_plugins_begin) X(lilv_plugins_is_end) X(lilv_plugins_next)         \
	X(lilv_plugins_get) X(lilv_plugins_get_by_uri) X(lilv_new_uri) X(lilv_node_free)                   \
	X(lilv_node_as_string) X(lilv_node_as_uri) X(lilv_node_as_float) X(lilv_node_is_float)             \
	X(lilv_node_is_int) X(lilv_node_as_int) X(lilv_node_is_uri) X(lilv_node_equals) X(lilv_free)       \
	X(lilv_file_uri_parse) X(lilv_plugin_get_uri) X(lilv_plugin_get_name) X(lilv_plugin_get_author_name) \
	X(lilv_plugin_get_class) X(lilv_plugin_class_get_label) X(lilv_plugin_class_get_uri)              \
	X(lilv_plugin_get_bundle_uri) X(lilv_plugin_get_num_ports) X(lilv_plugin_get_port_by_index)       \
	X(lilv_plugin_get_uis) X(lilv_plugin_get_required_features) X(lilv_plugin_has_latency)            \
	X(lilv_plugin_get_latency_port_index) X(lilv_plugin_instantiate) X(lilv_instance_free)            \
	X(lilv_port_is_a) X(lilv_port_get_name) X(lilv_port_get_symbol) X(lilv_port_has_property)          \
	X(lilv_port_supports_event) X(lilv_port_get_scale_points) X(lilv_port_get) X(lilv_port_get_range)  \
	X(lilv_scale_points_begin) X(lilv_scale_points_is_end) X(lilv_scale_points_next)                   \
	X(lilv_scale_points_get) X(lilv_scale_points_free) X(lilv_scale_point_get_label)                  \
	X(lilv_scale_point_get_value) X(lilv_uis_begin) X(lilv_uis_is_end) X(lilv_uis_next) X(lilv_uis_get) \
	X(lilv_uis_free) X(lilv_ui_get_uri) X(lilv_ui_is_a) X(lilv_ui_get_binary_uri)                      \
	X(lilv_ui_get_bundle_uri) X(lilv_nodes_begin) X(lilv_nodes_is_end) X(lilv_nodes_next)              \
	X(lilv_nodes_get) X(lilv_nodes_free) X(lilv_nodes_size) X(lilv_state_new_from_instance)            \
	X(lilv_state_to_string) X(lilv_state_new_from_string) X(lilv_state_restore) X(lilv_state_free)    \
	X(lilv_plugin_get_value)

struct Lilv {
#define DAWKIT_LILV_FIELD(n) decltype(&::n) n = nullptr;
	DAWKIT_LILV(DAWKIT_LILV_FIELD)
#undef DAWKIT_LILV_FIELD

	Library lib;
	LilvWorld *world = nullptr;
	std::string missing;

	// Nodes asked about often, made once.
	LilvNode *audio_port, *control_port, *atom_port, *cv_port, *input_port, *output_port;
	LilvNode *midi_event, *time_position, *toggled, *integer, *enumeration, *logarithmic, *sample_rate;
	LilvNode *not_on_gui, *x11_ui, *instrument_class, *unit, *unit_symbol, *minimum_size, *rdfs_label;
	LilvNode *connection_optional;

	static Lilv &get() {
		static Lilv l;
		return l;
	}

	bool ok() const { return world != nullptr; }

private:
	Lilv() {
		if (!lib.open_any({ "liblilv-0.so.0", "liblilv-0.so" })) {
			missing = "lilv is not installed, so there are no LV2 plugins";
			return;
		}
		bool all = true;
#define DAWKIT_LILV_LOAD(n)                    \
	if (!lib.get(#n, n)) {                     \
		all = false;                           \
		missing = "lilv has no " #n;           \
	}
		DAWKIT_LILV(DAWKIT_LILV_LOAD)
#undef DAWKIT_LILV_LOAD
		if (!all) {
			return;
		}
		lib.leak();
		world = lilv_world_new();
		lilv_world_load_all(world);
		audio_port = lilv_new_uri(world, LV2_CORE__AudioPort);
		control_port = lilv_new_uri(world, LV2_CORE__ControlPort);
		atom_port = lilv_new_uri(world, LV2_ATOM__AtomPort);
		cv_port = lilv_new_uri(world, LV2_CORE__CVPort);
		input_port = lilv_new_uri(world, LV2_CORE__InputPort);
		output_port = lilv_new_uri(world, LV2_CORE__OutputPort);
		midi_event = lilv_new_uri(world, LV2_MIDI__MidiEvent);
		time_position = lilv_new_uri(world, LV2_TIME__Position);
		toggled = lilv_new_uri(world, LV2_CORE__toggled);
		integer = lilv_new_uri(world, LV2_CORE__integer);
		enumeration = lilv_new_uri(world, LV2_CORE__enumeration);
		logarithmic = lilv_new_uri(world, LV2_PORT_PROPS__logarithmic);
		sample_rate = lilv_new_uri(world, LV2_CORE__sampleRate);
		not_on_gui = lilv_new_uri(world, LV2_PORT_PROPS__notOnGUI);
		x11_ui = lilv_new_uri(world, LV2_UI__X11UI);
		instrument_class = lilv_new_uri(world, LV2_CORE__InstrumentPlugin);
		unit = lilv_new_uri(world, LV2_UNITS__unit);
		unit_symbol = lilv_new_uri(world, LV2_UNITS__symbol);
		minimum_size = lilv_new_uri(world, "http://lv2plug.in/ns/ext/resize-port#minimumSize");
		rdfs_label = lilv_new_uri(world, "http://www.w3.org/2000/01/rdf-schema#label");
		connection_optional = lilv_new_uri(world, LV2_CORE__connectionOptional);
	}
};

// --- URIDs ------------------------------------------------------------------------------------

// One map for every plugin in the process, as LV2 expects: a URI is the same number to all of them.
class Urids {
public:
	static Urids &get() {
		static Urids u;
		return u;
	}
	LV2_URID map(const char *uri) {
		std::lock_guard<std::mutex> hold(lock);
		auto it = ids.find(uri);
		if (it != ids.end()) {
			return it->second;
		}
		uris.push_back(uri);
		LV2_URID id = (LV2_URID)uris.size();
		ids[uri] = id;
		return id;
	}
	const char *unmap(LV2_URID id) {
		std::lock_guard<std::mutex> hold(lock);
		return id >= 1 && id <= uris.size() ? uris[id - 1].c_str() : nullptr;
	}
	LV2_URID_Map map_feature{ this, [](LV2_URID_Map_Handle h, const char *uri) { return ((Urids *)h)->map(uri); } };
	LV2_URID_Unmap unmap_feature{ this, [](LV2_URID_Unmap_Handle h, LV2_URID id) { return ((Urids *)h)->unmap(id); } };

private:
	std::mutex lock;
	std::unordered_map<std::string, LV2_URID> ids;
	std::deque<std::string> uris;
};

LV2_URID urid(const char *uri) {
	return Urids::get().map(uri);
}

// --- bytes between threads ---------------------------------------------------------------------

// Messages of any size, one writer and one reader, never blocking either.
class ByteRing {
public:
	explicit ByteRing(size_t size = 1 << 16) : data(size) {}
	bool push(uint32_t port, const void *bytes, uint32_t size) {
		size_t need = 8 + size;
		size_t r = read.load(std::memory_order_acquire), w = write.load(std::memory_order_relaxed);
		size_t used = w - r;
		if (used + need > data.size()) {
			return false;
		}
		put(w, &port, 4);
		put(w + 4, &size, 4);
		put(w + 8, bytes, size);
		write.store(w + need, std::memory_order_release);
		return true;
	}
	// Into `out`, which it grows; false when there is nothing.
	bool pop(uint32_t &port, std::vector<uint8_t> &out) {
		size_t r = read.load(std::memory_order_relaxed), w = write.load(std::memory_order_acquire);
		if (r == w) {
			return false;
		}
		uint32_t size = 0;
		get(r, &port, 4);
		get(r + 4, &size, 4);
		out.resize(size);
		get(r + 8, out.data(), size);
		read.store(r + 8 + size, std::memory_order_release);
		return true;
	}
	// Into a buffer that never grows, for the audio thread; a message too large is dropped.
	bool pop_into(uint32_t &port, uint8_t *out, uint32_t capacity, uint32_t &size) {
		size_t r = read.load(std::memory_order_relaxed), w = write.load(std::memory_order_acquire);
		if (r == w) {
			return false;
		}
		get(r, &port, 4);
		get(r + 4, &size, 4);
		if (size <= capacity) {
			get(r + 8, out, size);
		} else {
			size = 0;
		}
		read.store(r + 8 + (size_t)size_at(r), std::memory_order_release);
		return true;
	}

private:
	uint32_t size_at(size_t r) {
		uint32_t s = 0;
		get(r + 4, &s, 4);
		return s;
	}
	void put(size_t at, const void *src, size_t n) {
		for (size_t i = 0; i < n; i++) data[(at + i) % data.size()] = ((const uint8_t *)src)[i];
	}
	void get(size_t at, void *dst, size_t n) {
		for (size_t i = 0; i < n; i++) ((uint8_t *)dst)[i] = data[(at + i) % data.size()];
	}
	std::vector<uint8_t> data;
	std::atomic<size_t> write{ 0 };
	std::atomic<size_t> read{ 0 };
};

std::string node_string(const LilvNode *n) {
	Lilv &L = Lilv::get();
	return n ? std::string(L.lilv_node_as_string(n)) : std::string();
}

std::string path_of(const LilvNode *uri_node) {
	Lilv &L = Lilv::get();
	if (!uri_node) return "";
	char *p = L.lilv_file_uri_parse(L.lilv_node_as_uri(uri_node), nullptr);
	std::string out = p ? p : "";
	if (p) L.lilv_free(p);
	return out;
}

const LilvUI *x11_ui_of(const LilvPlugin *plugin, LilvUIs *uis) {
	Lilv &L = Lilv::get();
	if (!uis) return nullptr;
	for (LilvIter *i = L.lilv_uis_begin(uis); !L.lilv_uis_is_end(uis, i); i = L.lilv_uis_next(uis, i)) {
		const LilvUI *ui = L.lilv_uis_get(uis, i);
		if (L.lilv_ui_is_a(ui, L.x11_ui)) {
			return ui;
		}
	}
	(void)plugin;
	return nullptr;
}

PluginInfo info_of(const LilvPlugin *p) {
	Lilv &L = Lilv::get();
	PluginInfo info;
	info.format = "LV2";
	info.id = L.lilv_node_as_uri(L.lilv_plugin_get_uri(p));
	LilvNode *name = L.lilv_plugin_get_name(p);
	info.name = node_string(name);
	if (name) L.lilv_node_free(name);
	LilvNode *author = L.lilv_plugin_get_author_name(p);
	info.vendor = node_string(author);
	if (author) L.lilv_node_free(author);
	info.path = path_of(L.lilv_plugin_get_bundle_uri(p));
	const LilvPluginClass *cls = L.lilv_plugin_get_class(p);
	if (cls) {
		info.category = node_string(L.lilv_plugin_class_get_label(cls));
		info.instrument = L.lilv_node_equals(L.lilv_plugin_class_get_uri(cls), L.instrument_class);
	}
	LilvUIs *uis = L.lilv_plugin_get_uis(p);
	info.has_editor = x11_ui_of(p, uis) != nullptr;
	if (uis) L.lilv_uis_free(uis);
	return info;
}

// --- the plugin -------------------------------------------------------------------------------

class Lv2Plugin final : public HostedPlugin {
public:
	Lv2Plugin(const LilvPlugin *p) : plugin(p) {}

	~Lv2Plugin() override {
		editor_close();
		deactivate();
		stop_worker();
		if (instance) Lilv::get().lilv_instance_free(instance);
	}

	bool load(std::string &why) {
		description = info_of(plugin);
		if (!check_features(why)) {
			return false;
		}
		read_ports();
		if (!instantiate(48000.0, why)) {
			return false;
		}
		return true;
	}

	// --- the main thread ----------------------------------------------------------------------

	bool activate(double r, int max) override {
		if (active.load()) {
			return true;
		}
		if (r != rate || max > max_block) {
			// The rate is the instance's for good: a new one, with the old one's state.
			std::vector<uint8_t> kept;
			bool had = get_state(kept);
			max_block = std::max(max, max_block);
			std::string why;
			if (!instantiate(r, why)) {
				problem = why;
				return false;
			}
			if (had) set_state(kept);
		}
		alloc_buffers();
		connect();
		lilv_instance_activate(instance);
		active.store(true);
		return true;
	}

	void deactivate() override {
		if (!active.load()) return;
		block_audio();
		active.store(false);
		lilv_instance_deactivate(instance);
		unblock_audio();
	}

	void set_normalized(int i, double value) override {
		if (i < 0 || i >= param_count()) return;
		value = std::clamp(value, 0.0, 1.0);
		store_value(i, value, false);
		queue_to_audio(i, value);
	}

	std::string param_text(int i, double value) override {
		if (i < 0 || i >= param_count()) return "";
		const Control &c = controls[i];
		double plain = to_plain(i, value);
		for (const auto &sp : c.points) {
			if (std::fabs(sp.first - plain) < 1e-4) return sp.second;
		}
		if (c.toggled) return plain >= 0.5 ? "On" : "Off";
		char buf[64];
		if (params[i].steps > 0) {
			std::snprintf(buf, sizeof buf, "%d", (int)std::lround(plain));
		} else {
			double a = std::fabs(plain);
			std::snprintf(buf, sizeof buf, a >= 100 ? "%.0f" : a >= 10 ? "%.1f" : "%.2f", plain);
		}
		std::string out = buf;
		if (!params[i].unit.empty()) out += " " + params[i].unit;
		return out;
	}

	bool get_state(std::vector<uint8_t> &out) override {
		Lilv &L = Lilv::get();
		if (!instance) return false;
		block_audio();
		LilvState *s = L.lilv_state_new_from_instance(plugin, instance, &Urids::get().map_feature, nullptr, nullptr,
				nullptr, nullptr, &Lv2Plugin::port_value_for_state, this, LV2_STATE_IS_POD | LV2_STATE_IS_PORTABLE,
				features.data());
		unblock_audio();
		if (!s) return false;
		char *text = L.lilv_state_to_string(L.world, &Urids::get().map_feature, &Urids::get().unmap_feature, s,
				"urn:dawkit:state", nullptr);
		L.lilv_state_free(s);
		if (!text) return false;
		out.assign(text, text + std::strlen(text));
		L.lilv_free(text);
		return true;
	}

	bool set_state(const std::vector<uint8_t> &in) override {
		Lilv &L = Lilv::get();
		if (!instance) return false;
		std::string text((const char *)in.data(), in.size());
		LilvState *s = L.lilv_state_new_from_string(L.world, &Urids::get().map_feature, text.c_str());
		if (!s) {
			problem = "not an LV2 state";
			return false;
		}
		block_audio();
		synchronous_work = true;
		L.lilv_state_restore(s, instance, &Lv2Plugin::port_value_from_state, this, 0, features.data());
		synchronous_work = false;
		unblock_audio();
		L.lilv_state_free(s);
		return true;
	}

	int latency() const override { return latency_samples.load(); }

	void main_thread() override {
		// What the plugin said, to its window: its output ports and any messages.
		uint32_t port = 0;
		while (to_ui.pop(port, message)) {
			if (ui_handle && ui_desc && ui_desc->port_event) {
				ui_desc->port_event(ui_handle, port, (uint32_t)message.size(), urid(LV2_ATOM__eventTransfer),
						message.data());
			}
		}
		if (ui_handle && ui_desc && ui_desc->port_event) {
			for (size_t i = 0; i < ports.size(); i++) {
				Port &p = ports[i];
				if (p.kind != Port::CONTROL) continue;
				float v = p.is_input ? (float)to_plain(p.param, get_normalized(p.param)) : out_values[i].load();
				if (v != p.ui_value) {
					p.ui_value = v;
					ui_desc->port_event(ui_handle, (uint32_t)i, sizeof(float), 0, &v);
				}
			}
			if (ui_idle && ui_idle->idle(ui_handle) != 0) {
				editor_close();
			}
		}
	}

	bool editor_supported() override { return description.has_editor; }

	bool editor_open(unsigned long parent, int &width, int &height) override {
		Lilv &L = Lilv::get();
		editor_close();
		LilvUIs *uis = L.lilv_plugin_get_uis(plugin);
		const LilvUI *ui = x11_ui_of(plugin, uis);
		if (!ui) {
			if (uis) L.lilv_uis_free(uis);
			problem = description.name + " has no window this host can show";
			return false;
		}
		std::string binary = path_of(L.lilv_ui_get_binary_uri(ui));
		std::string bundle = path_of(L.lilv_ui_get_bundle_uri(ui));
		std::string ui_uri = L.lilv_node_as_uri(L.lilv_ui_get_uri(ui));
		L.lilv_uis_free(uis);
		if (!bundle.empty() && bundle.back() != '/') bundle += '/';
		if (!ui_lib.open(binary, problem)) {
			return false;
		}
		const LV2UI_Descriptor *(*entry)(uint32_t) = nullptr;
		if (!ui_lib.get("lv2ui_descriptor", entry)) {
			problem = binary + " has no lv2ui_descriptor";
			return false;
		}
		for (uint32_t i = 0;; i++) {
			const LV2UI_Descriptor *d = entry(i);
			if (!d) break;
			if (ui_uri == d->URI) {
				ui_desc = d;
				break;
			}
		}
		if (!ui_desc) {
			problem = binary + " has no " + ui_uri;
			return false;
		}
		resize.handle = this;
		resize.ui_resize = [](LV2UI_Feature_Handle h, int w, int hgt) {
			((Lv2Plugin *)h)->request_editor_size(w, hgt);
			((Lv2Plugin *)h)->ui_w = w;
			((Lv2Plugin *)h)->ui_h = hgt;
			return 0;
		};
		port_map.handle = this;
		port_map.port_index = [](LV2UI_Feature_Handle h, const char *symbol) {
			Lv2Plugin *self = (Lv2Plugin *)h;
			for (size_t i = 0; i < self->ports.size(); i++) {
				if (self->ports[i].symbol == symbol) return (uint32_t)i;
			}
			return (uint32_t)LV2UI_INVALID_PORT_INDEX;
		};
		data_access.data_access = lilv_instance_get_descriptor(instance)->extension_data;
		ui_features_storage = {
			{ LV2_URID__map, &Urids::get().map_feature },
			{ LV2_URID__unmap, &Urids::get().unmap_feature },
			{ LV2_UI__parent, (void *)(uintptr_t)parent },
			{ LV2_UI__resize, &resize },
			{ LV2_UI__portMap, &port_map },
			{ LV2_INSTANCE_ACCESS_URI, lilv_instance_get_handle(instance) },
			{ LV2_DATA_ACCESS_URI, &data_access },
			{ LV2_OPTIONS__options, options.data() },
			{ LV2_LOG__log, &log },
		};
		ui_features.clear();
		for (LV2_Feature &f : ui_features_storage) ui_features.push_back(&f);
		ui_features.push_back(nullptr);
		ui_w = ui_h = 0;
		LV2UI_Widget widget = nullptr;
		ui_handle = ui_desc->instantiate(ui_desc, description.id.c_str(), bundle.c_str(), &Lv2Plugin::ui_write, this,
				&widget, ui_features.data());
		if (!ui_handle) {
			problem = description.name + "'s window would not open";
			ui_desc = nullptr;
			return false;
		}
		ui_idle = ui_desc->extension_data ? (const LV2UI_Idle_Interface *)ui_desc->extension_data(LV2_UI__idleInterface)
										   : nullptr;
		width = ui_w;
		height = ui_h;
		for (Port &p : ports) p.ui_value = NAN; // all sent on the next frame
		return true;
	}

	void editor_close() override {
		if (ui_handle && ui_desc && ui_desc->cleanup) {
			ui_desc->cleanup(ui_handle);
		}
		ui_handle = nullptr;
		ui_desc = nullptr;
		ui_idle = nullptr;
		// The library stays: a toolkit it loaded may have left callbacks behind.
		ui_lib.leak();
	}

	// --- the audio thread ---------------------------------------------------------------------

	void process(const float *const *in, float *const *out, int frames, const Event *events, int event_count,
			const Transport &t) override {
		in_run.store(true);
		if (blocked.load() || !active.load() || frames > max_block) {
			in_run.store(false);
			for (int c = 0; c < outputs; c++) std::memset(out[c], 0, sizeof(float) * frames);
			return;
		}
		ParamChange pc;
		while (to_audio.pop(pc)) {
			if (pc.index >= 0 && pc.index < param_count()) {
				control_values[controls[pc.index].port] = (float)to_plain(pc.index, pc.value);
			}
		}
		// Audio: the host's where the plugin has a channel for it, silence or a sink otherwise.
		int ai = 0, ao = 0;
		for (size_t i = 0; i < ports.size(); i++) {
			Port &p = ports[i];
			if (p.kind == Port::AUDIO) {
				float *buf;
				if (p.is_input) {
					if (ai < inputs && in) {
						buf = const_cast<float *>(in[ai]);
					} else {
						std::memset(p.scratch.data(), 0, sizeof(float) * frames);
						buf = p.scratch.data();
					}
					ai++;
				} else {
					buf = ao < outputs ? out[ao] : p.scratch.data();
					ao++;
				}
				lilv_instance_connect_port(instance, (uint32_t)i, buf);
			} else if (p.kind == Port::ATOM) {
				fill_atoms(i, p, events, event_count, t, frames);
			}
		}
		lilv_instance_run(instance, (uint32_t)frames);
		// The worker's answers, then the end of the run, as the worker extension asks.
		if (worker_iface) {
			uint32_t port = 0, size = 0;
			while (responses.pop_into(port, response_buf.data(), (uint32_t)response_buf.size(), size)) {
				if (size > 0) worker_iface->work_response(lilv_instance_get_handle(instance), size, response_buf.data());
			}
			if (worker_iface->end_run) worker_iface->end_run(lilv_instance_get_handle(instance));
		}
		for (size_t i = 0; i < ports.size(); i++) {
			Port &p = ports[i];
			if (p.kind == Port::CONTROL && !p.is_input) {
				out_values[i].store(control_values[i]);
			} else if (p.kind == Port::ATOM && !p.is_input) {
				LV2_Atom_Sequence *seq = (LV2_Atom_Sequence *)p.atoms.data();
				LV2_ATOM_SEQUENCE_FOREACH(seq, ev) {
					to_ui.push((uint32_t)i, &ev->body, sizeof(LV2_Atom) + ev->body.size);
				}
			}
		}
		if (latency_port >= 0) {
			latency_samples.store((int)std::max(0.0f, control_values[latency_port]));
		}
		in_run.store(false);
	}

private:
	struct Port {
		enum Kind { AUDIO, CONTROL, ATOM, CV, OTHER } kind = OTHER;
		bool is_input = true;
		bool midi = false;
		bool time = false;
		bool optional = false;
		std::string symbol;
		int param = -1;
		size_t atom_size = 65536;
		std::vector<float> scratch;
		std::vector<uint8_t> atoms;
		float ui_value = NAN;
	};
	struct Control {
		uint32_t port = 0;
		bool toggled = false;
		bool integer = false;
		std::vector<std::pair<float, std::string>> points;
	};

	bool check_features(std::string &why) {
		Lilv &L = Lilv::get();
		static const char *ours[] = { LV2_URID__map, LV2_URID__unmap, LV2_OPTIONS__options,
			LV2_BUF_SIZE__boundedBlockLength, LV2_WORKER__schedule, LV2_LOG__log, LV2_STATE__loadDefaultState,
			LV2_CORE__isLive, LV2_CORE__hardRTCapable, LV2_CORE__inPlaceBroken,
			"http://lv2plug.in/ns/lv2core#inPlaceBroken", LV2_STATE__threadSafeRestore };
		LilvNodes *req = L.lilv_plugin_get_required_features(plugin);
		bool fine = true;
		if (req) {
			for (LilvIter *i = L.lilv_nodes_begin(req); !L.lilv_nodes_is_end(req, i); i = L.lilv_nodes_next(req, i)) {
				std::string f = L.lilv_node_as_uri(L.lilv_nodes_get(req, i));
				bool have = false;
				for (const char *o : ours) have = have || f == o;
				if (!have) {
					why = description.name + " needs " + f + ", which this host does not give";
					fine = false;
				}
			}
			L.lilv_nodes_free(req);
		}
		return fine;
	}

	void read_ports() {
		Lilv &L = Lilv::get();
		uint32_t n = L.lilv_plugin_get_num_ports(plugin);
		ports.assign(n, Port());
		control_values.assign(n, 0.0f);
		out_values.reset(new std::atomic<float>[n + 1]);
		for (uint32_t i = 0; i <= n; i++) out_values[i].store(0.0f);
		std::vector<ParamInfo> list;
		controls.clear();
		int audio_in = 0, audio_out = 0;
		latency_port = L.lilv_plugin_has_latency(plugin) ? (int)L.lilv_plugin_get_latency_port_index(plugin) : -1;
		for (uint32_t i = 0; i < n; i++) {
			const LilvPort *lp = L.lilv_plugin_get_port_by_index(plugin, i);
			Port &p = ports[i];
			p.symbol = node_string(L.lilv_port_get_symbol(plugin, lp));
			p.is_input = L.lilv_port_is_a(plugin, lp, L.input_port);
			p.optional = L.lilv_port_has_property(plugin, lp, L.connection_optional);
			if (L.lilv_port_is_a(plugin, lp, L.audio_port)) {
				p.kind = Port::AUDIO;
				(p.is_input ? audio_in : audio_out)++;
			} else if (L.lilv_port_is_a(plugin, lp, L.cv_port)) {
				p.kind = Port::CV;
			} else if (L.lilv_port_is_a(plugin, lp, L.atom_port)) {
				p.kind = Port::ATOM;
				p.midi = L.lilv_port_supports_event(plugin, lp, L.midi_event);
				p.time = L.lilv_port_supports_event(plugin, lp, L.time_position);
				if (LilvNode *sz = L.lilv_port_get(plugin, lp, L.minimum_size)) {
					if (L.lilv_node_is_int(sz)) p.atom_size = std::max(p.atom_size, (size_t)L.lilv_node_as_int(sz));
					L.lilv_node_free(sz);
				}
				if (p.is_input && p.midi) event_inputs++;
			} else if (L.lilv_port_is_a(plugin, lp, L.control_port)) {
				p.kind = Port::CONTROL;
				LilvNode *def = nullptr, *mn = nullptr, *mx = nullptr;
				L.lilv_port_get_range(plugin, lp, &def, &mn, &mx);
				float fmin = mn ? L.lilv_node_as_float(mn) : 0.0f;
				float fmax = mx ? L.lilv_node_as_float(mx) : 1.0f;
				float fdef = def ? L.lilv_node_as_float(def) : fmin;
				if (def) L.lilv_node_free(def);
				if (mn) L.lilv_node_free(mn);
				if (mx) L.lilv_node_free(mx);
				if (L.lilv_port_has_property(plugin, lp, L.sample_rate)) {
					fmin *= 48000.0f;
					fmax *= 48000.0f;
					fdef *= 48000.0f;
				}
				if (fmax <= fmin) fmax = fmin + 1.0f;
				control_values[i] = fdef;
				if (!p.is_input || (int)i == latency_port) continue;
				Control c;
				c.port = i;
				c.toggled = L.lilv_port_has_property(plugin, lp, L.toggled);
				c.integer = c.toggled || L.lilv_port_has_property(plugin, lp, L.integer) ||
						L.lilv_port_has_property(plugin, lp, L.enumeration);
				LilvScalePoints *sps = L.lilv_port_get_scale_points(plugin, lp);
				if (sps) {
					for (LilvIter *it = L.lilv_scale_points_begin(sps); !L.lilv_scale_points_is_end(sps, it);
							it = L.lilv_scale_points_next(sps, it)) {
						const LilvScalePoint *sp = L.lilv_scale_points_get(sps, it);
						c.points.push_back({ L.lilv_node_as_float(L.lilv_scale_point_get_value(sp)),
								node_string(L.lilv_scale_point_get_label(sp)) });
					}
					L.lilv_scale_points_free(sps);
				}
				ParamInfo pi;
				LilvNode *name = L.lilv_port_get_name(plugin, lp);
				pi.name = node_string(name);
				if (name) L.lilv_node_free(name);
				pi.min = fmin;
				pi.max = fmax;
				pi.steps = c.toggled ? 1 : c.integer ? std::max(1, (int)std::lround(fmax - fmin)) : 0;
				pi.logarithmic = L.lilv_port_has_property(plugin, lp, L.logarithmic) && fmin > 0.0f;
				pi.hidden = L.lilv_port_has_property(plugin, lp, L.not_on_gui);
				pi.format_id = i;
				pi.unit = unit_of(lp);
				p.param = (int)list.size();
				list.push_back(pi);
				controls.push_back(c);
			}
		}
		inputs = std::min(audio_in, 2);
		outputs = std::min(audio_out, 2);
		description.instrument = description.instrument || (audio_in == 0 && event_inputs > 0);
		set_params(std::move(list));
		for (int i = 0; i < param_count(); i++) {
			double nv = to_normal(i, control_values[controls[i].port]);
			params[i].def = nv;
			store_value(i, nv, false);
		}
	}

	std::string unit_of(const LilvPort *lp) {
		Lilv &L = Lilv::get();
		LilvNode *u = L.lilv_port_get(plugin, lp, L.unit);
		std::string out;
		if (!u) return out;
		if (L.lilv_node_is_uri(u)) {
			LilvNode *sym = L.lilv_world_get(L.world, u, L.unit_symbol, nullptr);
			if (sym) {
				out = node_string(sym);
				L.lilv_node_free(sym);
			} else {
				std::string uri = L.lilv_node_as_uri(u);
				std::string tail = uri.substr(uri.find('#') + 1);
				static const std::pair<const char *, const char *> known[] = { { "db", "dB" }, { "hz", "Hz" },
					{ "khz", "kHz" }, { "ms", "ms" }, { "s", "s" }, { "pc", "%" }, { "bpm", "BPM" },
					{ "semitone12TET", "st" }, { "cent", "ct" }, { "degree", "°" } };
				for (auto &k : known) {
					if (tail == k.first) out = k.second;
				}
			}
		}
		L.lilv_node_free(u);
		return out;
	}

	double to_plain(int i, double norm) const {
		const ParamInfo &p = params[i];
		double v;
		if (p.logarithmic) {
			v = p.min * std::pow(p.max / p.min, norm);
		} else {
			v = p.min + norm * (p.max - p.min);
		}
		if (p.steps > 0) v = std::round(v);
		return std::clamp(v, p.min, p.max);
	}

	double to_normal(int i, double plain) const {
		const ParamInfo &p = params[i];
		plain = std::clamp(plain, p.min, p.max);
		if (p.logarithmic) return std::log(plain / p.min) / std::log(p.max / p.min);
		return (plain - p.min) / (p.max - p.min);
	}

	bool instantiate(double r, std::string &why) {
		Lilv &L = Lilv::get();
		stop_worker();
		if (instance) {
			L.lilv_instance_free(instance);
			instance = nullptr;
		}
		rate = r;
		rate_f = (float)r;
		min_len = 1;
		max_len = max_block;
		nominal_len = std::min(max_block, 512);
		seq_size = 65536;
		options = {
			{ LV2_OPTIONS_INSTANCE, 0, urid(LV2_BUF_SIZE__minBlockLength), sizeof(int32_t), urid(LV2_ATOM__Int), &min_len },
			{ LV2_OPTIONS_INSTANCE, 0, urid(LV2_BUF_SIZE__maxBlockLength), sizeof(int32_t), urid(LV2_ATOM__Int), &max_len },
			{ LV2_OPTIONS_INSTANCE, 0, urid(LV2_BUF_SIZE__nominalBlockLength), sizeof(int32_t), urid(LV2_ATOM__Int),
					&nominal_len },
			{ LV2_OPTIONS_INSTANCE, 0, urid(LV2_BUF_SIZE__sequenceSize), sizeof(int32_t), urid(LV2_ATOM__Int), &seq_size },
			{ LV2_OPTIONS_INSTANCE, 0, urid(LV2_PARAMETERS__sampleRate), sizeof(float), urid(LV2_ATOM__Float), &rate_f },
			{ LV2_OPTIONS_INSTANCE, 0, 0, 0, 0, nullptr },
		};
		schedule.handle = this;
		schedule.schedule_work = &Lv2Plugin::schedule_work;
		log.handle = this;
		log.printf = &Lv2Plugin::log_printf;
		log.vprintf = [](LV2_Log_Handle h, LV2_URID type, const char *fmt, va_list a) {
			return ((Lv2Plugin *)h)->log_line(type, fmt, a);
		};
		features_storage = {
			{ LV2_URID__map, &Urids::get().map_feature },
			{ LV2_URID__unmap, &Urids::get().unmap_feature },
			{ LV2_OPTIONS__options, options.data() },
			{ LV2_BUF_SIZE__boundedBlockLength, nullptr },
			{ LV2_WORKER__schedule, &schedule },
			{ LV2_LOG__log, &log },
			{ LV2_STATE__loadDefaultState, nullptr },
		};
		features.clear();
		for (LV2_Feature &f : features_storage) features.push_back(&f);
		features.push_back(nullptr);
		synchronous_work = true; // anything it schedules while it starts is done there and then
		instance = L.lilv_plugin_instantiate(plugin, r, features.data());
		synchronous_work = false;
		if (!instance) {
			why = description.name + " would not start";
			return false;
		}
		const LV2_Descriptor *d = lilv_instance_get_descriptor(instance);
		worker_iface = d->extension_data ? (const LV2_Worker_Interface *)d->extension_data(LV2_WORKER__interface) : nullptr;
		if (worker_iface) start_worker();
		alloc_buffers();
		connect();
		return true;
	}

	void alloc_buffers() {
		for (Port &p : ports) {
			if (p.kind == Port::AUDIO || p.kind == Port::CV) {
				p.scratch.assign((size_t)max_block, 0.0f);
			} else if (p.kind == Port::ATOM) {
				p.atoms.assign(p.atom_size, 0);
			}
		}
		response_buf.assign(65536, 0);
		ui_event.assign(65536, 0);
	}

	// Everything but audio stays where it is, so it is connected once.
	void connect() {
		for (size_t i = 0; i < ports.size(); i++) {
			Port &p = ports[i];
			void *where = nullptr;
			switch (p.kind) {
				case Port::CONTROL: where = &control_values[i]; break;
				case Port::AUDIO:
				case Port::CV: where = p.scratch.data(); break;
				case Port::ATOM: where = p.atoms.data(); break;
				default: break;
			}
			lilv_instance_connect_port(instance, (uint32_t)i, where);
		}
	}

	void fill_atoms(size_t index, Port &p, const Event *events, int event_count, const Transport &t, int frames) {
		LV2_Atom_Forge &f = forge;
		lv2_atom_forge_init(&f, &Urids::get().map_feature);
		lv2_atom_forge_set_buffer(&f, p.atoms.data(), p.atoms.size());
		if (!p.is_input) {
			// An empty sequence the size of the buffer, for the plugin to write into.
			LV2_Atom_Sequence *seq = (LV2_Atom_Sequence *)p.atoms.data();
			seq->atom.size = (uint32_t)(p.atoms.size() - sizeof(LV2_Atom));
			seq->atom.type = urid(LV2_ATOM__Chunk);
			return;
		}
		LV2_Atom_Forge_Frame frame;
		lv2_atom_forge_sequence_head(&f, &frame, 0);
		// From the window first, then the song's place, then the notes, so the times only go up.
		uint32_t port = 0, size = 0;
		while (index == first_atom_in && from_ui.pop_into(port, ui_event.data(), (uint32_t)ui_event.size(), size)) {
			if (size >= sizeof(LV2_Atom) && port < ports.size()) {
				// Every message for an atom input goes to the first one: almost every plugin has one.
				lv2_atom_forge_frame_time(&f, 0);
				lv2_atom_forge_write(&f, ui_event.data(), size);
			}
		}
		if (p.time) {
			bool jumped = t.playing != was_playing || t.tempo != was_tempo ||
					std::llabs((long long)std::llround(t.seconds * rate) - expected_frame) > 1;
			if (jumped) {
				LV2_Atom_Forge_Frame obj;
				lv2_atom_forge_frame_time(&f, 0);
				lv2_atom_forge_object(&f, &obj, 0, urid(LV2_TIME__Position));
				lv2_atom_forge_key(&f, urid(LV2_TIME__frame));
				lv2_atom_forge_long(&f, (int64_t)std::llround(t.seconds * rate));
				lv2_atom_forge_key(&f, urid(LV2_TIME__speed));
				lv2_atom_forge_float(&f, t.playing ? 1.0f : 0.0f);
				double beats_per_bar = t.numerator * (4.0 / std::max(1, t.denominator));
				double in_bar = t.beats - t.bar_start;
				lv2_atom_forge_key(&f, urid(LV2_TIME__bar));
				lv2_atom_forge_long(&f, (int64_t)std::floor(t.bar_start / std::max(beats_per_bar, 1e-9)));
				lv2_atom_forge_key(&f, urid(LV2_TIME__barBeat));
				lv2_atom_forge_float(&f, (float)(in_bar * t.denominator / 4.0));
				lv2_atom_forge_key(&f, urid(LV2_TIME__beatUnit));
				lv2_atom_forge_int(&f, t.denominator);
				lv2_atom_forge_key(&f, urid(LV2_TIME__beatsPerBar));
				lv2_atom_forge_float(&f, (float)t.numerator);
				lv2_atom_forge_key(&f, urid(LV2_TIME__beatsPerMinute));
				lv2_atom_forge_float(&f, (float)(t.tempo * t.denominator / 4.0));
				lv2_atom_forge_pop(&f, &obj);
			}
			was_playing = t.playing;
			was_tempo = t.tempo;
			expected_frame = (long long)std::llround(t.seconds * rate) + (t.playing ? frames : 0);
		}
		if (p.midi && index == first_midi_in) {
			for (int e = 0; e < event_count; e++) {
				const Event &ev = events[e];
				uint8_t msg[3];
				uint32_t len = 3;
				uint8_t ch = ev.channel & 15;
				switch (ev.kind) {
					case Event::NOTE_ON:
						msg[0] = 0x90 | ch;
						msg[1] = ev.key & 127;
						msg[2] = (uint8_t)std::clamp((int)std::lround(ev.value * 127.0), 1, 127);
						break;
					case Event::NOTE_OFF:
						msg[0] = 0x80 | ch;
						msg[1] = ev.key & 127;
						msg[2] = (uint8_t)std::clamp((int)std::lround(ev.value * 127.0), 0, 127);
						break;
					case Event::CONTROL:
						msg[0] = 0xB0 | ch;
						msg[1] = ev.key & 127;
						msg[2] = (uint8_t)std::clamp((int)std::lround(ev.value * 127.0), 0, 127);
						break;
					case Event::PITCH_BEND: {
						int v = std::clamp((int)std::lround((ev.value + 1.0) * 8192.0), 0, 16383);
						msg[0] = 0xE0 | ch;
						msg[1] = v & 127;
						msg[2] = (v >> 7) & 127;
						break;
					}
					case Event::ALL_NOTES_OFF:
						msg[0] = 0xB0 | ch;
						msg[1] = 123;
						msg[2] = 0;
						break;
				}
				lv2_atom_forge_frame_time(&f, std::clamp(ev.offset, 0, std::max(frames - 1, 0)));
				lv2_atom_forge_atom(&f, len, urid(LV2_MIDI__MidiEvent));
				lv2_atom_forge_write(&f, msg, len);
			}
		}
		lv2_atom_forge_pop(&f, &frame);
	}

	// The plugin's window set a port: a control's value, or a message for an atom port.
	static void ui_write(LV2UI_Controller c, uint32_t port, uint32_t size, uint32_t protocol, const void *buffer) {
		Lv2Plugin *self = (Lv2Plugin *)c;
		if (port >= self->ports.size()) return;
		Port &p = self->ports[port];
		if (protocol == 0 && size == sizeof(float) && p.kind == Port::CONTROL && p.is_input && p.param >= 0) {
			float v = *(const float *)buffer;
			double n = self->to_normal(p.param, v);
			p.ui_value = v; // it knows already
			self->store_value(p.param, n, true);
			self->queue_to_audio(p.param, n);
		} else if (protocol == urid(LV2_ATOM__eventTransfer) && p.kind == Port::ATOM) {
			self->from_ui.push(port, buffer, size);
		}
	}

	static const void *port_value_for_state(const char *symbol, void *data, uint32_t *size, uint32_t *type) {
		Lv2Plugin *self = (Lv2Plugin *)data;
		for (size_t i = 0; i < self->ports.size(); i++) {
			Port &p = self->ports[i];
			if (p.kind == Port::CONTROL && p.is_input && p.symbol == symbol && p.param >= 0) {
				self->state_value = (float)self->to_plain(p.param, self->get_normalized(p.param));
				*size = sizeof(float);
				*type = urid(LV2_ATOM__Float);
				return &self->state_value;
			}
		}
		*size = 0;
		*type = 0;
		return nullptr;
	}

	static void port_value_from_state(const char *symbol, void *data, const void *value, uint32_t size, uint32_t type) {
		Lv2Plugin *self = (Lv2Plugin *)data;
		float v;
		if (type == urid(LV2_ATOM__Float) && size == sizeof(float)) v = *(const float *)value;
		else if (type == urid(LV2_ATOM__Double) && size == sizeof(double)) v = (float)*(const double *)value;
		else if (type == urid(LV2_ATOM__Int) && size == sizeof(int32_t)) v = (float)*(const int32_t *)value;
		else return;
		for (size_t i = 0; i < self->ports.size(); i++) {
			Port &p = self->ports[i];
			if (p.symbol == symbol && p.kind == Port::CONTROL && p.is_input && p.param >= 0) {
				self->control_values[i] = v; // the audio thread is held off while state is restored
				self->store_value(p.param, self->to_normal(p.param, v), true);
			}
		}
	}

	// --- the worker ---------------------------------------------------------------------------

	static LV2_Worker_Status schedule_work(LV2_Worker_Schedule_Handle h, uint32_t size, const void *data) {
		Lv2Plugin *self = (Lv2Plugin *)h;
		if (!self->worker_iface) return LV2_WORKER_ERR_UNKNOWN;
		if (self->synchronous_work || !self->worker_running) {
			self->worker_iface->work(lilv_instance_get_handle(self->instance), &Lv2Plugin::respond_now, self, size, data);
			return LV2_WORKER_SUCCESS;
		}
		if (!self->requests.push(0, data, size)) return LV2_WORKER_ERR_NO_SPACE;
		self->work_waiting.store(true);
		self->work_ready.notify_one();
		return LV2_WORKER_SUCCESS;
	}

	static LV2_Worker_Status respond(LV2_Worker_Respond_Handle h, uint32_t size, const void *data) {
		Lv2Plugin *self = (Lv2Plugin *)h;
		return self->responses.push(0, data, size) ? LV2_WORKER_SUCCESS : LV2_WORKER_ERR_NO_SPACE;
	}

	static LV2_Worker_Status respond_now(LV2_Worker_Respond_Handle h, uint32_t size, const void *data) {
		Lv2Plugin *self = (Lv2Plugin *)h;
		self->worker_iface->work_response(lilv_instance_get_handle(self->instance), size, data);
		return LV2_WORKER_SUCCESS;
	}

	void start_worker() {
		worker_running = true;
		worker = std::thread([this]() {
			std::vector<uint8_t> job;
			uint32_t port = 0;
			while (true) {
				{
					std::unique_lock<std::mutex> hold(work_lock);
					work_ready.wait_for(hold, std::chrono::milliseconds(50),
							[this]() { return work_waiting.load() || !worker_running.load(); });
				}
				if (!worker_running.load()) break;
				work_waiting.store(false);
				while (requests.pop(port, job)) {
					worker_iface->work(lilv_instance_get_handle(instance), &Lv2Plugin::respond, this,
							(uint32_t)job.size(), job.data());
				}
			}
		});
	}

	void stop_worker() {
		if (!worker.joinable()) {
			worker_running = false;
			return;
		}
		worker_running = false;
		work_ready.notify_one();
		worker.join();
	}

	static int log_printf(LV2_Log_Handle h, LV2_URID type, const char *fmt, ...) {
		va_list a;
		va_start(a, fmt);
		int r = ((Lv2Plugin *)h)->log_line(type, fmt, a);
		va_end(a);
		return r;
	}

	int log_line(LV2_URID type, const char *fmt, va_list a) {
		if (type == urid(LV2_LOG__Trace)) return 0;
		char buf[1024];
		int n = std::vsnprintf(buf, sizeof buf, fmt, a);
		std::fprintf(stderr, "[%s] %s", description.name.c_str(), buf);
		return n;
	}

	// The audio thread kept out while the plugin is in its instantiation class (state, deactivate).
	void block_audio() {
		blocked.store(true);
		while (in_run.load()) std::this_thread::yield();
	}
	void unblock_audio() { blocked.store(false); }

	const LilvPlugin *plugin;
	LilvInstance *instance = nullptr;
	std::vector<Port> ports;
	std::vector<Control> controls;
	std::vector<float> control_values;
	std::unique_ptr<std::atomic<float>[]> out_values;
	int latency_port = -1;
	std::atomic<int> latency_samples{ 0 };
	int event_inputs = 0;
	size_t first_atom_in = SIZE_MAX;
	size_t first_midi_in = SIZE_MAX;

	double rate = 0.0;
	float rate_f = 48000.0f;
	int max_block = 4096;
	int32_t min_len = 1, max_len = 4096, nominal_len = 512, seq_size = 65536;
	std::vector<LV2_Options_Option> options;
	LV2_Worker_Schedule schedule{};
	LV2_Log_Log log{};
	std::vector<LV2_Feature> features_storage;
	std::vector<const LV2_Feature *> features;
	LV2_Atom_Forge forge{};

	const LV2_Worker_Interface *worker_iface = nullptr;
	std::thread worker;
	std::atomic<bool> worker_running{ false };
	std::atomic<bool> work_waiting{ false };
	std::mutex work_lock;
	std::condition_variable work_ready;
	ByteRing requests, responses;
	std::vector<uint8_t> response_buf;
	bool synchronous_work = false;

	std::atomic<bool> in_run{ false };
	std::atomic<bool> blocked{ false };
	bool was_playing = false;
	double was_tempo = 0.0;
	long long expected_frame = -1000000;
	float state_value = 0.0f;

	// The window.
	Library ui_lib;
	const LV2UI_Descriptor *ui_desc = nullptr;
	LV2UI_Handle ui_handle = nullptr;
	const LV2UI_Idle_Interface *ui_idle = nullptr;
	LV2UI_Resize resize{};
	LV2UI_Port_Map port_map{};
	LV2_Extension_Data_Feature data_access{};
	std::vector<LV2_Feature> ui_features_storage;
	std::vector<const LV2_Feature *> ui_features;
	int ui_w = 0, ui_h = 0;
	ByteRing to_ui{ 1 << 18 }, from_ui;
	std::vector<uint8_t> message, ui_event;

public:
	void find_event_ports() {
		for (size_t i = 0; i < ports.size(); i++) {
			if (ports[i].kind == Port::ATOM && ports[i].is_input) {
				if (first_atom_in == SIZE_MAX) first_atom_in = i;
				if (ports[i].midi && first_midi_in == SIZE_MAX) first_midi_in = i;
			}
		}
	}
};

} // namespace

std::vector<PluginInfo> scan_lv2(std::string &problem) {
	std::vector<PluginInfo> out;
	Lilv &L = Lilv::get();
	if (!L.ok()) {
		problem = L.missing;
		return out;
	}
	const LilvPlugins *all = L.lilv_world_get_all_plugins(L.world);
	for (LilvIter *i = L.lilv_plugins_begin(all); !L.lilv_plugins_is_end(all, i); i = L.lilv_plugins_next(all, i)) {
		out.push_back(info_of(L.lilv_plugins_get(all, i)));
	}
	return out;
}

std::unique_ptr<HostedPlugin> load_lv2(const std::string &uri, std::string &problem) {
	Lilv &L = Lilv::get();
	if (!L.ok()) {
		problem = L.missing;
		return nullptr;
	}
	LilvNode *node = L.lilv_new_uri(L.world, uri.c_str());
	const LilvPlugin *p = L.lilv_plugins_get_by_uri(L.lilv_world_get_all_plugins(L.world), node);
	L.lilv_node_free(node);
	if (!p) {
		problem = "no LV2 plugin " + uri;
		return nullptr;
	}
	auto plugin = std::make_unique<Lv2Plugin>(p);
	if (!plugin->load(problem)) {
		return nullptr;
	}
	plugin->find_event_ports();
	return plugin;
}

} // namespace dawkit
