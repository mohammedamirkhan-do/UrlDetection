#include "mainwindow.h"
#include "activitytrigger.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDesktopServices>
#include <QHeaderView>
#include <QHBoxLayout>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QLineEdit>
#include <QProcess>
#include <QPushButton>
#include <QTableWidget>
#include <QTimer>
#include <QUrl>
#include <QVBoxLayout>

MainWindow::MainWindow(QWidget *parent)
    : QMainWindow(parent)
{
    setWindowTitle("Application URL Detection");
    resize(1000, 620);
    auto *content = new QWidget(this);
    auto *layout = new QVBoxLayout(content);
    auto *description = new QLabel(
        "Detect URLs and window titles on application, focus and accessibility changes.\n"
        "Enable Accessibility for general apps. Browsers also use Automation. macOS only.");
    description->setWordWrap(true);
    layout->addWidget(description);

    auto *buttons = new QHBoxLayout;
    toggle = new QPushButton("Start monitoring");
    auto *retry = new QPushButton("Retry permissions");
    auto *clear = new QPushButton("Clear history");
    auto *accessibility = new QPushButton("Accessibility settings");
    buttons->addWidget(toggle);
    buttons->addWidget(retry);
    buttons->addWidget(accessibility);
    buttons->addWidget(clear);
    buttons->addStretch();
    layout->addLayout(buttons);
    status = new QLabel("Stopped. Start monitoring, then switch to an application. macOS may request permission.");
    status->setWordWrap(true);
    status->setTextFormat(Qt::PlainText);
    layout->addWidget(status);
    layout->addWidget(new QLabel("Application"));
    application = new QLineEdit;
    application->setReadOnly(true);
    layout->addWidget(application);
    layout->addWidget(new QLabel("Full URL (empty when unavailable; select to copy)"));
    currentUrl = new QLineEdit;
    currentUrl->setReadOnly(true);
    layout->addWidget(currentUrl);
    layout->addWidget(new QLabel("Window title / active document"));
    windowTitle = new QLineEdit;
    windowTitle->setReadOnly(true);
    layout->addWidget(windowTitle);
    layout->addWidget(new QLabel("Recent activity — up to 1,000 entries, kept only in memory"));
    history = new QTableWidget(0, 4);
    history->setHorizontalHeaderLabels({"Detected at", "Application", "Full URL", "Window title / document"});
    history->horizontalHeader()->setSectionResizeMode(0, QHeaderView::ResizeToContents);
    history->horizontalHeader()->setSectionResizeMode(1, QHeaderView::ResizeToContents);
    history->horizontalHeader()->setSectionResizeMode(2, QHeaderView::Stretch);
    history->horizontalHeader()->setSectionResizeMode(3, QHeaderView::Stretch);
    history->setEditTriggers(QAbstractItemView::NoEditTriggers);
    history->setSelectionBehavior(QAbstractItemView::SelectRows);
    history->setWordWrap(false);
    layout->addWidget(history);
    setCentralWidget(content);

    trigger = new ActivityTrigger(this);
    retryTimer = new QTimer(this);
    retryTimer->setSingleShot(true);
    retryTimer->setInterval(500);
    timeout = new QTimer(this);
    timeout->setSingleShot(true);
    probe = new QProcess(this);
    connect(trigger, &ActivityTrigger::checkRequested, this, [this] {
        remainingRetries = 2;
        retryTimer->stop();
        pollBrowser();
    });
    connect(retryTimer, &QTimer::timeout, this, &MainWindow::pollBrowser);
    connect(toggle, &QPushButton::clicked, this, [this] { setMonitoring(!monitoring); });
    connect(accessibility, &QPushButton::clicked, this, [this] {
        accessibilityAccess(true);
        status->setText("Enable UrlDetection in the access list. If absent, click + and select the built UrlDetection.app, then click Retry permissions.");
        QDesktopServices::openUrl(QUrl("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"));
    });
    connect(retry, &QPushButton::clicked, this, [this] {
        accessibilityAccess(true);
        browserErrors.clear();
        if (monitoring) {
            status->setText("Permissions will be retried when you return to the application.");
            trigger->requestCheck();
        }
    });
    connect(clear, &QPushButton::clicked, this, [this] {
        history->setRowCount(0);
        application->clear();
        currentUrl->clear();
        windowTitle->clear();
        lastId.clear();
        lastUrl.clear();
        lastTitle.clear();
    });
    connect(probe, &QProcess::finished, this, [this](int code, QProcess::ExitStatus) {
        finishSample(code);
        if (refreshPending && monitoring) {
            refreshPending = false;
            trigger->requestCheck();
        }
    });
    connect(probe, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) {
            timeout->stop();
            const QString message = "Unable to start the application reader: " + probe->errorString();
            browserErrors.insert(pending.id, message);
            status->setText(message);
        }
    });
    connect(timeout, &QTimer::timeout, this, [this] {
        const QString message = "Application request timed out. Check macOS permissions, then click Retry permissions.";
        browserErrors.insert(pending.id, message);
        status->setText(message);
        probe->kill();
    });
