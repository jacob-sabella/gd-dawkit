cmake_minimum_required(VERSION 3.17)
project(dawkit_native LANGUAGES C CXX)

# The engine's mixing core as a GDExtension. Built against the API of the Godot that runs it
# (extension_api.json, dumped by `godot --dump-extension-api`), with godot-cpp (MIT).
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(GODOTCPP_CUSTOM_API_FILE "${CMAKE_CURRENT_SOURCE_DIR}/extension_api.json" CACHE FILEPATH "" FORCE)
add_subdirectory(godot-cpp)

# Third-party plugins (CLAP, VST3, LV2), hosted on Linux. Plain C++, shared with dawkit_scan. Only
# the formats' interface headers are here (native/third_party: MIT, ISC); lilv and Xlib are
# opened at run time, so a system without them still loads the engine.
set(DAWKIT_PLUGIN_SOURCES src/plugins/hosted_plugin.cpp)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(DAWKIT_HOSTS_PLUGINS ON)
    list(APPEND DAWKIT_PLUGIN_SOURCES
        src/plugins/clap_host.cpp
        src/plugins/vst3_host.cpp
        src/plugins/lv2_host.cpp
        src/plugins/x11_editor.cpp
    )
else()
    list(APPEND DAWKIT_PLUGIN_SOURCES src/plugins/no_hosting.cpp)
endif()
set(DAWKIT_PLUGIN_INCLUDES
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/plugins
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/clap/include
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/vst3
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lv2/include
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lilv
)
add_library(dawkit_plugins STATIC ${DAWKIT_PLUGIN_SOURCES})
target_include_directories(dawkit_plugins PUBLIC ${DAWKIT_PLUGIN_INCLUDES})
set_target_properties(dawkit_plugins PROPERTIES POSITION_INDEPENDENT_CODE ON)
if(DAWKIT_HOSTS_PLUGINS)
    target_compile_definitions(dawkit_plugins PUBLIC DAWKIT_HOSTS_PLUGINS)
    target_link_libraries(dawkit_plugins PUBLIC ${CMAKE_DL_LIBS} pthread)
endif()

add_library(dawkit SHARED
    src/register_types.cpp
    src/dawkit_transport.cpp
    src/dawkit_lane.cpp
    src/dawkit_plugin.cpp
)
target_link_libraries(dawkit PRIVATE godot::cpp dawkit_plugins)

if(DAWKIT_HOSTS_PLUGINS)
    add_executable(dawkit_scan src/plugins/dawkit_scan.cpp)
    target_link_libraries(dawkit_scan PRIVATE dawkit_plugins)
    set_target_properties(dawkit_scan PROPERTIES
        OUTPUT_NAME "dawkit_scan.linux.${CMAKE_SYSTEM_PROCESSOR}"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../addons/dawkit/bin"
    )
    # A CLAP for dawkit's own checks (tests/run_tests.gd), never shipped.
    add_library(dawkit_test_plugin MODULE test_plugin/dawkit_test_plugin.c)
    target_include_directories(dawkit_test_plugin PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/third_party/clap/include)
    target_link_libraries(dawkit_test_plugin PRIVATE m)
    set_target_properties(dawkit_test_plugin PROPERTIES PREFIX "" OUTPUT_NAME "dawkit_test" SUFFIX ".clap"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
endif()
set_target_properties(dawkit PROPERTIES
    OUTPUT_NAME "dawkit.${CMAKE_SYSTEM_NAME}.${GODOTCPP_TARGET}"
    PREFIX "lib"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../addons/dawkit/bin"
    # A Windows DLL is a runtime output, not a library one.
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../addons/dawkit/bin"
)
if(MINGW)
    # The C++ runtime inside the DLL, so it needs nothing beside it on a player's machine.
    target_link_options(dawkit PRIVATE -static -static-libgcc -static-libstdc++)
endif()
string(TOLOWER "${CMAKE_SYSTEM_NAME}" DAWKIT_SYSTEM)
set_target_properties(dawkit PROPERTIES OUTPUT_NAME "dawkit.${DAWKIT_SYSTEM}.${GODOTCPP_TARGET}")
