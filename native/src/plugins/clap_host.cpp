// CLAP plugins: https://github.com/free-audio/clap (MIT), headers in native/third_party/clap.

#include "hosted_plugin.h"
#include "library.h"

#include <clap/clap.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
#include <unordered_map>

namespace dawkit {

// The kind of window a plugin's is put in, here.
#ifdef _WIN32
static const char *const WINDOW_API = CLAP_WINDOW_API_WIN32;
#else
static const char *const WINDOW_API = CLAP_WINDOW_API_X11;
#endif

namespace {

// A .clap file, opened once however many plugins come out of it, and its entry initialised once.
struct ClapModule {
	Library lib;
	const clap_plugin_entry_t *entry = nullptr;
	std::string path;
	bool bridged = false; // yabridge's (it says its version), standing in for a Windows plugin
	~ClapModule() {
		if (entry) {
			entry->deinit();
		}
	}
};

std::map<std::string, std::weak_ptr<ClapModule>> &modules() {
	static std::map<std::string, std::weak_ptr<ClapModule>> m;
	return m;
}

std::shared_ptr<ClapModule> open_module(const std::string &path, std::string &problem) {
	auto &all = modules();
	auto it = all.find(path);
	if (it != all.end()) {
		if (auto had = it->second.lock()) {
			return had;
		}
	}
	auto m = std::make_shared<ClapModule>();
	m->path = path;
	if (!m->lib.open(path, problem)) {
		return nullptr;
	}
	const char *(*bridge_version)() = nullptr;
	m->bridged = m->lib.get("yabridge_version", bridge_version);
	const clap_plugin_entry_t *entry = nullptr;
	if (!m->lib.get("clap_entry", entry)) {
		problem = path + " has no clap_entry";
		return nullptr;
	}
	if (!clap_version_is_compatible(entry->clap_version)) {
		problem = path + " is a CLAP version this host does not speak";
		return nullptr;
	}
	if (!entry->init(path.c_str())) {
		problem = path + " would not initialise";
		return nullptr;
	}
	m->entry = entry;
	all[path] = m;
	return m;
}

const clap_plugin_factory_t *factory_of(const ClapModule &m) {
	return (const clap_plugin_factory_t *)m.entry->get_factory(CLAP_PLUGIN_FACTORY_ID);
}

bool has_feature(const clap_plugin_descriptor_t *d, const char *feature) {
	if (!d->features) {
		return false;
	}
	for (const char *const *f = d->features; *f; f++) {
		if (std::strcmp(*f, feature) == 0) {
			return true;
		}
	}
	return false;
}

std::string features_of(const clap_plugin_descriptor_t *d) {
	std::string out;
	if (d->features) {
		for (const char *const *f = d->features; *f; f++) {
			out += (out.empty() ? "" : " ") + std::string(*f);
		}
	}
	return out;
}

thread_local bool audio_thread = false;

// The events a block is given: notes and parameter changes, in one sorted list.
union AnyEvent {
	clap_event_header_t header;
	clap_event_note_t note;
	clap_event_param_value_t param;
	clap_event_midi_t midi;
};

class ClapPlugin final : public HostedPlugin {
public:
	ClapPlugin(std::shared_ptr<ClapModule> mod) : module(std::move(mod)) {
		bridged = module->bridged;
		host.clap_version = CLAP_VERSION;
		host.host_data = this;
		host.name = "dawkit";
		host.vendor = "dawkit";
		host.url = "";
		host.version = "1.0";
		host.get_extension = &ClapPlugin::host_extension;
		host.request_restart = [](const clap_host_t *h) { self(h)->restart_wanted.store(true); };
		host.request_process = [](const clap_host_t *) {};
		host.request_callback = [](const clap_host_t *h) { self(h)->callback_wanted.store(true); };
		in_list.ctx = this;
		in_list.size = [](const clap_input_events_t *l) -> uint32_t { return ((ClapPlugin *)l->ctx)->in_count; };
		in_list.get = [](const clap_input_events_t *l, uint32_t i) -> const clap_event_header_t * {
			ClapPlugin *p = (ClapPlugin *)l->ctx;
			return i < p->in_count ? &p->in_events[i].header : nullptr;
		};
		out_list.ctx = this;
		out_list.try_push = [](const clap_output_events_t *l, const clap_event_header_t *e) -> bool {
			((ClapPlugin *)l->ctx)->heard(e);
			return true;
		};
	}

