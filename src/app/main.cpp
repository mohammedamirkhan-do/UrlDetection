#include "blocking/tabcloser.h"
#include "detection/activitytrigger.h"
#include "mainwindow.h"
#include "uploads/fileactivity.h"
#include "detection/browserprobe.h"
#include "blocking/websitepolicy.h"

#include <QApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <cstdio>

int main(int argc, char *argv[])
{
    if (argc == 2 && (QString::fromLocal8Bit(argv[1]) == "--watch-activity" || QString::fromLocal8Bit(argv[1]) == "--watch-file-activity")) {
        QCoreApplication::setAttribute(Qt::AA_PluginApplication);
        configureObserverActivation();
        QApplication app(argc, argv);
        if (!configureObserverActivation())
            return 1;
        if (QString::fromLocal8Bit(argv[1]) == "--watch-file-activity")
            return runFileActivityWorker(app);
        ActivityTrigger observer(nullptr, true);
        const auto send = [](const char *message) {
            const bool delivered = std::fputs(message, stdout) >= 0 && std::fflush(stdout) == 0;
            if (!delivered)
                QCoreApplication::quit();
            return delivered;
        };
        QObject::connect(&observer, &ActivityTrigger::checkRequested, &app, [send] { send("changed\n"); });
        QTimer heartbeat;
        heartbeat.setInterval(5000);
        QObject::connect(&heartbeat, &QTimer::timeout, &app, [send] { send("alive\n"); });
        heartbeat.start();
        observer.start();
        if (!send("alive\n"))
            return 0;
        return app.exec();
    }
    // Isolate browser IPC so a permission dialog or unresponsive browser cannot freeze the UI.
    if (argc >= 3 && QString::fromLocal8Bit(argv[1]) == "--read-browser-url") {
        const bool background = configureApplicationActivation(true);
        QCoreApplication app(argc, argv);
        bool allowPrompt = false;
        QStringList blockedDomains;
        QString optionError;
        bool gotPolicy = false;
        for (int i = 3; i < argc; ++i) {
            const auto option = QString::fromLocal8Bit(argv[i]);
            if (option == "--allow-automation-prompt" && !allowPrompt) {
                allowPrompt = true;
            } else if (option == "--blocked-domains" && !gotPolicy && i + 1 < argc) {
                gotPolicy = true;
                const QByteArray encoded(argv[++i]);
                const auto policy = QJsonDocument::fromJson(encoded.size() <= 350000
                    ? QByteArray::fromBase64(encoded, QByteArray::AbortOnBase64DecodingErrors) : QByteArray());
                if (!policy.isArray()) {
                    optionError = "Invalid blocked-domain policy.";
                    break;
                }
                blockedDomains = configuredBlockedDomains(policy.toJson(QJsonDocument::Compact), &optionError);
            } else {
                optionError = "Invalid browser reader options.";
            }
            if (!optionError.isEmpty())
                break;
        }
        const auto id = QString::fromLocal8Bit(argv[2]);
        const BrowserResult result = !optionError.isEmpty() ? BrowserResult{{}, optionError} : background
            ? readBrowserUrl(id, allowPrompt)
            : BrowserResult{{}, "Unable to start the browser reader in background mode."};
        const auto blockedDomain = result.error.isEmpty() && isSupportedBrowser(id)
            ? blockedDomainForUrl(result.url, blockedDomains) : QString();
        const auto closeError = blockedDomain.isEmpty() ? QString() : requestCloseBrowserTab(id, result.url, allowPrompt);
        const QByteArray output = QJsonDocument(QJsonObject{
            {"url", result.url}, {"error", result.error}, {"title", result.title},
            {"tabCloseRequested", !blockedDomain.isEmpty() && closeError.isEmpty()}, {"tabCloseError", closeError}
        }).toJson(QJsonDocument::Compact);
        std::fwrite(output.constData(), 1, size_t(output.size()), stdout);
        return 0;
    }
    QApplication a(argc, argv);
    configureApplicationActivation(false);
    MainWindow w;
    w.show();
    return QApplication::exec();
}
