#include "mainwindow.h"
#include "browserprobe.h"

#include <QApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <cstdio>

int main(int argc, char *argv[])
{
    // Isolate browser IPC so a permission dialog or unresponsive browser cannot freeze the UI.
    if (argc == 3 && QString::fromLocal8Bit(argv[1]) == "--read-browser-url") {
        const bool background = configureApplicationActivation(true);
        QCoreApplication app(argc, argv);
        const BrowserResult result = background
            ? readBrowserUrl(QString::fromLocal8Bit(argv[2]))
            : BrowserResult{{}, "Unable to start the browser reader in background mode."};
        const QByteArray output = QJsonDocument(QJsonObject{
            {"url", result.url}, {"error", result.error}, {"title", result.title}
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
