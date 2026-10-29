#ifndef SNOW_SHOT_PRESENTATION_SCREENSHOTTEXTRESULTWINDOW_H
#define SNOW_SHOT_PRESENTATION_SCREENSHOTTEXTRESULTWINDOW_H

#include <QImage>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QVector>

#include <optional>

class QEvent;
class QLabel;
class QScreen;
class QSplitter;
class QWidget;

namespace adqt::widgets {
class AdModal;
class AdButton;
class AdSelect;
class AdTextEdit;
} // namespace adqt::widgets

namespace snow_shot::presentation {

class ScreenshotTextResultPreviewView;

struct ScreenshotTextResultOption {
    QString id;
    QString label;
};

// Standalone text result surface: the captured region on the left, recognized text and its
// translation on the right. The window owns no recognition state; it reports user intent through
// signals and renders whatever its host pushes in.
class ScreenshotTextResultWindow final : public QObject {
    Q_OBJECT

  public:
    explicit ScreenshotTextResultWindow(QObject* parent = nullptr);
    ~ScreenshotTextResultWindow() override;

    // Presenting an already visible window only refreshes the preview image.
    void present(QScreen* screen, const QImage& image);
    [[nodiscard]] bool isVisible() const;
    // Native window widget, used to parent platform dialogs.
    [[nodiscard]] QWidget* windowWidget() const;
    void close();

    void setElapsedMilliseconds(std::optional<qint64> milliseconds);
    void setOcrText(const QString& text);
    void setTranslationText(const QString& text);
    void setRecognizing(bool busy);
    void setTranslating(bool busy, bool streaming);
    void setOcrStatus(const QString& message, bool error);
    void setTranslationStatus(const QString& message, bool error);
    // Clears the translation pane and re-enables the translate action.
    void clearTranslationResult();
    void setLanguages(const QVector<ScreenshotTextResultOption>& sources, const QString& source,
                      const QVector<ScreenshotTextResultOption>& targets, const QString& target);
    // Typesetting options reuse the shared OCR text formatting catalog.
    void setTypesettingOptions(const QVector<ScreenshotTextResultOption>& options,
                               const QString& current);
    // Editions without the translation feature hide the language row and the translation pane.
    void setTranslationAvailable(bool available);
    [[nodiscard]] QString typesettingOption() const;
    [[nodiscard]] QImage previewImage() const;
    [[nodiscard]] QString ocrText() const;
    [[nodiscard]] QString translationText() const;

  signals:
    void recognizeRequested();
    void translateRequested(const QString& sourceLanguage, const QString& targetLanguage);
    void copyImageRequested();
    void saveOcrRequested();
    void saveTranslationRequested();
    void typesettingChanged(const QString& value);
    void translationSettingsRequested();
    void closed();

  protected:
    bool eventFilter(QObject* watched, QEvent* event) override;

  private:
    void buildUi();
    void retranslate();
    void updateRecognizeControls();
    void updateTranslateControls();
    void setStatus(QLabel* label, const QString& message, bool error);
    void copyText(const QString& value);

    QPointer<adqt::widgets::AdModal> m_modal;
    QWidget* m_body = nullptr;
    QSplitter* m_splitter = nullptr;
    QLabel* m_elapsedLabel = nullptr;
    QLabel* m_previewTitle = nullptr;
    QLabel* m_settingsTitle = nullptr;
    QLabel* m_ocrTitle = nullptr;
    QLabel* m_translationTitle = nullptr;
    QLabel* m_ocrStatus = nullptr;
    QLabel* m_translationStatus = nullptr;
    QLabel* m_sourceLabel = nullptr;
    QLabel* m_targetLabel = nullptr;
    QLabel* m_typesettingLabel = nullptr;
    ScreenshotTextResultPreviewView* m_preview = nullptr;
    adqt::widgets::AdTextEdit* m_ocrText = nullptr;
    adqt::widgets::AdTextEdit* m_translationText = nullptr;
    adqt::widgets::AdSelect* m_sourceSelect = nullptr;
    adqt::widgets::AdSelect* m_targetSelect = nullptr;
    adqt::widgets::AdSelect* m_typesettingSelect = nullptr;
    adqt::widgets::AdButton* m_ocrCopy = nullptr;
    adqt::widgets::AdButton* m_ocrSave = nullptr;
    adqt::widgets::AdButton* m_translationCopy = nullptr;
    adqt::widgets::AdButton* m_translationSave = nullptr;
    adqt::widgets::AdButton* m_imageCopy = nullptr;
    adqt::widgets::AdButton* m_recognize = nullptr;
    adqt::widgets::AdButton* m_translate = nullptr;
    adqt::widgets::AdButton* m_translationSettings = nullptr;
    bool m_recognizing = false;
    // Translation state is tracked even in builds without the translation feature; the host
    // simply never drives it there.
    bool m_translating = false;
    bool m_translationAvailable = true;
    bool m_suppressControlSignals = false;
    bool m_shortcutInstalled = false;
};

} // namespace snow_shot::presentation

#endif // SNOW_SHOT_PRESENTATION_SCREENSHOTTEXTRESULTWINDOW_H
