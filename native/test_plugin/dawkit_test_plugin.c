// Two CLAP plugins for dawkit's own checks, built beside the extension (never shipped):
//
//   dawkit.test.gain   an effect: both channels times "Gain" (0-2, default 1), as many dB as it says
//   dawkit.test.sine   an instrument: a sine at each note's pitch, as loud as its velocity, until
//                      its note off; "Level" (0-1, default 0.5) on top
//
// Each keeps its one parameter as its state, so a state saved and loaded is seen to come back.
#include <clap/clap.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	clap_plugin_t plugin;
	const clap_host_t *host;
	int instrument;
	double value; // Gain, or Level
	double rate;
	double phase[128];
	float amp[128];
} test_t;

static const char *GAIN_FEATURES[] = { CLAP_PLUGIN_FEATURE_AUDIO_EFFECT, NULL };
static const char *SINE_FEATURES[] = { CLAP_PLUGIN_FEATURE_INSTRUMENT, CLAP_PLUGIN_FEATURE_SYNTHESIZER, NULL };

static const clap_plugin_descriptor_t GAIN = {
	CLAP_VERSION_INIT, "dawkit.test.gain", "Test Gain", "dawkit", "", "", "", "1.0", "", GAIN_FEATURES,
};
static const clap_plugin_descriptor_t SINE = {
	CLAP_VERSION_INIT, "dawkit.test.sine", "Test Sine", "dawkit", "", "", "", "1.0", "", SINE_FEATURES,
};

static test_t *self(const clap_plugin_t *p) { return (test_t *)p->plugin_data; }

static bool init(const clap_plugin_t *p) { (void)p; return true; }
static void destroy(const clap_plugin_t *p) { free(self(p)); }
static bool activate(const clap_plugin_t *p, double rate, uint32_t min, uint32_t max) {
	(void)min; (void)max;
	self(p)->rate = rate;
	return true;
}
static void deactivate(const clap_plugin_t *p) { (void)p; }
static bool start_processing(const clap_plugin_t *p) { (void)p; return true; }
static void stop_processing(const clap_plugin_t *p) { (void)p; }
static void reset(const clap_plugin_t *p) {
	memset(self(p)->amp, 0, sizeof self(p)->amp);
}

static void event(test_t *t, const clap_event_header_t *h) {
	if (h->space_id != CLAP_CORE_EVENT_SPACE_ID) return;
	if (h->type == CLAP_EVENT_PARAM_VALUE) {
		const clap_event_param_value_t *e = (const clap_event_param_value_t *)h;
		if (e->param_id == 0) t->value = e->value;
	} else if (h->type == CLAP_EVENT_NOTE_ON) {
		const clap_event_note_t *e = (const clap_event_note_t *)h;
		if (e->key >= 0 && e->key < 128) {
			t->amp[e->key] = (float)e->velocity;
			t->phase[e->key] = 0.0;
		}
	} else if (h->type == CLAP_EVENT_NOTE_OFF) {
		const clap_event_note_t *e = (const clap_event_note_t *)h;
		if (e->key >= 0 && e->key < 128) t->amp[e->key] = 0.0f;
	} else if (h->type == CLAP_EVENT_MIDI) {
		const clap_event_midi_t *e = (const clap_event_midi_t *)h;
		if ((e->data[0] & 0xF0) == 0xB0 && e->data[1] == 123) memset(t->amp, 0, sizeof t->amp);
	}
}

static clap_process_status process(const clap_plugin_t *p, const clap_process_t *pr) {
	test_t *t = self(p);
	uint32_t n = pr->in_events->size(pr->in_events);
	uint32_t next = 0;
	float **out = pr->audio_outputs[0].data32;
	float **in = t->instrument ? NULL : pr->audio_inputs[0].data32;
	for (uint32_t i = 0; i < pr->frames_count; i++) {
		while (next < n) {
			const clap_event_header_t *h = pr->in_events->get(pr->in_events, next);
			if (h->time > i) break;
			event(t, h);
			next++;
		}
		if (t->instrument) {
			float s = 0.0f;
			for (int k = 0; k < 128; k++) {
				if (t->amp[k] <= 0.0f) continue;
				s += t->amp[k] * (float)sin(t->phase[k]);
				t->phase[k] += 2.0 * M_PI * 440.0 * pow(2.0, (k - 69) / 12.0) / t->rate;
			}
			out[0][i] = out[1][i] = s * (float)t->value;
		} else {
			out[0][i] = in[0][i] * (float)t->value;
			out[1][i] = in[1][i] * (float)t->value;
		}
	}
	while (next < n) event(t, pr->in_events->get(pr->in_events, next++));
	return CLAP_PROCESS_CONTINUE;
}

// --- parameters --------------------------------------------------------------------------------

