cmake_minimum_required(VERSION 3.17)
project(dawkit_native LANGUAGES CXX)

# The engine's mixing core as a GDExtension. Built against the API of the Godot that runs it
# (extension_api.json, dumped by `godot --dump-extension-api`), with godot-cpp (MIT).
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(GODOTCPP_CUSTOM_API_FILE "${CMAKE_CURRENT_SOURCE_DIR}/extension_api.json" CACHE FILEPATH "" FORCE)
add_subdirectory(godot-cpp)

add_library(dawkit SHARED
    src/register_types.cpp
    src/dawkit_transport.cpp
    src/dawkit_lane.cpp
)
target_link_libraries(dawkit PRIVATE godot::cpp)
set_target_properties(dawkit PROPERTIES
    OUTPUT_NAME "dawkit.${CMAKE_SYSTEM_NAME}.${GODOTCPP_TARGET}"
    PREFIX "lib"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../addons/dawkit/bin"
)
string(TOLOWER "${CMAKE_SYSTEM_NAME}" DAWKIT_SYSTEM)
set_target_properties(dawkit PROPERTIES OUTPUT_NAME "dawkit.${DAWKIT_SYSTEM}.${GODOTCPP_TARGET}")