	~ClapPlugin() override {
		editor_close();
		deactivate();
		for (int id : loop_ids) {
			RunLoop::get().remove(id);
		}
		if (plugin) {
			plugin->destroy(plugin);
		}
	}

	bool load(const std::string &id, std::string &why) {
		const clap_plugin_factory_t *f = factory_of(*module);
		if (!f) {
			why = module->path + " has no plugin factory";
			return false;
		}
		plugin = f->create_plugin(f, &host, id.c_str());
		if (!plugin) {
			why = "no plugin " + id + " in " + module->path;
			return false;
		}
		if (!plugin->init(plugin)) {
			why = id + " would not initialise";
			plugin->destroy(plugin);
			plugin = nullptr;
			return false;
		}
		description.format = "CLAP";
		description.id = id;
		description.path = module->path;
		const clap_plugin_descriptor_t *d = plugin->desc;
		description.name = d->name ? d->name : id;
		description.vendor = d->vendor ? d->vendor : "";
		description.version = d->version ? d->version : "";
		description.category = features_of(d);
		description.instrument = has_feature(d, CLAP_PLUGIN_FEATURE_INSTRUMENT);
		ext_params = (const clap_plugin_params_t *)plugin->get_extension(plugin, CLAP_EXT_PARAMS);
		ext_state = (const clap_plugin_state_t *)plugin->get_extension(plugin, CLAP_EXT_STATE);
		ext_gui = (const clap_plugin_gui_t *)plugin->get_extension(plugin, CLAP_EXT_GUI);
		ext_ports = (const clap_plugin_audio_ports_t *)plugin->get_extension(plugin, CLAP_EXT_AUDIO_PORTS);
		ext_latency = (const clap_plugin_latency_t *)plugin->get_extension(plugin, CLAP_EXT_LATENCY);
		ext_timer = (const clap_plugin_timer_support_t *)plugin->get_extension(plugin, CLAP_EXT_TIMER_SUPPORT);
		ext_fd = (const clap_plugin_posix_fd_support_t *)plugin->get_extension(plugin, CLAP_EXT_POSIX_FD_SUPPORT);
		ext_tail = (const clap_plugin_tail_t *)plugin->get_extension(plugin, CLAP_EXT_TAIL);
		description.has_editor = editor_supported();
		read_ports();
		read_params();
		return true;
	}

	// --- the main thread ----------------------------------------------------------------------

	bool activate(double rate, int max_block) override {
		if (active.load()) {
			return true;
		}
		this->rate = rate;
		this->max_block = max_block;
		if (!plugin->activate(plugin, rate, 1, (uint32_t)max_block)) {
			problem = description.name + " would not start";
			return false;
		}
		processing = false;
		active.store(true);
		return true;
	}

	void deactivate() override {
		if (!active.load()) {
			return;
		}
		active.store(false);
		if (processing) {
			// The audio thread no longer calls it (whoever deactivates has taken it out of the mix
			// first), so this thread stands in for it, as the plugin is told.
			audio_thread = true;
			plugin->stop_processing(plugin);
			audio_thread = false;
			processing = false;
		}
		plugin->deactivate(plugin);
	}

	void set_normalized(int i, double value) override {
		if (i < 0 || i >= param_count()) {
			return;
		}
		store_value(i, value, false);
		if (active.load()) {
			queue_to_audio(i, value);
		} else if (ext_params && ext_params->flush) {
			// Not processing, so the plugin is told now, on this thread, as it asks to be.
			in_count = 0;
			add_param_event(i, value, 0);
			ext_params->flush(plugin, &in_list, &out_list);
			in_count = 0;
		}
	}

	std::string param_text(int i, double value) override {
		if (i < 0 || i >= param_count() || !ext_params || !ext_params->value_to_text) {
			return "";
		}
		char buf[256] = { 0 };
		if (!ext_params->value_to_text(plugin, params[i].format_id, plain(i, value), buf, sizeof buf)) {
			return "";
		}
		return buf;
	}

