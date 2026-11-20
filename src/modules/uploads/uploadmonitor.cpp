#include "uploadmonitor.h"
#include "fileactivity.h"
#include <QCheckBox>
#include <QDateTime>
#include <QDesktopServices>
#include <QGuiApplication>
#include <QClipboard>
#include <QHeaderView>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QPushButton>
#include <QTableWidget>
#include <QUrl>
#include <QVBoxLayout>

UploadMonitor::UploadMonitor(QWidget *parent) : QWidget(parent)
{
    auto *layout = new QVBoxLayout(this);
    auto *buttons = new QHBoxLayout;
    enabled = new QCheckBox("Detect file attachment attempts while monitoring");
    auto *permission = new QPushButton("Input Monitoring settings");
    auto *retry = new QPushButton("Retry capture");
    auto *clear = new QPushButton("Clear file history");
    buttons->addWidget(enabled);
    buttons->addWidget(permission);
    buttons->addWidget(retry);
    buttons->addWidget(clear);
    layout->addLayout(buttons);
    layout->addWidget(new QLabel("File-related gestures and file-dialog confirmations only; completed uploads are not verified. Double-click a path to copy it."));
    status = new QLabel("Off. Enable file detection and start monitoring.");
    status->setWordWrap(true);
    status->setTextFormat(Qt::PlainText);
    layout->addWidget(status);
    history = new QTableWidget(0, 5);
    history->setHorizontalHeaderLabels({"Observed at", "Application", "Method", "File path", "Evidence / limitations"});
    history->horizontalHeader()->setSectionResizeMode(0, QHeaderView::ResizeToContents);
    history->horizontalHeader()->setSectionResizeMode(1, QHeaderView::ResizeToContents);
    history->horizontalHeader()->setSectionResizeMode(2, QHeaderView::ResizeToContents);
    for (int i = 3; i < 5; ++i)
        history->horizontalHeader()->setSectionResizeMode(i, QHeaderView::Stretch);
    history->setEditTriggers(QAbstractItemView::NoEditTriggers);
    history->setSelectionBehavior(QAbstractItemView::SelectRows);
    history->setWordWrap(false);
    layout->addWidget(history);
    connect(enabled, &QCheckBox::toggled, this, [this] { updateCapture(); });
    connect(clear, &QPushButton::clicked, this, &UploadMonitor::clearHistory);
    connect(permission, &QPushButton::clicked, this, [this] {
        requestFileInputPermission();
        QDesktopServices::openUrl(QUrl("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"));
        status->setText("Enable UrlDetection in Input Monitoring if needed, then click Retry capture. Accessibility is also needed for file dialogs.");
    });
    connect(retry, &QPushButton::clicked, this, [this] { worker.stop(); updateCapture(); });
    connect(&worker, &WorkerProcess::messageReceived, this, &UploadMonitor::receive);
    connect(&worker, &WorkerProcess::available, this, [this] {
        if (monitoring && enabled->isChecked())
            status->setText("File activity worker is running; checking capture permissions.");
    });
    connect(&worker, &WorkerProcess::unavailable, this, [this](const QString &message) {
        if (monitoring && enabled->isChecked())
            status->setText(message);
    });
    connect(history, &QTableWidget::cellDoubleClicked, this, [this](int row, int column) {
        if (column == 3 && history->item(row, column)->data(Qt::UserRole).toBool())
            QGuiApplication::clipboard()->setText(history->item(row, column)->text());
    });
#ifndef Q_OS_MACOS
    enabled->setEnabled(false);
    permission->setEnabled(false);
    retry->setEnabled(false);
    status->setText("File activity detection is implemented for macOS only.");
#endif
}

void UploadMonitor::setMonitoring(bool value)
{
    monitoring = value;
    updateCapture();
}

void UploadMonitor::updateCapture()
{
    if (monitoring && enabled->isChecked()) {
        status->setText("Starting file activity capture…");
        worker.start();
    } else {
        worker.stop();
        status->setText("File capture stopped. Existing rows remain until cleared or the app closes.");
    }
}

void UploadMonitor::clearHistory()
{
    history->setRowCount(0);
    seen.clear();
    actionIds.clear();
}

void UploadMonitor::receive(const QByteArray &line)
{
    if (!monitoring || !enabled->isChecked())
        return;
    const auto document = QJsonDocument::fromJson(line);
    if (!document.isObject())
        return;
    const auto event = document.object();
    if (event.value("kind").toString() == "status") {
        status->setText(event.value("message").toString().left(2048));
        return;
    }
    const auto id = event.value("actionId").toString();
    const auto method = event.value("method").toString();
    const auto timestamp = QDateTime::fromString(event.value("timestamp").toString(), Qt::ISODateWithMs);
    if (event.value("kind").toString() != "file_activity" || id.isEmpty() || id.size() > 64 || seen.contains(id)
        || !QStringList{"dialog", "drag-drop", "paste"}.contains(method) || !timestamp.isValid() || !event.value("paths").isArray())
        return;
    QStringList references;
    for (const auto &path : event.value("paths").toArray())
        if (path.isString()) references.append(path.toString());
    const auto paths = localFileReferences(references);
    if (paths.isEmpty() && !event.value("pathUnavailable").toBool())
        return;
    seen.insert(id);
    actionIds.enqueue(id);
    while (actionIds.size() > 1000) seen.remove(actionIds.dequeue());
    QString detail = "Attempt observed; upload completion not verified. " + event.value("detail").toString().left(2048);
    if (event.value("truncated").toBool()) detail += " Some paths exceeded capture limits.";
    const auto displayPaths = paths.isEmpty() ? QStringList{"Unavailable — original path not exposed"} : paths;
    for (const auto &path : displayPaths) {
        history->insertRow(0);
        const QStringList values{timestamp.toLocalTime().toString("yyyy-MM-dd HH:mm:ss.zzz"),
            event.value("application").toString().left(256), method, path,
            detail};
        for (int column = 0; column < values.size(); ++column) {
            auto *item = new QTableWidgetItem(values[column]);
            item->setToolTip(values[column]);
            if (column == 3) item->setData(Qt::UserRole, !paths.isEmpty());
            history->setItem(0, column, item);
        }
        if (history->rowCount() > 1000) history->removeRow(1000);
    }
    status->setText("File interaction recorded. Paths are captured only when exposed; sending/acceptance is not confirmed.");
}
