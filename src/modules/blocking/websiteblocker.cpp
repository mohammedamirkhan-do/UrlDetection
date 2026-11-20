#include "websiteblocker.h"

#include <QCoreApplication>
#include <QCheckBox>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>
#include <QVBoxLayout>

static QString blockConfigPath()
{
    // Use the editable project config during development; installed apps get a writable copy.
    QDir directory(QCoreApplication::applicationDirPath());
    for (int i = 0; i < 6; ++i) {
        const auto candidate = directory.filePath("config/blocked-websites.json");
        if (QFileInfo::exists(candidate))
            return candidate;
        if (!directory.cdUp())
            break;
    }
    const auto folder = QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation);
    QDir().mkpath(folder);
    const auto path = folder + "/blocked-websites.json";
    if (!QFileInfo::exists(path) && QFile::copy(":/config/blocked-websites.json", path))
        QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    return path;
}

WebsiteBlocker::WebsiteBlocker(QWidget *parent) : QWidget(parent)
{
    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    auto *buttons = new QHBoxLayout;
    auto *edit = new QPushButton("Open website block list");
    enabled = new QCheckBox("Close blocked website tabs while monitoring");
    enabled->setToolTip("Closes matching foreground browser tabs after detection. Accessibility or browser Automation permission is required. Pages may start loading before closure.");
    buttons->addWidget(edit);
    buttons->addWidget(enabled);
    buttons->addStretch();
    layout->addLayout(buttons);
    status = new QLabel;
    status->setWordWrap(true);
    status->setTextFormat(Qt::PlainText);
    layout->addWidget(status);
    watcher = new QFileSystemWatcher(this);
    reloadTimer = new QTimer(this);
    reloadTimer->setSingleShot(true);
    reloadTimer->setInterval(400);
    configPath = blockConfigPath();
    edit->setToolTip(configPath);
    watcher->addPath(QFileInfo(configPath).absolutePath());
    connect(edit, &QPushButton::clicked, this, [this] {
        if (!QDesktopServices::openUrl(QUrl::fromLocalFile(configPath)))
            status->setText("Could not open the block list: " + configPath);
    });
    connect(enabled, &QCheckBox::toggled, this, [this](bool checked) {
        if (checked)
            reload();
        if (checked && !configError.isEmpty()) {
            enabled->setChecked(false);
            return;
        }
        updateStatus();
        emit policyChanged();
    });
    connect(watcher, &QFileSystemWatcher::fileChanged, reloadTimer, [this] { reloadTimer->start(); });
    connect(watcher, &QFileSystemWatcher::directoryChanged, reloadTimer, [this] { reloadTimer->start(); });
    connect(reloadTimer, &QTimer::timeout, this, &WebsiteBlocker::reload);
    reload();
#ifndef Q_OS_MACOS
    enabled->setEnabled(false);
    status->setText("Browser tab closing is implemented for macOS only.");
#endif
}

QStringList WebsiteBlocker::activeDomains() const
{
    return enabled->isChecked() ? domains : QStringList{};
}

void WebsiteBlocker::reload()
{
    if (QFileInfo::exists(configPath) && !watcher->files().contains(configPath))
        watcher->addPath(configPath);
    const auto previous = domains;
    QFile file(configPath);
    if (!file.open(QIODevice::ReadOnly)) {
        configError = "Could not read block list: " + configPath;
    } else {
        const auto loaded = configuredBlockedDomains(file.read(256 * 1024 + 1), &configError);
        if (configError.isEmpty())
            domains = loaded;
    }
    updateStatus();
    if (previous != domains)
        emit policyChanged();
}

void WebsiteBlocker::updateStatus()
{
    if (!configError.isEmpty())
        status->setText(configError + (enabled->isChecked() ? " The last valid block list remains active." : " Tab closing is off."));
    else
        status->setText(QString::number(domains.size()) + " domains configured (including subdomains). "
            + (enabled->isChecked() ? "Start monitoring to close matching browser tabs after detection. No administrator access is used."
                                    : "Tab closing is off. Enable it and start monitoring to enforce the list."));
}

void WebsiteBlocker::reportResult(const QString &application, const QString &url, bool closeRequested, const QString &error)
{
    if (!enabled->isChecked())
        return;
    if (!error.isEmpty())
        status->setText(application + ": " + error);
    else if (closeRequested)
        status->setText(application + ": requested closing blocked tab " + url);
    if (!configError.isEmpty())
        status->setText(configError + " The last valid block list remains active. " + status->text());
}
