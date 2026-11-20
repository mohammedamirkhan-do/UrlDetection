#pragma once
#include <QStringList>
class QCoreApplication;

// Only explicit file references belong here; never pass general clipboard text.
QStringList localFileReferences(const QStringList &references, bool *truncated = nullptr);
bool requestFileInputPermission();
int runFileActivityWorker(QCoreApplication &application);
