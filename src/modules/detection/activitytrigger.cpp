#include "activitytrigger.h"
#include <QCoreApplication>
#include <algorithm>

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
    restart.setSingleShot(true);
    watchdog.setInterval(5000);
    connect(&restart, &QTimer::timeout, this, &ActivityTrigger::startObserverProcess);
    connect(&watchdog, &QTimer::timeout, this, [this] {
        if (active && lastAlive.isValid() && lastAlive.elapsed() > 15000)
            observerProcess.kill();
    });
    connect(&observerProcess, &QProcess::readyReadStandardOutput, this, [this] {
        observerOutput += observerProcess.readAllStandardOutput();
        bool changed = false;
        int newline;
        while ((newline = observerOutput.indexOf('\n')) >= 0) {
            const auto line = observerOutput.left(newline);
            observerOutput.remove(0, newline + 1);
            if (line == "alive" || line == "changed") {
                lastAlive.restart();
                restartDelay = 1000;
                changed = changed || line == "changed";
            }
        }
        if (observerOutput.size() > 1024)
            observerOutput.clear();
        if (changed)
            requestCheck();
    });
    connect(&observerProcess, &QProcess::readyReadStandardError, this, [this] {
        observerProcess.readAllStandardError();
    });
    const auto retry = [this] {
        watchdog.stop();
        if (active && !this->nativeObserverMode) {
            restart.start(restartDelay);
            restartDelay = std::min(restartDelay * 2, 30000);
        }
    };
    connect(&observerProcess, &QProcess::finished, this, [retry](int, QProcess::ExitStatus) { retry(); });
    connect(&observerProcess, &QProcess::errorOccurred, this, [retry](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            retry();
    });
}

ActivityTrigger::~ActivityTrigger()
{
    stop();
    if (observerProcess.state() != QProcess::NotRunning)
        observerProcess.waitForFinished(100);
}

void ActivityTrigger::startObserverProcess()
{
#ifdef Q_OS_MACOS
    if (!active || nativeObserverMode || observerProcess.state() != QProcess::NotRunning)
        return;
    observerOutput.clear();
    lastAlive.start();
    observerProcess.start(QCoreApplication::applicationFilePath(), {"--watch-activity"});
    watchdog.start();
#endif
}

void ActivityTrigger::start()
{
    if (active)
        return;
    active = true;
    if (nativeObserverMode) {
        startNative();
    } else {
        restartDelay = 1000;
        startObserverProcess();
        fallback.start();
    }
    requestCheck();
}

void ActivityTrigger::stop()
{
    active = false;
    debounce.stop();
    fallback.stop();
    restart.stop();
    watchdog.stop();
    observerProcess.kill();
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
