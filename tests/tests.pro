QT += core gui testlib dbus
CONFIG += testcase c++17 link_pkgconfig
PKGCONFIG += libecal-2.0
TEMPLATE = app
TARGET = tst_omacal

INCLUDEPATH += ../src
SOURCES += \
    tst_omacal.cpp \
    ../src/backend.cpp \
    ../src/calendarstore.cpp
HEADERS += \
    ../src/backend.h \
    ../src/calendarstore.h
