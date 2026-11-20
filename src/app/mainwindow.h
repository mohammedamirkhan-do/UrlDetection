#ifndef MAINWINDOW_H
#define MAINWINDOW_H

#include <QMainWindow>
#include <QHash>
#include <QElapsedTimer>
#include "detection/browserprobe.h"

class QLabel;
class QLineEdit;
class QPushButton;
class QTableWidget;
class QTimer;
class QProcess;
class ActivityTrigger;
class QCheckBox;
class WebsiteBlocker;

class MainWindow : public QMainWindow
{
    Q_OBJECT

public:
    explicit MainWindow(QWidget *parent = nullptr);
    ~MainWindow() override;

private:
    void pollBrowser();
    void finishSample(int exitCode);
    void retryReader();
    void displayActivity(const QString &url, const QString &title);
    void setMonitoring(bool enabled);

    QLabel *status;
    QLineEdit *application;
    QLineEdit *currentUrl;
    QLineEdit *windowTitle;
    QPushButton *toggle;
    QCheckBox *automationPrompts;
    WebsiteBlocker *websiteBlocker;
    QTableWidget *history;
    ActivityTrigger *trigger;
    QTimer *retryTimer;
    QTimer *timeout;
    QProcess *probe;
    BrowserApplication pending;
    QHash<QString, QString> browserErrors;
    QString lastId;
    QString lastUrl;
    QString lastTitle;
    QString titleWaitId;
    QString titleWaitUrl;
    QElapsedTimer titleWait;
    bool monitoring = false;
    bool discardSample = false;
    bool refreshPending = false;
    int remainingRetries = 0;
};
#endif // MAINWINDOW_H