#ifndef Q_OS_MACOS
    toggle->setEnabled(false);
    retry->setEnabled(false);
    accessibility->setEnabled(false);
    status->setText("Application detection is currently implemented for macOS only.");
#endif
}

void MainWindow::setMonitoring(bool enabled)
{
    monitoring = enabled;
    toggle->setText(enabled ? "Stop monitoring" : "Start monitoring");
    lastId.clear();
    lastUrl.clear();
    lastTitle.clear();
    if (enabled) {
        // Request from the visible app, not from a short-lived reader process.
        accessibilityAccess(true);
        browserErrors.clear();
        trigger->start();
    } else {
        trigger->stop();
        retryTimer->stop();
        refreshPending = false;
        timeout->stop();
        discardSample = true;
        probe->kill();
        status->setText("Stopped. Previously detected URLs remain below until cleared or the app closes.");
    }
}

void MainWindow::pollBrowser()
{
    if (!monitoring)
        return;
    if (probe->state() != QProcess::NotRunning) {
        refreshPending = true;
        return;
    }
    refreshPending = false;
    const auto app = foregroundApplication();
    if (app.id.isEmpty() || app.id == "com.urldetection.desktop") {
        status->setText("Waiting for another application in the foreground. Fields below show the last detection.");
        return;
    }
    application->setText(app.name);
    if (app.id != lastId) {
        currentUrl->clear();
        windowTitle->clear();
    }
    if (browserErrors.contains(app.id)) {
        status->setText(app.name + ": " + browserErrors.value(app.id));
        return;
    }
    pending = app;
    discardSample = false;
    status->setText("Reading " + app.name + "… Allow macOS access if prompted.");
    probe->start(QCoreApplication::applicationFilePath(), {"--read-browser-url", app.id});
    timeout->start(15000);
}

void MainWindow::finishSample(int exitCode)
{
    timeout->stop();
    const QByteArray output = probe->readAllStandardOutput();
    probe->readAllStandardError();
    if (!monitoring || discardSample || browserErrors.contains(pending.id))
        return;
    if (foregroundApplication().id != pending.id)
        return;
    QJsonParseError parseError;
    const auto document = QJsonDocument::fromJson(output, &parseError);
    if (exitCode != 0 || parseError.error != QJsonParseError::NoError || !document.isObject()) {
        const QString message = "Application reader failed. Click Retry permissions to try again.";
        browserErrors.insert(pending.id, message);
        status->setText(message);
        return;
    }
    const auto result = document.object();
    const QString error = result.value("error").toString();
    if (!error.isEmpty()) {
        browserErrors.insert(pending.id, error);
        status->setText(pending.name + ": " + error);
        return;
    }
    const QString rawUrl = result.value("url").toString();
    const QString url = isFullUrl(rawUrl) ? rawUrl : QString();
    const QString title = result.value("title").toString();
    // Browser titles can arrive before their URLs while the page is loading.
    if (!BrowserResult{url, {}, title}.canRecordActivity(pending.id)) {
        status->setText(pending.name + (isSupportedBrowser(pending.id)
            ? ": waiting for the active tab URL; retrying without adding activity."
            : ": no URL or window title available; retrying without adding activity."));
        if (remainingRetries > 0) {
            --remainingRetries;
            retryTimer->start();
        }
        return;
    }
    status->setText(url.isEmpty()
        ? pending.name + ": no URL exposed; showing the window title."
        : "Monitoring " + pending.name + " — event triggers with a 10-second fallback.");
    application->setText(pending.name);
    currentUrl->setText(url);
    currentUrl->setCursorPosition(0);
    windowTitle->setText(title);
    windowTitle->setCursorPosition(0);
    if (lastId == pending.id && lastUrl == url && lastTitle == title)
        return;
    lastId = pending.id;
    lastUrl = url;
    lastTitle = title;
    history->insertRow(0);
    const QStringList values{QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss"), pending.name, url, title};
    for (int column = 0; column < values.size(); ++column) {
        auto *item = new QTableWidgetItem(values[column]);
        item->setToolTip(values[column]);
        history->setItem(0, column, item);
    }
    if (history->rowCount() > 1000)
        history->removeRow(1000);
}

MainWindow::~MainWindow()
{
    trigger->stop();
    probe->kill();
    probe->waitForFinished(1000);
}
