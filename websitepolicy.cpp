#include "websitepolicy.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <QUrl>
#include <algorithm>

static bool validBlockedDomain(const QString &domain)
{
    if (domain.isEmpty() || domain.size() > 253 || !domain.contains('.'))
        return false;
    bool hasLetter = false;
    for (const auto &label : domain.split('.')) {
        if (label.isEmpty() || label.size() > 63 || label.startsWith('-') || label.endsWith('-'))
            return false;
        for (const auto c : label) {
            if (c >= QLatin1Char('a') && c <= QLatin1Char('z'))
                hasLetter = true;
            else if (!(c >= QLatin1Char('0') && c <= QLatin1Char('9')) && c != QLatin1Char('-'))
                return false;
        }
    }
    return hasLetter;
}

QStringList configuredBlockedDomains(const QByteArray &json, QString *error)
{
    error->clear();
    const auto reject = [error](const QString &message) -> QStringList { *error = message; return {}; };
    if (json.size() > 256 * 1024)
        return reject("Block list exceeds 256 KB.");
    QJsonParseError parse;
    const auto document = QJsonDocument::fromJson(json, &parse);
    if (parse.error != QJsonParseError::NoError || (!document.isObject() && !document.isArray()))
        return reject("Invalid block-list JSON: " + parse.errorString());
    auto root = document.object();
    if (document.isArray()) {
        QJsonArray websites;
        if (!document.array().isEmpty())
            websites.append(QJsonObject{{"name", "Blocked websites"}, {"domains", document.array()}});
        root = QJsonObject{{"version", 1}, {"websites", websites}};
    }
    if (root.value("version").toInt(-1) != 1 || !root.value("websites").isArray())
        return reject("Expected version 1 and a websites array.");
    QSet<QString> unique;
    for (const auto &value : root.value("websites").toArray()) {
        const auto site = value.toObject();
        if (!value.isObject() || !site.value("name").isString() || site.value("name").toString().trimmed().isEmpty()
            || !site.value("domains").isArray() || site.value("domains").toArray().isEmpty())
            return reject("Each website needs a name and a nonempty domains array.");
        for (const auto &entry : site.value("domains").toArray()) {
            if (!entry.isString())
                return reject("Every domain must be a string.");
            const auto text = entry.toString().trimmed().toLower();
            const auto domain = QString::fromLatin1(QUrl::toAce(text));
            if (!validBlockedDomain(domain))
                return reject("Use domain names only, without schemes, paths, wildcards or IP addresses: " + text);
            unique.insert(domain);
            if (unique.size() > 1000)
                return reject("The block list supports up to 1,000 distinct domains.");
        }
    }
    auto result = unique.values();
    std::sort(result.begin(), result.end());
    return result;
}

QString blockedDomainForUrl(const QString &value, const QStringList &domains)
{
    const QUrl url(value, QUrl::StrictMode);
    if (!url.isValid() || (url.scheme() != "http" && url.scheme() != "https"))
        return {};
    QString host = QString::fromLatin1(QUrl::toAce(url.host().toLower()));
    if (host.endsWith('.'))
        host.chop(1);
    for (const auto &domain : domains)
        if (host == domain || host.endsWith("." + domain))
            return domain;
    return {};
}
