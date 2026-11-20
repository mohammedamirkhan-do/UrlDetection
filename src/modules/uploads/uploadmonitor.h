#pragma once
#include <QWidget>
#include <QSet>
#include <QQueue>
#include "core/workerprocess.h"
class QLabel;
class QCheckBox;
class QTableWidget;

class UploadMonitor : public QWidget
{
    Q_OBJECT
public:
    explicit UploadMonitor(QWidget *parent = nullptr);
    void setMonitoring(bool value);
    void clearHistory();
private:
    void updateCapture();
    void receive(const QByteArray &line);
    WorkerProcess worker{"--watch-file-activity"};
    bool monitoring = false;
    QCheckBox *enabled;
    QLabel *status;
    QTableWidget *history;
    QSet<QString> seen;
    QQueue<QString> actionIds;
};
