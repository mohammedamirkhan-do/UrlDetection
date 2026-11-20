#pragma once

#include <QString>

QString browserCloseTabScript(const QString &id, const QString &expectedUrl);
QString requestCloseBrowserTab(const QString &id, const QString &expectedUrl, bool allowAutomationPrompt = false);
