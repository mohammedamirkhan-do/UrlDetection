#pragma once

#include <QObject>
#include <QTimer>

class ActivityTrigger : public QObject
{
    Q_OBJECT
public:
    explicit ActivityTrigger(QObject *parent = nullptr);
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
    bool active = false;
    void *nativeState = nullptr;
};