	bool get_state(std::vector<uint8_t> &out) override {
		if (!ext_state) {
			return false;
		}
		out.clear();
		clap_ostream_t s;
		s.ctx = &out;
		s.write = [](const clap_ostream_t *st, const void *buf, uint64_t size) -> int64_t {
			auto *v = (std::vector<uint8_t> *)st->ctx;
			v->insert(v->end(), (const uint8_t *)buf, (const uint8_t *)buf + size);
			return (int64_t)size;
		};
		return ext_state->save(plugin, &s);
	}

	bool set_state(const std::vector<uint8_t> &in) override {
		if (!ext_state) {
			return false;
		}
		struct Reader {
			const std::vector<uint8_t> *data;
			size_t at;
		} r{ &in, 0 };
		clap_istream_t s;
		s.ctx = &r;
		s.read = [](const clap_istream_t *st, void *buf, uint64_t size) -> int64_t {
			Reader *rd = (Reader *)st->ctx;
			size_t n = std::min<size_t>(size, rd->data->size() - rd->at);
			std::memcpy(buf, rd->data->data() + rd->at, n);
			rd->at += n;
			return (int64_t)n;
		};
		bool ok = ext_state->load(plugin, &s);
		if (ok) {
			refresh_values(true);
		}
		return ok;
	}

	int latency() const override {
		return ext_latency && active.load() ? (int)ext_latency->get(plugin) : 0;
	}

	int tail_samples() const override {
		if (!ext_tail || !active.load()) {
			return 0;
		}
		uint32_t t = ext_tail->get(plugin);
		return t > (uint32_t)INT32_MAX ? INT32_MAX : (int)t;
	}

	void main_thread() override {
		if (callback_wanted.exchange(false)) {
			plugin->on_main_thread(plugin);
		}
		if (rescan_wanted.exchange(false)) {
			if (active.load() && rescan_needs_restart) {
				restart_wanted.store(true);
			} else {
				read_params();
				mark_rescanned();
			}
			rescan_needs_restart = false;
		}
		if (restart_wanted.exchange(false) && active.load()) {
			double r = rate;
			int b = max_block;
			deactivate();
			read_ports();
			read_params();
			mark_rescanned();
			activate(r, b);
		}
	}

	bool editor_supported() override {
		return ext_gui && ext_gui->is_api_supported(plugin, WINDOW_API, false);
	}

	bool editor_open(uintptr_t parent, int &width, int &height) override {
		if (!editor_supported()) {
			problem = description.name + " has no window this host can show";
			return false;
		}
		editor_close();
		if (!ext_gui->create(plugin, WINDOW_API, false)) {
			problem = description.name + " would not make its window";
			return false;
		}
		gui_made = true;
		ext_gui->set_scale(plugin, 1.0);
		uint32_t w = 0, h = 0;
		ext_gui->get_size(plugin, &w, &h);
		clap_window_t win;
		win.api = WINDOW_API;
#ifdef _WIN32
		win.win32 = (clap_hwnd)parent;
#else
		win.x11 = (clap_xwnd)parent;
#endif
		if (!ext_gui->set_parent(plugin, &win)) {
			problem = description.name + " would not go into the window it was given";
			editor_close();
			return false;
		}
		ext_gui->show(plugin);
		width = (int)w;
		height = (int)h;
		return true;
	}

	void editor_close() override {
		if (gui_made) {
			ext_gui->hide(plugin);
			ext_gui->destroy(plugin);
			gui_made = false;
		}
	}

	// --- the audio thread ---------------------------------------------------------------------

