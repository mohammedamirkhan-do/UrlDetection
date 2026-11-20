#pragma once

#include <QStringList>

QStringList configuredBlockedDomains(const QByteArray &json, QString *error);
QString blockedDomainForUrl(const QString &url, const QStringList &domains);
