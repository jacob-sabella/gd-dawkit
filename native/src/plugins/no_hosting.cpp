// The formats a system does not host find nothing: LV2 off Linux, everything on Android.
#include "hosted_plugin.h"
#include "editor_window.h"

namespace dawkit {

[[maybe_unused]] static const char *NOT_HERE = "plugins are not hosted on this system";

#ifndef DAWKIT_HOSTS_PLUGINS
std::vector<PluginInfo> scan_clap(const std::string &, std::string &problem) {
	problem = NOT_HERE;
	return {};
}
std::vector<PluginInfo> scan_vst3(const std::string &, std::string &problem) {
	problem = NOT_HERE;
	return {};
}
std::unique_ptr<HostedPlugin> load_clap(const std::string &, const std::string &, std::string &problem) {
	problem = NOT_HERE;
	return nullptr;
}
std::unique_ptr<HostedPlugin> load_vst3(const std::string &, const std::string &, std::string &problem) {
	problem = NOT_HERE;
	return nullptr;
}

// Never made here, but named by the engine's plugin class.
void EditorWindow::destroy() {}
#endif

#ifndef DAWKIT_HOSTS_LV2
std::vector<PluginInfo> scan_lv2(std::string &problem) {
	problem = "LV2 plugins are not hosted on this system";
	return {};
}
std::unique_ptr<HostedPlugin> load_lv2(const std::string &, std::string &problem) {
	problem = "LV2 plugins are not hosted on this system";
	return nullptr;
}
#endif

} // namespace dawkit
