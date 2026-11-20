#include "workerprocess.h"
#include <QCoreApplication>
#include <algorithm>

WorkerProcess::WorkerProcess(const QString &argument, QObject *parent)
    : QObject(parent), argument(argument)
{
    restart.setSingleShot(true);
    watchdog.setInterval(5000);
    connect(&restart, &QTimer::timeout, this, &WorkerProcess::launch);
    connect(&watchdog, &QTimer::timeout, this, [this] {
        if (active && lastAlive.isValid() && lastAlive.elapsed() > 15000) {
            emit unavailable("Capture worker stalled; restarting. Activity during the interruption may be missed.");
            process.kill();
        }
    });
    connect(&process, &QProcess::readyReadStandardOutput, this, [this] {
        const auto incoming = process.readAllStandardOutput();
        if (!active) { output.clear(); return; }
        output += incoming;
        int newline;
        while ((newline = output.indexOf('\n')) >= 0) {
            const auto line = output.left(newline);
            output.remove(0, newline + 1);
            if (line.size() > 512 * 1024) {
                emit unavailable("A capture event exceeded the size limit and was discarded.");
                continue;
            }
            if (line == "alive" || line == "changed" || line.startsWith('{')) {
                lastAlive.restart();
                restartDelay = 1000;
                if (!announced) {
                    announced = true;
                    emit available();
                }
                if (line != "alive")
                    emit messageReceived(line);
            }
        }
        if (output.size() > 512 * 1024) {
            output.clear();
            emit unavailable("Invalid capture-worker output was discarded.");
        }
    });
    connect(&process, &QProcess::readyReadStandardError, this, [this] { process.readAllStandardError(); });
    const auto retry = [this] {
        watchdog.stop();
        if (active) {
            emit unavailable("Capture worker stopped; restarting. Activity during the interruption may be missed.");
            restart.start(restartDelay);
            restartDelay = std::min(restartDelay * 2, 30000);
        }
    };
    connect(&process, &QProcess::finished, this, [retry](int, QProcess::ExitStatus) { retry(); });
    connect(&process, &QProcess::errorOccurred, this, [retry](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            retry();
    });
}

WorkerProcess::~WorkerProcess()
{
    stop();
    if (process.state() != QProcess::NotRunning)
        process.waitForFinished(100);
}

void WorkerProcess::launch()
{
    if (!active || process.state() != QProcess::NotRunning)
        return;
    output.clear();
    announced = false;
    lastAlive.start();
    process.start(QCoreApplication::applicationFilePath(), {argument});
    watchdog.start();
}

void WorkerProcess::start()
{
    if (active)
        return;
    active = true;
    restartDelay = 1000;
    launch();
}

void WorkerProcess::stop()
{
    active = false;
    restart.stop();
    watchdog.stop();
    process.kill();
}