	void process(const float *const *in, float *const *out, int frames, const Event *events, int event_count,
			const Transport &t) override {
		if (!active.load()) {
			for (int c = 0; c < outputs; c++) {
				std::memset(out[c], 0, sizeof(float) * frames);
			}
			return;
		}
		audio_thread = true;
		if (!processing) {
			processing = plugin->start_processing(plugin);
		}
		in_count = 0;
		ParamChange pc;
		while (in_count < MAX_EVENTS && to_audio.pop(pc)) {
			add_param_event(pc.index, pc.value, 0);
		}
		for (int e = 0; e < event_count && in_count < MAX_EVENTS; e++) {
			add_event(events[e]);
		}
		// Kept in time order, as the plugin may expect: the parameters at 0 first, then the rest.
		std::stable_sort(in_events, in_events + in_count,
				[](const AnyEvent &a, const AnyEvent &b) { return a.header.time < b.header.time; });

		clap_event_transport_t tr;
		std::memset(&tr, 0, sizeof tr);
		tr.header.size = sizeof tr;
		tr.header.type = CLAP_EVENT_TRANSPORT;
		tr.header.space_id = CLAP_CORE_EVENT_SPACE_ID;
		tr.flags = CLAP_TRANSPORT_HAS_TEMPO | CLAP_TRANSPORT_HAS_BEATS_TIMELINE | CLAP_TRANSPORT_HAS_SECONDS_TIMELINE |
				CLAP_TRANSPORT_HAS_TIME_SIGNATURE | (t.playing ? CLAP_TRANSPORT_IS_PLAYING : 0);
		tr.song_pos_beats = (clap_beattime)std::llround(t.beats * CLAP_BEATTIME_FACTOR);
		tr.song_pos_seconds = (clap_sectime)std::llround(t.seconds * CLAP_SECTIME_FACTOR);
		tr.tempo = t.tempo;
		tr.bar_start = (clap_beattime)std::llround(t.bar_start * CLAP_BEATTIME_FACTOR);
		tr.bar_number = t.numerator > 0 ? (int32_t)(t.bar_start / (t.numerator * 4.0 / t.denominator)) : 0;
		tr.tsig_num = (uint16_t)t.numerator;
		tr.tsig_denom = (uint16_t)t.denominator;

		clap_audio_buffer_t ins, outs;
		std::memset(&ins, 0, sizeof ins);
		std::memset(&outs, 0, sizeof outs);
		ins.data32 = const_cast<float **>(in);
		ins.channel_count = (uint32_t)inputs;
		outs.data32 = const_cast<float **>(out);
		outs.channel_count = (uint32_t)outputs;

		clap_process_t p;
		std::memset(&p, 0, sizeof p);
		p.steady_time = t.frames;
		p.frames_count = (uint32_t)frames;
		p.transport = &tr;
		p.audio_inputs = &ins;
		p.audio_outputs = &outs;
		p.audio_inputs_count = inputs > 0 ? 1 : 0;
		p.audio_outputs_count = outputs > 0 ? 1 : 0;
		p.in_events = &in_list;
		p.out_events = &out_list;
		if (processing) {
			plugin->process(plugin, &p);
		} else {
			for (int c = 0; c < outputs; c++) {
				std::memset(out[c], 0, sizeof(float) * frames);
			}
		}
		audio_thread = false;
	}

private:
	static ClapPlugin *self(const clap_host_t *h) { return (ClapPlugin *)h->host_data; }

	double plain(int i, double normalized) const {
		const ParamInfo &p = params[i];
		double v = p.min + std::clamp(normalized, 0.0, 1.0) * (p.max - p.min);
		return p.steps > 0 ? std::round(v) : v;
	}
	double normal(int i, double value) const {
		const ParamInfo &p = params[i];
		return p.max > p.min ? std::clamp((value - p.min) / (p.max - p.min), 0.0, 1.0) : 0.0;
	}

	void read_ports() {
		inputs = 0;
		outputs = 0;
		if (!ext_ports) {
			inputs = description.instrument ? 0 : 2;
			outputs = 2;
			return;
		}
		clap_audio_port_info_t info;
		if (ext_ports->count(plugin, true) > 0 && ext_ports->get(plugin, 0, true, &info)) {
			inputs = (int)std::min<uint32_t>(info.channel_count, 2);
		}
		if (ext_ports->count(plugin, false) > 0 && ext_ports->get(plugin, 0, false, &info)) {
			outputs = (int)std::min<uint32_t>(info.channel_count, 2);
		}
	}

