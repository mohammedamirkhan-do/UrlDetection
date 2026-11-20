#include "tabcloser.h"
#include "detection/browserprobe.h"

QString browserCloseTabScript(const QString &id, const QString &expectedUrl)
{
    const auto reader = browserReader(id);
    if ((reader != BrowserReader::Safari && reader != BrowserReader::Chromium) || !isFullUrl(expectedUrl))
        return {};
    QString quoted = expectedUrl;
    quoted.replace("\\", "\\\\").replace("\"", "\\\"").replace('\n', "\\n").replace('\r', "\\r");
    return "with timeout of 3 seconds\ntell application id \"" + id
        + "\"\nif (count of windows) is 0 then return false\nset selectedTab to "
        + (reader == BrowserReader::Safari ? "current tab" : "active tab")
        + " of front window\nif URL of selectedTab is not \"" + quoted
        + "\" then return false\nclose selectedTab\nreturn true\nend tell\nend timeout";
}

#ifndef Q_OS_MACOS
QString requestCloseBrowserTab(const QString &, const QString &, bool)
{
    return "Browser tab closing is implemented for macOS only.";
}
#endif
