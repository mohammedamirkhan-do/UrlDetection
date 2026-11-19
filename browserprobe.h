#pragma once

#include <QString>

struct BrowserApplication {
    QString id;
    QString name;
};

struct BrowserResult {
    QString url;
    QString error;
    QString title;

    bool canRecordActivity(const QString &applicationId) const;
};

BrowserApplication foregroundApplication();
bool configureApplicationActivation(bool background);
bool accessibilityAccess(bool prompt = false);
bool isSupportedBrowser(const QString &id);
bool isFullUrl(const QString &value);
QString accessibleAddressUrl(const QString &role, const QString &identity,
                             const QString &value, bool inToolbar);
BrowserResult readBrowserUrl(const QString &id);
