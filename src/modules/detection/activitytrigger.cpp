#include "activitytrigger.h"

ActivityTrigger::ActivityTrigger(QObject *parent, bool nativeObserverMode)
    : QObject(parent), nativeObserverMode(nativeObserverMode)
{
    debounce.setSingleShot(true);
    debounce.setInterval(150);
    fallback.setInterval(10000);
    connect(&debounce, &QTimer::timeout, this, [this] {
        if (this->nativeObserverMode)
            refreshNative();
        emit checkRequested();
    });
    connect(&fallback, &QTimer::timeout, this, &ActivityTrigger::requestCheck);
    connect(&observerProcess, &WorkerProcess::messageReceived, this, [this](const QByteArray &line) {
        if (line == "changed")
            requestCheck();
    });
}

ActivityTrigger::~ActivityTrigger() { stop(); }

void ActivityTrigger::start()
{
    if (active)
        return;
    active = true;
    if (nativeObserverMode) {
        startNative();
    } else {
#ifdef Q_OS_MACOS
        observerProcess.start();
#endif
        fallback.start();
    }
    requestCheck();
}

void ActivityTrigger::stop()
{
    active = false;
    debounce.stop();
    fallback.stop();
    observerProcess.stop();
    if (nativeObserverMode)
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
