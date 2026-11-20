#pragma once

#include <QWidget>
#include "websitepolicy.h"

class QLabel;
class QCheckBox;
class QFileSystemWatcher;
class QTimer;

class WebsiteBlocker : public QWidget
{
    Q_OBJECT
public:
    explicit WebsiteBlocker(QWidget *parent = nullptr);
    QStringList activeDomains() const;
    void reportResult(const QString &application, const QString &url, bool closeRequested, const QString &error);

signals:
    void policyChanged();

private:
    void reload();
    void updateStatus();

    QString configPath;
    QString configError;
    QStringList domains;
    QLabel *status;
    QCheckBox *enabled;
    QFileSystemWatcher *watcher;
    QTimer *reloadTimer;
};
