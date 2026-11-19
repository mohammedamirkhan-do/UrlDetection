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
enum class BrowserReader { GenericAccessibility, BrowserAccessibility, Safari, Chromium };
BrowserReader browserReader(const QString &id);
QString browserUrlScript(const QString &id);
bool isSupportedBrowser(const QString &id);
bool isFullUrl(const QString &value);
bool isBrowserInterfaceUrl(const QString &applicationId, const QString &url);
QString accessibleAddressUrl(const QString &role, const QString &identity,
                             const QString &value, bool inToolbar);
BrowserResult readBrowserUrl(const QString &id, bool allowAutomationPrompt = false);
