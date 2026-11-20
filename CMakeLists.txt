cmake_minimum_required(VERSION 3.19)
if(CMAKE_HOST_APPLE AND NOT CMAKE_OSX_DEPLOYMENT_TARGET AND "$ENV{MACOSX_DEPLOYMENT_TARGET}" STREQUAL "")
    # Use an explicit deployment baseline instead of silently targeting the build Mac's current OS.
    set(CMAKE_OSX_DEPLOYMENT_TARGET "14.4" CACHE STRING "Minimum macOS version (must also be supported by Qt)" FORCE)
endif()
project(UrlDetection LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Widgets)

qt_standard_project_setup()

qt_add_executable(UrlDetection
    WIN32 MACOSX_BUNDLE
    src/app/main.cpp
    src/app/mainwindow.cpp
    src/app/mainwindow.h
    src/modules/detection/browserprobe.cpp
    src/modules/detection/browserprobe.h
    src/modules/detection/activitytrigger.cpp
    src/modules/detection/activitytrigger.h
    src/modules/blocking/websiteblocker.cpp
    src/modules/blocking/websiteblocker.h
    src/modules/blocking/websitepolicy.cpp
    src/modules/blocking/websitepolicy.h
    src/modules/blocking/tabcloser.cpp
    src/modules/blocking/tabcloser.h
)
target_include_directories(UrlDetection PRIVATE src/modules)

qt_add_resources(UrlDetection "website_block_defaults"
    PREFIX "/"
    FILES config/blocked-websites.json
)

if(APPLE)
    enable_language(OBJCXX)
    target_sources(UrlDetection PRIVATE
        src/platform/mac/browserintegration.mm
        src/platform/mac/activityobserver.mm
        src/platform/mac/macprocess.h
    )
    target_link_libraries(UrlDetection PRIVATE "-framework AppKit" "-framework ApplicationServices" "-framework CoreServices")
    set_target_properties(UrlDetection PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/resources/macos/Info.plist.in")
endif()

get_target_property(project_sources UrlDetection SOURCES)
list(FILTER project_sources INCLUDE REGEX "^src/")
source_group(TREE "${CMAKE_CURRENT_SOURCE_DIR}/src" PREFIX "Source" FILES ${project_sources})

target_link_libraries(UrlDetection
    PRIVATE
        Qt::Core
        Qt::Widgets
)

install(TARGETS UrlDetection
    BUNDLE  DESTINATION .
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
)

set(deploy_options)
if(APPLE AND Qt6_VERSION VERSION_GREATER_EQUAL "6.7"
        AND TARGET Qt6::QCocoaIntegrationPlugin AND TARGET Qt6::QMacStylePlugin)
    # This Widgets app needs Cocoa and the native style, not every optional plugin in the Qt installation.
    install(FILES "$<TARGET_FILE:Qt6::QCocoaIntegrationPlugin>"
        DESTINATION "UrlDetection.app/Contents/PlugIns/platforms")
    install(FILES "$<TARGET_FILE:Qt6::QMacStylePlugin>"
        DESTINATION "UrlDetection.app/Contents/PlugIns/styles")
    set(deploy_options DEPLOY_TOOL_OPTIONS
        "-no-plugins"
        "-executable=UrlDetection.app/Contents/PlugIns/platforms/$<TARGET_FILE_NAME:Qt6::QCocoaIntegrationPlugin>"
        "-executable=UrlDetection.app/Contents/PlugIns/styles/$<TARGET_FILE_NAME:Qt6::QMacStylePlugin>"
    )
endif()

qt_generate_deploy_app_script(
    TARGET UrlDetection
    OUTPUT_SCRIPT deploy_script
    NO_UNSUPPORTED_PLATFORM_ERROR
    ${deploy_options}
)
install(SCRIPT ${deploy_script})
