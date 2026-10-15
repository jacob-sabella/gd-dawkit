// Where plugins are not hosted (Windows for now, Android for good): every format finds nothing.
#include "hosted_plugin.h"
#include "x11_editor.h"

namespace dawkit {

static const char *NOT_HERE = "plugins are not hosted on this system";

std::vector<PluginInfo> scan_clap(const std::string &, std::string &problem) {
	problem = NOT_HERE;
	return {};
}
std::vector<PluginInfo> scan_vst3(const std::string &, std::string &problem) {
	problem = NOT_HERE;
	return {};
}
std::vector<PluginInfo> scan_lv2(std::string &problem) {
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
std::unique_ptr<HostedPlugin> load_lv2(const std::string &, std::string &problem) {
	problem = NOT_HERE;
	return nullptr;
}

// Never made here, but named by the engine's plugin class.
void X11Editor::destroy() {}

} // namespace dawkit