static uint32_t params_count(const clap_plugin_t *p) { (void)p; return 1; }
static bool params_info(const clap_plugin_t *p, uint32_t i, clap_param_info_t *info) {
	if (i != 0) return false;
	memset(info, 0, sizeof *info);
	info->id = 0;
	info->flags = CLAP_PARAM_IS_AUTOMATABLE;
	strcpy(info->name, self(p)->instrument ? "Level" : "Gain");
	info->min_value = 0.0;
	info->max_value = self(p)->instrument ? 1.0 : 2.0;
	info->default_value = self(p)->instrument ? 0.5 : 1.0;
	return true;
}
static bool params_value(const clap_plugin_t *p, clap_id id, double *v) {
	if (id != 0) return false;
	*v = self(p)->value;
	return true;
}
static bool params_text(const clap_plugin_t *p, clap_id id, double v, char *out, uint32_t size) {
	(void)p;
	if (id != 0) return false;
	if (v <= 0.0) snprintf(out, size, "-inf dB");
	else snprintf(out, size, "%.1f dB", 20.0 * log10(v));
	return true;
}
static bool params_from_text(const clap_plugin_t *p, clap_id id, const char *text, double *v) {
	(void)p; (void)id; (void)text; (void)v;
	return false;
}
static void params_flush(const clap_plugin_t *p, const clap_input_events_t *in, const clap_output_events_t *out) {
	(void)out;
	for (uint32_t i = 0; i < in->size(in); i++) event(self(p), in->get(in, i));
}
static const clap_plugin_params_t PARAMS = { params_count, params_info, params_value, params_text, params_from_text,
	params_flush };

// --- state -------------------------------------------------------------------------------------

static bool state_save(const clap_plugin_t *p, const clap_ostream_t *s) {
	double v = self(p)->value;
	return s->write(s, &v, sizeof v) == sizeof v;
}
static bool state_load(const clap_plugin_t *p, const clap_istream_t *s) {
	double v = 0.0;
	if (s->read(s, &v, sizeof v) != sizeof v) return false;
	self(p)->value = v;
	return true;
}
static const clap_plugin_state_t STATE = { state_save, state_load };

// --- ports -------------------------------------------------------------------------------------

static uint32_t audio_count(const clap_plugin_t *p, bool is_input) {
	return is_input && self(p)->instrument ? 0 : 1;
}
static bool audio_get(const clap_plugin_t *p, uint32_t i, bool is_input, clap_audio_port_info_t *info) {
	(void)p;
	if (i != 0) return false;
	memset(info, 0, sizeof *info);
	info->id = 0;
	strcpy(info->name, is_input ? "in" : "out");
	info->flags = CLAP_AUDIO_PORT_IS_MAIN;
	info->channel_count = 2;
	info->port_type = CLAP_PORT_STEREO;
	info->in_place_pair = CLAP_INVALID_ID;
	return true;
}
static const clap_plugin_audio_ports_t AUDIO = { audio_count, audio_get };

static uint32_t note_count(const clap_plugin_t *p, bool is_input) {
	return is_input && self(p)->instrument ? 1 : 0;
}
static bool note_get(const clap_plugin_t *p, uint32_t i, bool is_input, clap_note_port_info_t *info) {
	(void)p;
	if (i != 0 || !is_input) return false;
	memset(info, 0, sizeof *info);
	info->supported_dialects = CLAP_NOTE_DIALECT_CLAP | CLAP_NOTE_DIALECT_MIDI;
	info->preferred_dialect = CLAP_NOTE_DIALECT_CLAP;
	strcpy(info->name, "notes");
	return true;
}
static const clap_plugin_note_ports_t NOTES = { note_count, note_get };

static const void *extension(const clap_plugin_t *p, const char *id) {
	if (!strcmp(id, CLAP_EXT_PARAMS)) return &PARAMS;
	if (!strcmp(id, CLAP_EXT_STATE)) return &STATE;
	if (!strcmp(id, CLAP_EXT_AUDIO_PORTS)) return &AUDIO;
	if (!strcmp(id, CLAP_EXT_NOTE_PORTS) && self(p)->instrument) return &NOTES;
	return NULL;
}
static void on_main_thread(const clap_plugin_t *p) { (void)p; }

// --- the factory -------------------------------------------------------------------------------

static uint32_t count(const clap_plugin_factory_t *f) { (void)f; return 2; }
static const clap_plugin_descriptor_t *descriptor(const clap_plugin_factory_t *f, uint32_t i) {
	(void)f;
	return i == 0 ? &GAIN : i == 1 ? &SINE : NULL;
}
static const clap_plugin_t *create(const clap_plugin_factory_t *f, const clap_host_t *host, const char *id) {
	(void)f;
	int instrument;
	if (!strcmp(id, GAIN.id)) instrument = 0;
	else if (!strcmp(id, SINE.id)) instrument = 1;
	else return NULL;
	test_t *t = calloc(1, sizeof *t);
	t->host = host;
	t->instrument = instrument;
	t->value = instrument ? 0.5 : 1.0;
	t->rate = 48000.0;
	t->plugin.desc = instrument ? &SINE : &GAIN;
	t->plugin.plugin_data = t;
	t->plugin.init = init;
	t->plugin.destroy = destroy;
	t->plugin.activate = activate;
	t->plugin.deactivate = deactivate;
	t->plugin.start_processing = start_processing;
	t->plugin.stop_processing = stop_processing;
	t->plugin.reset = reset;
	t->plugin.process = process;
	t->plugin.get_extension = extension;
	t->plugin.on_main_thread = on_main_thread;
	return &t->plugin;
}
static const clap_plugin_factory_t FACTORY = { count, descriptor, create };

static bool entry_init(const char *path) { (void)path; return true; }
static void entry_deinit(void) {}
static const void *entry_factory(const char *id) {
	return !strcmp(id, CLAP_PLUGIN_FACTORY_ID) ? &FACTORY : NULL;
}

CLAP_EXPORT const clap_plugin_entry_t clap_entry = { CLAP_VERSION_INIT, entry_init, entry_deinit, entry_factory };
