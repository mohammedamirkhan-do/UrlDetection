#pragma once

#include <QObject>
#include <QTimer>
#include "core/workerprocess.h"

class ActivityTrigger : public QObject
{
    Q_OBJECT
public:
    explicit ActivityTrigger(QObject *parent = nullptr, bool nativeObserverMode = false);
    ~ActivityTrigger() override;
    void start();
    void stop();
    void requestCheck();

signals:
    void checkRequested();

private:
    void startNative();
    void stopNative();
    void refreshNative();
    QTimer debounce;
    QTimer fallback;
    WorkerProcess observerProcess{"--watch-activity"};
    bool nativeObserverMode;
    bool active = false;
    void *nativeState = nullptr;
};
