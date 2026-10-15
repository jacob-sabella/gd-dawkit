#include "dawkit_lane.h"
#include "dawkit_plugin.h"
#include "dawkit_transport.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize_dawkit(ModuleInitializationLevel level) {
	if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(DawKitTransport);
	GDREGISTER_CLASS(DawKitLane);
	GDREGISTER_CLASS(DawKitLanePlayback);
	GDREGISTER_CLASS(DawKitPlugin);
	GDREGISTER_CLASS(DawKitPluginEffect);
	GDREGISTER_CLASS(DawKitPluginEffectInstance);
	// Plugins are made, and their windows run, on this thread.
	dawkit::set_main_thread();
}

static void uninitialize_dawkit(ModuleInitializationLevel level) {
}

extern "C" {
GDExtensionBool GDE_EXPORT dawkit_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,
		const GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
	GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
	init.register_initializer(initialize_dawkit);
	init.register_terminator(uninitialize_dawkit);
	init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init.init();
}
}
