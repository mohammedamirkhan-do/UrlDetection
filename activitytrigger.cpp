#include "activitytrigger.h"

ActivityTrigger::ActivityTrigger(QObject *parent) : QObject(parent)
{
    debounce.setSingleShot(true);
    debounce.setInterval(150);
    fallback.setInterval(10000);
    connect(&debounce, &QTimer::timeout, this, [this] {
        refreshNative();
        emit checkRequested();
    });
    connect(&fallback, &QTimer::timeout, this, &ActivityTrigger::requestCheck);
}

ActivityTrigger::~ActivityTrigger() { stop(); }

void ActivityTrigger::start()
{
    if (active)
        return;
    active = true;
    startNative();
    fallback.start();
    requestCheck();
}

void ActivityTrigger::stop()
{
    active = false;
    debounce.stop();
    fallback.stop();
    stopNative();
}

void ActivityTrigger::requestCheck()
{
    // Coalesce bursts without allowing a busy app to postpone reads indefinitely.
    if (active && !debounce.isActive())
        debounce.start();
}

#ifndef Q_OS_MACOS
void ActivityTrigger::startNative() {}
void ActivityTrigger::stopNative() {}
void ActivityTrigger::refreshNative() {}
#endif