	void read_params() {
		std::vector<ParamInfo> list;
		by_id.clear();
		if (ext_params) {
			uint32_t n = ext_params->count(plugin);
			for (uint32_t i = 0; i < n; i++) {
				clap_param_info_t ci;
				std::memset(&ci, 0, sizeof ci);
				if (!ext_params->get_info(plugin, i, &ci)) {
					continue;
				}
				ParamInfo p;
				p.name = ci.name;
				p.min = ci.min_value;
				p.max = ci.max_value;
				p.steps = (ci.flags & CLAP_PARAM_IS_STEPPED) ? (int)std::llround(ci.max_value - ci.min_value) : 0;
				p.automatable = (ci.flags & CLAP_PARAM_IS_AUTOMATABLE) != 0;
				p.hidden = (ci.flags & CLAP_PARAM_IS_HIDDEN) != 0;
				p.read_only = (ci.flags & CLAP_PARAM_IS_READONLY) != 0;
				p.bypass = (ci.flags & CLAP_PARAM_IS_BYPASS) != 0;
				p.format_id = ci.id;
				p.def = p.max > p.min ? std::clamp((ci.default_value - p.min) / (p.max - p.min), 0.0, 1.0) : 0.0;
				by_id[ci.id] = (int)list.size();
				list.push_back(p);
			}
		}
		set_params(std::move(list));
		refresh_values(false);
	}

	// Every parameter's value read from the plugin again (a state loaded, a rescan).
	void refresh_values(bool tell) {
		if (!ext_params) {
			return;
		}
		for (int i = 0; i < param_count(); i++) {
			double v;
			if (ext_params->get_value(plugin, params[i].format_id, &v)) {
				store_value(i, normal(i, v), tell);
			}
		}
	}

	void add_param_event(int i, double value, uint32_t time) {
		AnyEvent &e = in_events[in_count++];
		std::memset(&e, 0, sizeof e);
		e.param.header.size = sizeof(clap_event_param_value_t);
		e.param.header.time = time;
		e.param.header.space_id = CLAP_CORE_EVENT_SPACE_ID;
		e.param.header.type = CLAP_EVENT_PARAM_VALUE;
		e.param.param_id = params[i].format_id;
		e.param.note_id = -1;
		e.param.port_index = -1;
		e.param.channel = -1;
		e.param.key = -1;
		e.param.value = plain(i, value);
	}

	void add_event(const Event &ev) {
		AnyEvent &e = in_events[in_count++];
		std::memset(&e, 0, sizeof e);
		uint32_t time = (uint32_t)std::max(ev.offset, 0);
		switch (ev.kind) {
			case Event::NOTE_ON:
			case Event::NOTE_OFF:
				e.note.header.size = sizeof(clap_event_note_t);
				e.note.header.type = ev.kind == Event::NOTE_ON ? CLAP_EVENT_NOTE_ON : CLAP_EVENT_NOTE_OFF;
				e.note.note_id = -1;
				e.note.port_index = 0;
				e.note.channel = ev.channel;
				e.note.key = ev.key;
				e.note.velocity = ev.value;
				break;
			case Event::CONTROL:
			case Event::PITCH_BEND:
			case Event::ALL_NOTES_OFF: {
				e.midi.header.size = sizeof(clap_event_midi_t);
				e.midi.header.type = CLAP_EVENT_MIDI;
				e.midi.port_index = 0;
				if (ev.kind == Event::PITCH_BEND) {
					int v = std::clamp((int)std::lround((ev.value + 1.0) * 8192.0), 0, 16383);
					e.midi.data[0] = (uint8_t)(0xE0 | (ev.channel & 15));
					e.midi.data[1] = (uint8_t)(v & 127);
					e.midi.data[2] = (uint8_t)(v >> 7);
				} else {
					e.midi.data[0] = (uint8_t)(0xB0 | (ev.channel & 15));
					e.midi.data[1] = ev.kind == Event::ALL_NOTES_OFF ? 123 : ev.key;
					e.midi.data[2] = ev.kind == Event::ALL_NOTES_OFF ? 0 : (uint8_t)std::clamp((int)std::lround(ev.value * 127.0), 0, 127);
				}
				break;
			}
		}
		e.header.time = time;
		e.header.space_id = CLAP_CORE_EVENT_SPACE_ID;
	}

