cmake_minimum_required(VERSION 3.19)
project(UrlDetection LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Widgets)

qt_standard_project_setup()

qt_add_executable(UrlDetection
    WIN32 MACOSX_BUNDLE
    main.cpp
    mainwindow.cpp
    mainwindow.h
    browserprobe.cpp
    browserprobe.h
    activitytrigger.cpp
    activitytrigger.h
)

if(APPLE)
    enable_language(OBJCXX)
    target_sources(UrlDetection PRIVATE browserprobe_mac.mm activitytrigger_mac.mm)
    target_link_libraries(UrlDetection PRIVATE "-framework AppKit" "-framework ApplicationServices")
    set_target_properties(UrlDetection PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in")
endif()

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

qt_generate_deploy_app_script(
    TARGET UrlDetection
    OUTPUT_SCRIPT deploy_script
    NO_UNSUPPORTED_PLATFORM_ERROR
)
install(SCRIPT ${deploy_script})
