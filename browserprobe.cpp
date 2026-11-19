#include "browserprobe.h"

#include <QUrl>

bool isSupportedBrowser(const QString &id)
{
    return id == "com.apple.Safari" || id == "com.apple.SafariTechnologyPreview"
        || id == "com.google.Chrome" || id == "com.google.Chrome.beta"
        || id == "com.microsoft.edgemac" || id == "com.brave.Browser"
        || id == "com.operasoftware.Opera" || id == "com.vivaldi.Vivaldi"
        || id == "org.mozilla.firefox";
}

bool isFullUrl(const QString &value)
{
    const QUrl url(value, QUrl::StrictMode);
    if (!url.isValid() || url.scheme().isEmpty())
        return false;
    if (url.scheme() == "http" || url.scheme() == "https" || url.scheme() == "ftp")
        return !url.host().isEmpty();
    return !url.path().isEmpty() || !url.host().isEmpty();
}

bool BrowserResult::canRecordActivity(const QString &applicationId) const
{
    if (!error.isEmpty())
        return false;
    if (isSupportedBrowser(applicationId))
        return isFullUrl(url);
    return isFullUrl(url) || !title.trimmed().isEmpty();
}

QString accessibleAddressUrl(const QString &role, const QString &identity,
                             const QString &value, bool inToolbar)
{
    if (!inToolbar || (role != "AXTextField" && role != "AXComboBox"))
        return {};
    if (!identity.contains("url", Qt::CaseInsensitive)
        && !identity.contains("address", Qt::CaseInsensitive)
        && !identity.contains("location", Qt::CaseInsensitive))
        return {};
    return isFullUrl(value) ? value : QString();
}

#ifndef Q_OS_MACOS
bool accessibilityAccess(bool) { return false; }
bool configureApplicationActivation(bool) { return true; }
BrowserApplication foregroundApplication() { return {}; }
BrowserResult readBrowserUrl(const QString &)
{
    return {{}, "Application detection is currently implemented for macOS only."};
}
#endif