	// What the plugin says back: a parameter it moved itself.
	void heard(const clap_event_header_t *e) {
		if (e->space_id != CLAP_CORE_EVENT_SPACE_ID || e->type != CLAP_EVENT_PARAM_VALUE) {
			return;
		}
		auto *pv = (const clap_event_param_value_t *)e;
		auto it = by_id.find(pv->param_id);
		if (it != by_id.end()) {
			store_value(it->second, normal(it->second, pv->value), true);
		}
	}

	static const void *host_extension(const clap_host_t *h, const char *id) {
		static const clap_host_log_t log = { [](const clap_host_t *, clap_log_severity, const char *) {} };
		static const clap_host_thread_check_t threads = {
			[](const clap_host_t *) -> bool { return on_main_thread(); },
			[](const clap_host_t *) -> bool { return audio_thread; },
		};
		static const clap_host_params_t params = {
			[](const clap_host_t *h, clap_param_rescan_flags flags) {
				ClapPlugin *p = self(h);
				p->rescan_needs_restart = p->rescan_needs_restart || (flags & CLAP_PARAM_RESCAN_ALL);
				p->rescan_wanted.store(true);
				if (on_main_thread()) {
					p->main_thread();
				}
			},
			[](const clap_host_t *, clap_id, clap_param_clear_flags) {},
			[](const clap_host_t *h) { self(h)->callback_wanted.store(true); },
		};
		static const clap_host_state_t state = { [](const clap_host_t *) {} };
		static const clap_host_latency_t latency = { [](const clap_host_t *) {} };
		static const clap_host_gui_t gui = {
			[](const clap_host_t *) {},
			[](const clap_host_t *h, uint32_t w, uint32_t hh) -> bool {
				self(h)->request_editor_size((int)w, (int)hh);
				return true;
			},
			[](const clap_host_t *) -> bool { return true; },
			[](const clap_host_t *) -> bool { return true; },
			[](const clap_host_t *, bool) {},
		};
		static const clap_host_timer_support_t timers = {
			[](const clap_host_t *h, uint32_t period, clap_id *timer_id) -> bool {
				ClapPlugin *p = self(h);
				clap_id cid = (clap_id)p->next_timer++;
				int real = RunLoop::get().add_timer((int)period, [p, cid]() {
					if (p->ext_timer) {
						p->ext_timer->on_timer(p->plugin, cid);
					}
				});
				p->timers[cid] = real;
				p->loop_ids.push_back(real);
				*timer_id = cid;
				return true;
			},
			[](const clap_host_t *h, clap_id timer_id) -> bool {
				ClapPlugin *p = self(h);
				auto it = p->timers.find(timer_id);
				if (it == p->timers.end()) {
					return false;
				}
				RunLoop::get().remove(it->second);
				p->timers.erase(it);
				return true;
			},
		};
		static const clap_host_posix_fd_support_t fds = {
			[](const clap_host_t *h, int fd, clap_posix_fd_flags_t) -> bool {
				ClapPlugin *p = self(h);
				int id = RunLoop::get().add_fd(fd, [p, fd]() {
					if (p->ext_fd) {
						p->ext_fd->on_fd(p->plugin, fd, CLAP_POSIX_FD_READ);
					}
				});
				p->fds[fd] = id;
				p->loop_ids.push_back(id);
				return true;
			},
			[](const clap_host_t *, int, clap_posix_fd_flags_t) -> bool { return true; },
			[](const clap_host_t *h, int fd) -> bool {
				ClapPlugin *p = self(h);
				auto it = p->fds.find(fd);
				if (it == p->fds.end()) {
					return false;
				}
				RunLoop::get().remove(it->second);
				p->fds.erase(it);
				return true;
			},
		};
		static const clap_host_audio_ports_t ports = {
			[](const clap_host_t *, uint32_t) -> bool { return true; },
			[](const clap_host_t *h, uint32_t) { self(h)->restart_wanted.store(true); },
		};
		static const clap_host_note_ports_t notes = {
			[](const clap_host_t *) -> uint32_t { return CLAP_NOTE_DIALECT_CLAP | CLAP_NOTE_DIALECT_MIDI; },
			[](const clap_host_t *, uint32_t) {},
		};
		static const clap_host_tail_t tail = { [](const clap_host_t *) {} };
		(void)h;
		if (!std::strcmp(id, CLAP_EXT_LOG)) return &log;
		if (!std::strcmp(id, CLAP_EXT_THREAD_CHECK)) return &threads;
		if (!std::strcmp(id, CLAP_EXT_PARAMS)) return &params;
		if (!std::strcmp(id, CLAP_EXT_STATE)) return &state;
		if (!std::strcmp(id, CLAP_EXT_LATENCY)) return &latency;
		if (!std::strcmp(id, CLAP_EXT_GUI)) return &gui;
		if (!std::strcmp(id, CLAP_EXT_TIMER_SUPPORT)) return &timers;
		if (!std::strcmp(id, CLAP_EXT_POSIX_FD_SUPPORT)) return &fds;
		if (!std::strcmp(id, CLAP_EXT_AUDIO_PORTS)) return &ports;
		if (!std::strcmp(id, CLAP_EXT_NOTE_PORTS)) return &notes;
		if (!std::strcmp(id, CLAP_EXT_TAIL)) return &tail;
		return nullptr;
	}

