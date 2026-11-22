# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
# Kai - CMake build. The Windows build (MSVC or clang-cl). On macOS and Linux
# the Makefile stays the build; this file also configures there, for checking.
#
#   cmake -S . -B build -G "Visual Studio 17 2022" -A x64
#   cmake --build build --config Release
#   ctest --test-dir build -C Release --output-on-failure
cmake_minimum_required(VERSION 3.21)
project(kai C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
# Static CRT: kai.exe needs no Visual C++ redistributable.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

option(KAI_RELEASE "Release build: ignore KAI_HOME / KAI_POLICY" OFF)

set(KAI_CORE
  src/util.c src/policy.c src/scan.c src/sha256.c src/audit.c src/net.c
  src/storage.c src/storage_prof.c src/grant.c src/approval_store.c src/proc.c
  src/shell.c src/winshell.c src/session.c src/agent_rules.c
  third_party/cjson/cJSON.c)
set(KAI_APP
  src/hooks.c src/install.c src/manage.c src/report.c src/health.c
  src/grant_cli.c src/status.c src/demo.c src/stats.c src/activity.c)

if(WIN32)
  list(APPEND KAI_CORE src/platform_win.c
    third_party/musl-regex/regcomp.c third_party/musl-regex/regexec.c
    third_party/musl-regex/tre-mem.c)
  # No Internet wall (gateway) and no Files wall (storaged) on Windows yet.
  list(APPEND KAI_APP src/gateway_none.c src/storaged_none.c)
else()
  list(APPEND KAI_CORE src/platform_posix.c)
  list(APPEND KAI_APP src/gateway.c src/storaged.c)
endif()

# src/kai_commit.h: the commit `kai version` reports.
find_package(Git QUIET)
set(KAI_COMMIT "unknown")
if(GIT_FOUND)
  execute_process(COMMAND ${GIT_EXECUTABLE} rev-parse --short=12 HEAD
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} OUTPUT_VARIABLE KAI_COMMIT
    OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
  execute_process(COMMAND ${GIT_EXECUTABLE} diff --quiet HEAD --
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} RESULT_VARIABLE KAI_DIRTY ERROR_QUIET)
  if(KAI_DIRTY)
    set(KAI_COMMIT "${KAI_COMMIT}-dirty")
  endif()
endif()
file(WRITE ${CMAKE_BINARY_DIR}/gen/kai_commit.h.tmp "#define KAI_COMMIT \"${KAI_COMMIT}\"\n")
configure_file(${CMAKE_BINARY_DIR}/gen/kai_commit.h.tmp ${CMAKE_BINARY_DIR}/gen/kai_commit.h COPYONLY)

function(kai_target_setup t)
  target_include_directories(${t} BEFORE PRIVATE
    ${CMAKE_BINARY_DIR}/gen include src third_party/cjson)
  if(WIN32)
    target_include_directories(${t} BEFORE PRIVATE compat/win)
    target_compile_definitions(${t} PRIVATE _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_WARNINGS
      WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE)
    target_link_libraries(${t} PRIVATE advapi32 shell32 ole32 bcrypt ws2_32)
  else()
    target_compile_definitions(${t} PRIVATE _POSIX_C_SOURCE=200809L _DARWIN_C_SOURCE _GNU_SOURCE)
  endif()
  if(MSVC)
    # Force-include the POSIX mapping; /utf-8 source and execution charset.
    target_compile_options(${t} PRIVATE /FI${CMAKE_SOURCE_DIR}/compat/win/kai_win_compat.h
      /utf-8 /W3 /wd4996 /wd4244 /wd4267 /wd4018 /wd4146 /experimental:c11atomics)
  endif()
  if(KAI_RELEASE)
    target_compile_definitions(${t} PRIVATE KAI_RELEASE)
  endif()
endfunction()

# musl regex: its own warnings are not ours.
if(WIN32)
  set_source_files_properties(
    third_party/musl-regex/regcomp.c third_party/musl-regex/regexec.c
    third_party/musl-regex/tre-mem.c
    PROPERTIES COMPILE_OPTIONS "/W0;/FI${CMAKE_SOURCE_DIR}/compat/win/musl_regex_prelude.h")
endif()

add_library(libkai STATIC ${KAI_CORE})
set_target_properties(libkai PROPERTIES OUTPUT_NAME kai_core)
kai_target_setup(libkai)

add_executable(kai src/main.c ${KAI_APP})
kai_target_setup(kai)
target_link_libraries(kai PRIVATE libkai)
if(WIN32)
  # UTF-8 active code page + long paths (compat/win/kai.manifest).
  target_sources(kai PRIVATE compat/win/kai.rc)
  target_link_options(kai PRIVATE /MANIFEST:NO)
endif()

# Test-only binary with the policy test seam (never shipped), like the Makefile.
add_executable(kai-test src/main.c ${KAI_APP})
kai_target_setup(kai-test)
target_compile_definitions(kai-test PRIVATE KAI_TEST_DIRECT_POLICY)
target_link_libraries(kai-test PRIVATE libkai)
if(WIN32)
  target_sources(kai-test PRIVATE compat/win/kai.rc)
  target_link_options(kai-test PRIVATE /MANIFEST:NO)
endif()

# ---- tests ----
enable_testing()
add_executable(kai_unit_tests tests/run_tests.c)
kai_target_setup(kai_unit_tests)
target_link_libraries(kai_unit_tests PRIVATE libkai)
set_target_properties(kai_unit_tests PROPERTIES OUTPUT_NAME run_tests)   # its agent rule matches *run_tests*
add_test(NAME unit COMMAND kai_unit_tests)

if(WIN32)
  add_executable(kai_win_tests tests/windows/run_win_tests.c)
  kai_target_setup(kai_win_tests)
  target_link_libraries(kai_win_tests PRIVATE libkai)
  target_sources(kai_win_tests PRIVATE compat/win/kai.rc)
  target_link_options(kai_win_tests PRIVATE /MANIFEST:NO)
  add_test(NAME windows COMMAND kai_win_tests)
endif()

find_package(Python3 COMPONENTS Interpreter QUIET)
if(Python3_FOUND)
  add_test(NAME escape
    COMMAND ${Python3_EXECUTABLE} -I tests/escape/run_escape.py $<TARGET_FILE:kai>
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
  if(WIN32)
    add_test(NAME windows-hooks
      COMMAND ${Python3_EXECUTABLE} -I tests/windows/run_win_hook_tests.py $<TARGET_FILE:kai>
      WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
  endif()
endif()

# cmake --install build --config Release --prefix "%LOCALAPPDATA%\Programs\Kai"
# puts kai.exe where Kai's checks treat it as Kai's own program (kai_program).
install(TARGETS kai RUNTIME DESTINATION .)
