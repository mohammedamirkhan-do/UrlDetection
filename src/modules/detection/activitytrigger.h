#pragma once

#include <QObject>
#include <QTimer>
#include <QProcess>
#include <QElapsedTimer>

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
    void startObserverProcess();
    QTimer debounce;
    QTimer fallback;
    QTimer restart;
    QTimer watchdog;
    QProcess observerProcess;
    QElapsedTimer lastAlive;
    QByteArray observerOutput;
    int restartDelay = 1000;
    bool nativeObserverMode;
    bool active = false;
    void *nativeState = nullptr;
};
