#include "mainwindow.h"
#include "uploads/uploadmonitor.h"
#include <QTabWidget>
#include "detection/activitytrigger.h"
#include "blocking/websiteblocker.h"

#include <QCoreApplication>
#include <QCheckBox>
#include <QDateTime>
#include <QDesktopServices>
#include <QHeaderView>
#include <QHBoxLayout>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
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
        "Enable Accessibility. Existing browser Automation grants are used; new prompts are optional. macOS only.");
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
    automationPrompts = new QCheckBox("Allow browser Automation permission prompts");
    automationPrompts->setToolTip("Off: use Accessibility or an existing browser grant. On: macOS may ask permission to read a browser through Automation.");
    layout->addWidget(automationPrompts);
    websiteBlocker = new WebsiteBlocker(content);
    layout->addWidget(websiteBlocker);
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
    auto *tabs = new QTabWidget;
    tabs->addTab(history, "Application activity");
    uploads = new UploadMonitor;
    tabs->addTab(uploads, "File attachment attempts");
    layout->addWidget(tabs);
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
    connect(automationPrompts, &QCheckBox::toggled, this, [this] {
        browserErrors.clear();
        if (monitoring)
            trigger->requestCheck();
    });
    connect(websiteBlocker, &WebsiteBlocker::policyChanged, this, [this] {
        if (probe->state() != QProcess::NotRunning) {
            discardSample = true;
            probe->kill();
        }
        if (monitoring)
            trigger->requestCheck();
    });
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
        uploads->clearHistory();
        application->clear();
        currentUrl->clear();
        windowTitle->clear();
        lastId.clear();
        lastUrl.clear();
        lastTitle.clear();
        titleWait.invalidate();
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
            status->setText(message);
            retryReader();
        }
    });
    connect(timeout, &QTimer::timeout, this, [this] {
        const QString message = "Application request timed out. It will be retried automatically.";
        status->setText(message);
        discardSample = true;
        probe->kill();
        retryReader();
    });
#ifndef Q_OS_MACOS
    toggle->setEnabled(false);
    retry->setEnabled(false);
    accessibility->setEnabled(false);
    automationPrompts->setEnabled(false);
    status->setText("Application detection is currently implemented for macOS only.");
#endif
}

void MainWindow::setMonitoring(bool enabled)
{
    monitoring = enabled;
    uploads->setMonitoring(enabled);
    toggle->setText(enabled ? "Stop monitoring" : "Start monitoring");
    lastId.clear();
    lastUrl.clear();
    lastTitle.clear();
    titleWait.invalidate();
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
    status->setText("Reading " + app.name + "…");
    QStringList arguments{"--read-browser-url", app.id};
    if (automationPrompts->isChecked())
        arguments.append("--allow-automation-prompt");
    const auto blockedDomains = websiteBlocker->activeDomains();
    if (!blockedDomains.isEmpty())
        arguments << "--blocked-domains" << QString::fromLatin1(
            QJsonDocument(QJsonArray::fromStringList(blockedDomains)).toJson(QJsonDocument::Compact).toBase64());
    probe->start(QCoreApplication::applicationFilePath(), arguments);
    timeout->start(15000);
}

void MainWindow::retryReader()
{
    if (monitoring && remainingRetries > 0) {
        --remainingRetries;
        retryTimer->start();
    }
}

void MainWindow::finishSample(int exitCode)
{
    timeout->stop();
    const QByteArray output = probe->readAllStandardOutput();
    probe->readAllStandardError();
    if (!monitoring || discardSample || browserErrors.contains(pending.id))
        return;
    QJsonParseError parseError;
    const auto document = QJsonDocument::fromJson(output, &parseError);
    if (exitCode != 0 || parseError.error != QJsonParseError::NoError || !document.isObject()) {
        const QString message = "Application reader failed. It will be retried automatically.";
        status->setText(message);
        retryReader();
        return;
    }
    const auto result = document.object();
    const bool closeRequested = result.value("tabCloseRequested").toBool();
    websiteBlocker->reportResult(pending.name, result.value("url").toString(), closeRequested,
                                result.value("tabCloseError").toString());
    if (closeRequested && monitoring)
        trigger->requestCheck();
    if (foregroundApplication().id != pending.id)
        return;
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
    displayActivity(url, title);
}

void MainWindow::displayActivity(const QString &url, const QString &title)
{
    const bool browser = isSupportedBrowser(pending.id);
    application->setText(pending.name);
    currentUrl->setText(url);
    currentUrl->setCursorPosition(0);
    windowTitle->setText(title);
    windowTitle->setCursorPosition(0);

    if (browser && title.trimmed().isEmpty()) {
        if (lastId == pending.id && lastUrl == url && !lastTitle.trimmed().isEmpty()) {
            windowTitle->setText(lastTitle);
            status->setText("Monitoring " + pending.name + " — retaining the last available title for this URL.");
            return;
        }
        if (!titleWait.isValid() || titleWaitId != pending.id || titleWaitUrl != url) {
            titleWaitId = pending.id;
            titleWaitUrl = url;
            titleWait.start();
        }
        // Allow redirects/title metadata to settle without losing genuinely untitled pages.
        if (titleWait.elapsed() < 1500) {
            status->setText(pending.name + ": URL detected; waiting briefly for the page title.");
            retryTimer->start(500);
            return;
        }
    } else {
        titleWait.invalidate();
    }
    retryTimer->stop();
    status->setText(url.isEmpty()
        ? pending.name + ": no URL exposed; showing the window title."
        : "Monitoring " + pending.name + " — event triggers with a 10-second fallback.");
    if (lastId == pending.id && lastUrl == url && lastTitle == title)
        return;
    if (browser && lastId == pending.id && lastUrl == url && history->rowCount() > 0) {
        lastTitle = title;
        history->item(0, 3)->setText(title);
        history->item(0, 3)->setToolTip(title);
        return;
    }
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
    uploads->setMonitoring(false);
    trigger->stop();
    probe->kill();
    probe->waitForFinished(1000);
}
