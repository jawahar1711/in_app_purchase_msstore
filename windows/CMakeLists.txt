# in_app_purchase_msstore Flutter Windows plugin: a C++/WinRT wrapper around
# Windows.Services.Store.StoreContext. The method channel contract lives in
# doc/CHANNEL.md at the repository root.

cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "in_app_purchase_msstore")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed. The host app links against `${PROJECT_NAME}_plugin`.
set(PLUGIN_NAME "in_app_purchase_msstore_plugin")

# C++/WinRT coroutines (co_await, fire_and_forget) require C++20.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Sources shared by the plugin DLL and the unit test runner.
list(APPEND PLUGIN_SOURCES
  "in_app_purchase_msstore_plugin.cpp"
  "in_app_purchase_msstore_plugin.h"
  "store_helpers.h"
)

# Define the plugin library target.
add_library(${PLUGIN_NAME} SHARED
  "include/in_app_purchase_msstore/in_app_purchase_ms_store_plugin_c_api.h"
  "in_app_purchase_ms_store_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

# Apply common Flutter plugin properties.
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Include directories.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

# - flutter / flutter_wrapper_plugin: Flutter Windows engine ABI.
# - WindowsApp: WinRT runtime used by C++/WinRT.
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
target_link_libraries(${PLUGIN_NAME} PRIVATE "WindowsApp.lib")

# This plugin ships no extra files.
set(in_app_purchase_msstore_bundled_libraries
  ""
  PARENT_SCOPE
)

# === Tests ===
# The tests cover the pure helpers (status mapping, argument parsing, date
# and GUID handling). They need no Microsoft Store. Run them after building
# the example:
#   example\build\windows\x64\plugins\in_app_purchase_msstore\Debug\in_app_purchase_msstore_test.exe
#
# Only enabled when the example sets `include_in_app_purchase_msstore_tests`,
# so plugin clients never build them.
if (${include_${PROJECT_NAME}_tests})
set(TEST_RUNNER "${PROJECT_NAME}_test")
enable_testing()

# Add the Google Test dependency.
include(FetchContent)
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/refs/tags/v1.18.0.zip
)
# Prevent overriding the parent project's compiler/linker settings.
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
# Disable install commands for gtest so it doesn't end up in the bundle.
set(INSTALL_GTEST OFF CACHE BOOL "Disable installation of googletest" FORCE)
FetchContent_MakeAvailable(googletest)

# Build the sources directly into the test binary rather than using the DLL.
add_executable(${TEST_RUNNER}
  test/in_app_purchase_msstore_test.cpp
  ${PLUGIN_SOURCES}
)
apply_standard_settings(${TEST_RUNNER})
target_include_directories(${TEST_RUNNER} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(${TEST_RUNNER} PRIVATE flutter_wrapper_plugin)
target_link_libraries(${TEST_RUNNER} PRIVATE "WindowsApp.lib")
target_link_libraries(${TEST_RUNNER} PRIVATE gtest_main gmock)
# flutter_wrapper_plugin has link dependencies on the Flutter DLL.
add_custom_command(TARGET ${TEST_RUNNER} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
  "${FLUTTER_LIBRARY}" $<TARGET_FILE_DIR:${TEST_RUNNER}>
)

# Enable automatic test discovery.
include(GoogleTest)
gtest_discover_tests(${TEST_RUNNER})
endif()
