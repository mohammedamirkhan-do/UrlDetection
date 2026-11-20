#include "fileactivity.h"
#include <QSet>
#include <QUrl>

QStringList localFileReferences(const QStringList &references, bool *truncated)
{
    if (truncated)
        *truncated = false;
    QStringList paths;
    QSet<QString> seen;
    qsizetype bytes = 0;
    for (const auto &reference : references) {
        QString path = reference;
        if (reference.startsWith("file:", Qt::CaseInsensitive)) {
            QUrl url(reference, QUrl::StrictMode);
            if (!url.isValid() || !url.isLocalFile() || url.hasQuery() || url.hasFragment() || !url.userInfo().isEmpty() || (!url.host().isEmpty() && url.host().toLower() != "localhost"))
                continue;
            url.setHost({});
            path = url.toLocalFile();
        }
        if (path.startsWith("/.file/id=") || !path.startsWith('/') || path.contains(QChar::Null) || seen.contains(path))
            continue;
        const auto size = path.toUtf8().size();
        if (paths.size() >= 100 || path.size() > 8192 || bytes + size > 64 * 1024) {
            if (truncated)
                *truncated = true;
            continue;
        }
        // Preserve the exposed path: resolving symlinks or searching by name can identify a different file.
        paths.append(path);
        seen.insert(path);
        bytes += size;
    }
    return paths;
}

#ifndef Q_OS_MACOS
bool requestFileInputPermission() { return false; }
int runFileActivityWorker(QCoreApplication &) { return 1; }
#endif