	static constexpr uint32_t MAX_EVENTS = 1024;

	std::shared_ptr<ClapModule> module;
	clap_host_t host;
	const clap_plugin_t *plugin = nullptr;
	const clap_plugin_params_t *ext_params = nullptr;
	const clap_plugin_state_t *ext_state = nullptr;
	const clap_plugin_gui_t *ext_gui = nullptr;
	const clap_plugin_audio_ports_t *ext_ports = nullptr;
	const clap_plugin_latency_t *ext_latency = nullptr;
	const clap_plugin_timer_support_t *ext_timer = nullptr;
	const clap_plugin_posix_fd_support_t *ext_fd = nullptr;
	const clap_plugin_tail_t *ext_tail = nullptr;
	std::unordered_map<clap_id, int> by_id;
	std::map<clap_id, int> timers;
	std::map<int, int> fds;
	std::vector<int> loop_ids;
	int next_timer = 1;
	double rate = 48000.0;
	int max_block = 4096;
	bool processing = false;
	bool gui_made = false;
	bool rescan_needs_restart = false;
	std::atomic<bool> callback_wanted{ false };
	std::atomic<bool> restart_wanted{ false };
	std::atomic<bool> rescan_wanted{ false };
	AnyEvent in_events[MAX_EVENTS];
	uint32_t in_count = 0;
	clap_input_events_t in_list;
	clap_output_events_t out_list;
};

} // namespace

std::vector<PluginInfo> scan_clap(const std::string &path, std::string &problem) {
	std::vector<PluginInfo> out;
	auto m = open_module(path, problem);
	if (!m) {
		return out;
	}
	const clap_plugin_factory_t *f = factory_of(*m);
	if (!f) {
		problem = path + " has no plugin factory";
		return out;
	}
	uint32_t n = f->get_plugin_count(f);
	for (uint32_t i = 0; i < n; i++) {
		const clap_plugin_descriptor_t *d = f->get_plugin_descriptor(f, i);
		if (!d || !d->id) {
			continue;
		}
		PluginInfo info;
		info.format = "CLAP";
		info.id = d->id;
		info.name = d->name ? d->name : d->id;
		info.vendor = d->vendor ? d->vendor : "";
		info.version = d->version ? d->version : "";
		info.path = path;
		info.category = features_of(d);
		info.instrument = has_feature(d, CLAP_PLUGIN_FEATURE_INSTRUMENT);
		info.has_editor = true;
		out.push_back(info);
	}
	return out;
}

std::unique_ptr<HostedPlugin> load_clap(const std::string &path, const std::string &id, std::string &problem) {
	auto m = open_module(path, problem);
	if (!m) {
		return nullptr;
	}
	auto p = std::make_unique<ClapPlugin>(m);
	if (!p->load(id, problem)) {
		return nullptr;
	}
	return p;
}

} // namespace dawkit
