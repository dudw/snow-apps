#include "snow_shot/presentation/screenshottextresultwindow.h"
#include "snow_shot/presentation/styles/thememanager.h"

#include "widgets/button.h"

#include <QApplication>
#include <QFontDatabase>
#include <QImage>
#include <QWidget>

#include <cstdio>
#include <optional>

namespace {
using snow_shot::presentation::ScreenshotTextResultOption;
using snow_shot::presentation::ScreenshotTextResultWindow;
namespace styles = snow_shot::presentation::styles;

int failures = 0;

void require(bool condition, const char* message) {
    if (condition)
        return;
    ++failures;
    std::fprintf(stderr, "FAIL: %s\n", message);
}

void contracts() {
    ScreenshotTextResultWindow window;
    require(!window.isVisible(), "a fresh result window stays hidden");

    window.setOcrText(QStringLiteral("first line\nsecond line"));
    require(window.ocrText() == QStringLiteral("first line\nsecond line"),
            "recognized text round-trips");

    window.setTranslationText(QStringLiteral("translated"));
    require(window.translationText() == QStringLiteral("translated"),
            "translation text round-trips");

    window.clearTranslationResult();
    require(window.translationText().isEmpty(), "clearing drops the translation");
    require(window.ocrText() == QStringLiteral("first line\nsecond line"),
            "clearing the translation keeps the recognized text");

    window.setElapsedMilliseconds(qint64(230));
    window.setElapsedMilliseconds(std::optional<qint64>{});

    // The translate action must carry the languages the user currently sees.
    window.setLanguages({ScreenshotTextResultOption{QStringLiteral("auto"),
                                                    QStringLiteral("Auto")},
                         ScreenshotTextResultOption{QStringLiteral("en"),
                                                    QStringLiteral("English")}},
                        QStringLiteral("auto"),
                        {ScreenshotTextResultOption{QStringLiteral("zh-Hans"),
                                                    QStringLiteral("Simplified Chinese")}},
                        QStringLiteral("zh-Hans"));

    QString requestedSource;
    QString requestedTarget;
    QObject::connect(&window, &ScreenshotTextResultWindow::translateRequested, &window,
                     [&requestedSource, &requestedTarget](const QString& source,
                                                          const QString& target) {
                         requestedSource = source;
                         requestedTarget = target;
                     });

    QWidget* surface = window.windowWidget();
    require(surface != nullptr, "the window exposes its surface widget");

    auto* translate = surface != nullptr
                          ? surface->findChild<adqt::widgets::AdButton*>(
                                QStringLiteral("screenshotTextResultTranslate"))
                          : nullptr;
    require(translate != nullptr, "translate action exists");
    if (translate != nullptr) {
        translate->click();
        require(requestedSource == QStringLiteral("auto"), "translate request keeps the source");
        require(requestedTarget == QStringLiteral("zh-Hans"),
                "translate request keeps the target");
    }

    QString typesetting;
    QObject::connect(&window, &ScreenshotTextResultWindow::typesettingChanged, &window,
                     [&typesetting](const QString& value) { typesetting = value; });
    window.setTypesettingOptions(
        {ScreenshotTextResultOption{QStringLiteral("none"), QStringLiteral("None")},
         ScreenshotTextResultOption{QStringLiteral("smart"), QStringLiteral("Smart Typesetting")}},
        QStringLiteral("none"));
    require(window.typesettingOption() == QStringLiteral("none"),
            "typesetting keeps the requested option");
    require(typesetting.isEmpty(),
            "programmatic option updates do not report a user change");

    auto* recognize = surface != nullptr ? surface->findChild<adqt::widgets::AdButton*>(
                                               QStringLiteral("screenshotTextResultRecognize"))
                                         : nullptr;
    require(recognize != nullptr, "recognize action exists");
    window.setRecognizing(true);
    require(recognize != nullptr && !recognize->isEnabled(),
            "recognition busy state disables the recognize action");
    window.setRecognizing(false);
    require(recognize != nullptr && recognize->isEnabled(),
            "recognition completion re-enables the recognize action");

    window.setTranslating(true, false);
    require(translate != nullptr && !translate->isEnabled(),
            "an active translation disables its own action");
    window.setTranslating(false, false);
    require(translate != nullptr && translate->isEnabled(),
            "a finished translation re-enables its action");
}

// The result surface is a bare window: its chrome must sit flush against the frame. A wrapped
// title label reports a height-for-width hint, so a dense content area used to collapse the
// title into a column and inflate the header, leaving a blank band above everything else.
void layoutContract() {
    ScreenshotTextResultWindow window;
    window.present(nullptr, QImage(640, 400, QImage::Format_ARGB32));
    QCoreApplication::processEvents();

    QWidget* overlay = window.windowWidget();
    require(overlay != nullptr, "a presented window exposes its surface");
    if (overlay == nullptr)
        return;

    QWidget* header = overlay->findChild<QWidget*>(QStringLiteral("ad-modal-header"));
    QWidget* title = overlay->findChild<QWidget*>(QStringLiteral("ad-modal-title"));
    QWidget* body = overlay->findChild<QWidget*>(QStringLiteral("ad-modal-body"));
    require(header != nullptr, "the window chrome exposes a header");
    require(title != nullptr, "the window chrome exposes a title");
    require(body != nullptr, "the window chrome exposes a content area");
    if (header == nullptr || title == nullptr || body == nullptr)
        return;

    require(header->height() < 80, "the title bar keeps a single-line height");
    require(title->mapTo(overlay, QPoint(0, 0)).y() < 40,
            "the title sits against the window top");
    require(body->mapTo(overlay, QPoint(0, 0)).y() < 100,
            "the content area starts right below the title");
}
} // namespace

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName(QStringLiteral("SnowShotTests"));
    QCoreApplication::setApplicationName(QStringLiteral("screenshot_text_result_window_tests"));
#ifdef Q_OS_WIN
    static_cast<void>(
        QFontDatabase::addApplicationFont(QStringLiteral("C:/Windows/Fonts/segoeui.ttf")));
    static_cast<void>(
        QFontDatabase::addApplicationFont(QStringLiteral("C:/Windows/Fonts/msyh.ttc")));
#endif
    styles::ThemeManager::instance().initialize(app);
    contracts();
    layoutContract();
    return failures == 0 ? 0 : 1;
}
