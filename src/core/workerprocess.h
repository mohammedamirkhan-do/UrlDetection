#pragma once
#include <QObject>
#include <QProcess>
#include <QTimer>
#include <QElapsedTimer>

// Owns one framed-stdout worker, shared by observation features. No native IPC runs here.
class WorkerProcess : public QObject
{
    Q_OBJECT
public:
    explicit WorkerProcess(const QString &argument, QObject *parent = nullptr);
    ~WorkerProcess() override;
    void start();
    void stop();
signals:
    void messageReceived(const QByteArray &line);
    void available();
    void unavailable(const QString &message);
private:
    void launch();
    QString argument;
    QProcess process;
    QTimer restart;
    QTimer watchdog;
    QElapsedTimer lastAlive;
    QByteArray output;
    int restartDelay = 1000;
    bool active = false;
    bool announced = false;
};
