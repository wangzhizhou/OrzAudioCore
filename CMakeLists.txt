cmake_minimum_required(VERSION 3.21)
project(OrzAudioCore VERSION 1.0.0 LANGUAGES C CXX)

set(ORZ_PROFILE "full" CACHE STRING "Decoder profile: builtin-lite, full, server")
set_property(CACHE ORZ_PROFILE PROPERTY STRINGS builtin-lite full server)
option(ORZ_BUILD_SHARED "Build a shared OrzAudioCore library" OFF)
option(ORZ_BUILD_TESTS "Build ABI consumer tests" ON)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(ORZ_ROOT "${CMAKE_CURRENT_SOURCE_DIR}")
set(ORZ_SOURCE "${ORZ_ROOT}/Sources/OrzAudioKitCXX")
set(ORZ_THIRDPARTY "${ORZ_ROOT}/Libraries/OrzAudioKit/thirdparty")
set(ORZ_NATIVE_LIB "${ORZ_ROOT}/Libraries/OrzAudioKit/native" CACHE PATH "Prebuilt dependency directory")

set(ORZ_BUILTIN_SOURCES
    ${ORZ_SOURCE}/dispatch/audio_engine.c
    ${ORZ_SOURCE}/dispatch/orz_dispatch.c
    ${ORZ_SOURCE}/bp/bp_impl.c
    ${ORZ_SOURCE}/midi/midi_impl.c
    ${ORZ_SOURCE}/ym6/ym6_impl.c
    ${ORZ_SOURCE}/ym6/lhasa_adapter.c
    ${ORZ_SOURCE}/ym6/lhasa/lh5_decoder.c
    ${ORZ_SOURCE}/ym6/unlzh_ym.c)

set(ORZ_FULL_SOURCES
    ${ORZ_SOURCE}/openmpt/openmpt_impl.c
    ${ORZ_SOURCE}/gme/gme_impl.c
    ${ORZ_SOURCE}/asap/asap_impl.c
    ${ORZ_SOURCE}/sidplayfp/sidplayfp_impl.cpp
    ${ORZ_SOURCE}/sc68/sc68_impl.c
    ${ORZ_SOURCE}/v2m/v2m_native_impl.cpp
    ${ORZ_SOURCE}/uade/uade_native_ahx.c
    ${ORZ_SOURCE}/adplug/adplug_impl.c
    ${ORZ_SOURCE}/adplug/adplug_wrap.cpp
    ${ORZ_SOURCE}/helpers/cxx_helpers.cpp)

set(ORZ_LIBRARY_TYPE STATIC)
if(ORZ_BUILD_SHARED)
    set(ORZ_LIBRARY_TYPE SHARED)
endif()
add_library(OrzAudioCore ${ORZ_LIBRARY_TYPE} ${ORZ_BUILTIN_SOURCES})
add_library(OrzAudioCore::OrzAudioCore ALIAS OrzAudioCore)
target_include_directories(OrzAudioCore
    PUBLIC $<BUILD_INTERFACE:${ORZ_SOURCE}/include> $<INSTALL_INTERFACE:include>
    PRIVATE ${ORZ_SOURCE}/dispatch ${ORZ_THIRDPARTY})
target_compile_definitions(OrzAudioCore PRIVATE ORZ_AUDIO_CORE_BUILD=1)
if(UNIX AND NOT APPLE AND NOT EMSCRIPTEN)
    # Builtin MIDI and BP synthesis use libm. Keep it a transitive dependency
    # because consumers may link the static OrzAudioCore archive.
    target_link_libraries(OrzAudioCore PUBLIC m)
endif()

if(ORZ_PROFILE STREQUAL "builtin-lite")
    target_sources(OrzAudioCore PRIVATE ${ORZ_SOURCE}/stub_decoders.c)
else()
    target_sources(OrzAudioCore PRIVATE ${ORZ_FULL_SOURCES})
    target_include_directories(OrzAudioCore PRIVATE
        ${ORZ_THIRDPARTY}/sidplayfp ${ORZ_THIRDPARTY}/adplug ${ORZ_THIRDPARTY}/binio
        ${ORZ_THIRDPARTY}/sc68 ${ORZ_THIRDPARTY}/v2m_headers ${ORZ_THIRDPARTY}/v2m_headers/v2m
        ${ORZ_THIRDPARTY}/ahx2play ${ORZ_THIRDPARTY}/uade_combined/include
        ${ORZ_THIRDPARTY}/uade_combined ${ORZ_THIRDPARTY}/uade_combined/frontends/include)
    target_compile_definitions(OrzAudioCore PRIVATE ORZ_HAVE_OPENMPT ORZ_HAVE_GME)
    foreach(dependency openmpt gme sidplayfp adplug binio asap sc68 v2m ahx2play)
        find_library(ORZ_${dependency}_LIB NAMES ${dependency} PATHS ${ORZ_NATIVE_LIB} NO_DEFAULT_PATH REQUIRED)
        target_link_libraries(OrzAudioCore PRIVATE ${ORZ_${dependency}_LIB})
    endforeach()
endif()

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)
install(TARGETS OrzAudioCore EXPORT OrzAudioCoreTargets
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES ${ORZ_SOURCE}/include/orz_audio_core.h DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT OrzAudioCoreTargets NAMESPACE OrzAudioCore:: DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/OrzAudioCore)
configure_package_config_file(cmake/OrzAudioCoreConfig.cmake.in
    ${CMAKE_CURRENT_BINARY_DIR}/OrzAudioCoreConfig.cmake
    INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/OrzAudioCore)
write_basic_package_version_file(${CMAKE_CURRENT_BINARY_DIR}/OrzAudioCoreConfigVersion.cmake
    VERSION ${PROJECT_VERSION} COMPATIBILITY SameMajorVersion)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/OrzAudioCoreConfig.cmake
              ${CMAKE_CURRENT_BINARY_DIR}/OrzAudioCoreConfigVersion.cmake
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/OrzAudioCore)
configure_file(cmake/orz-audio-core.pc.in ${CMAKE_CURRENT_BINARY_DIR}/orz-audio-core.pc @ONLY)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/orz-audio-core.pc DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig)

if(ORZ_BUILD_TESTS)
    enable_testing()
    add_executable(orz_abi_consumer Tests/SDK/abi_consumer.c)
    target_link_libraries(orz_abi_consumer PRIVATE OrzAudioCore::OrzAudioCore)
    add_test(NAME orz_abi_consumer COMMAND orz_abi_consumer)
    add_executable(orz_abi_cpp_consumer Tests/SDK/abi_consumer.cpp)
    target_link_libraries(orz_abi_cpp_consumer PRIVATE OrzAudioCore::OrzAudioCore)
    add_test(NAME orz_abi_cpp_consumer COMMAND orz_abi_cpp_consumer)
    add_executable(orz_parallel_conformance Tests/SDK/parallel_conformance.c)
    target_link_libraries(orz_parallel_conformance PRIVATE OrzAudioCore::OrzAudioCore)
    add_test(NAME orz_parallel_conformance COMMAND orz_parallel_conformance)
endif()
