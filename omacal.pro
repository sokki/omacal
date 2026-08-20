QT += core gui qml quick quickcontrols2 dbus

CONFIG += c++17 release link_pkgconfig
PKGCONFIG += libecal-2.0
TARGET = omacal
TEMPLATE = app

HEADERS += \
    src/backend.h \
    src/calendarstore.h \
    src/systemtheme.h

SOURCES += \
    src/main.cpp \
    src/backend.cpp \
    src/calendarstore.cpp \
    src/systemtheme.cpp

RESOURCES += src/resources.qrc
