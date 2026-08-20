#pragma once

#include <QObject>
#include <QVariant>

class QDBusVariant;

class SystemTheme : public QObject {
    Q_OBJECT

public:
    explicit SystemTheme(QObject *parent = nullptr);

    bool darkMode() const { return m_darkMode; }
    qreal textScale() const { return m_textScale; }

signals:
    void darkModeChanged(bool darkMode);
    void textScaleChanged(qreal textScale);

public slots:
    void refresh();

private slots:
    void handlePortalSettingChanged(const QString &nameSpace, const QString &key,
                                    const QDBusVariant &value);

private:
    bool fallbackDarkMode() const;
    bool qtDarkMode(bool *known) const;
    void setDarkMode(bool darkMode);
    void setTextScale(qreal textScale);
    void requestPortalSetting(const QString &nameSpace, const QString &key);
    void applyPortalSetting(const QString &key, const QVariant &value);

    bool m_darkMode = true;
    qreal m_textScale = 1.0;
};
