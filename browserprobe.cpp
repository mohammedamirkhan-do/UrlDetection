#include "browserprobe.h"

#include <QUrl>

BrowserReader browserReader(const QString &id)
{
    static const struct { const char *id; BrowserReader reader; } browsers[] = {
        {"com.apple.Safari", BrowserReader::Safari},
        {"com.apple.SafariTechnologyPreview", BrowserReader::Safari},
        {"com.google.Chrome", BrowserReader::Chromium},
        {"com.google.Chrome.beta", BrowserReader::Chromium},
        {"com.microsoft.edgemac", BrowserReader::Chromium},
        {"com.brave.Browser", BrowserReader::Chromium},
        {"com.operasoftware.Opera", BrowserReader::Chromium},
        {"com.operasoftware.OperaGX", BrowserReader::Chromium},
        {"com.vivaldi.Vivaldi", BrowserReader::Chromium},
        {"ru.yandex.desktop.yandex-browser", BrowserReader::Chromium},
        {"org.chromium.Chromium", BrowserReader::Chromium},
        {"company.thebrowser.Browser", BrowserReader::Chromium},
        {"org.mozilla.firefox", BrowserReader::BrowserAccessibility},
        {"com.duckduckgo.macos.browser", BrowserReader::BrowserAccessibility},
        {"org.torproject.torbrowser", BrowserReader::BrowserAccessibility},
        {"org.mozilla.tor browser", BrowserReader::BrowserAccessibility},
    };
    for (const auto &browser : browsers)
        if (id == QLatin1String(browser.id))
            return browser.reader;
    return BrowserReader::GenericAccessibility;
}

bool isSupportedBrowser(const QString &id)
{
    return browserReader(id) != BrowserReader::GenericAccessibility;
}

QString browserUrlScript(const QString &id)
{
    const auto reader = browserReader(id);
    if (reader != BrowserReader::Safari && reader != BrowserReader::Chromium)
        return {};
    // Bundle IDs come from the exact registry above, never arbitrary application or page text.
    const bool safari = reader == BrowserReader::Safari;
    return "with timeout of 3 seconds\ntell application id \"" + id
        + "\"\nif (count of windows) is 0 then return {\"\", \"\"}\nset selectedTab to "
        + (safari ? "current tab" : "active tab")
        + " of front window\nset detectedTitle to "
        + (safari ? "name" : "title")
        + " of selectedTab\nif detectedTitle is missing value then set detectedTitle to \"\"\n"
          "if detectedTitle is \"\" then\ntry\nset detectedTitle to name of front window\nend try\nend if\n"
          "return {URL of selectedTab, detectedTitle}\nend tell\nend timeout";
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

bool isBrowserInterfaceUrl(const QString &applicationId, const QString &value)
{
    const QUrl url(value);
    return applicationId == "com.vivaldi.Vivaldi"
        && url.scheme() == "chrome-extension"
        && url.host() == "mpognobbkildjkofajifpdfhcoklimli"
        && (url.path() == "/window.html" || url.path() == "/browser.html");
}

bool BrowserResult::canRecordActivity(const QString &applicationId) const
{
    if (!error.isEmpty())
        return false;
    if (isSupportedBrowser(applicationId))
        return isFullUrl(url) && !isBrowserInterfaceUrl(applicationId, url);
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
BrowserResult readBrowserUrl(const QString &, bool)
{
    return {{}, "Application detection is currently implemented for macOS only."};
}
#endif
