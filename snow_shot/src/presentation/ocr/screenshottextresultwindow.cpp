#include "snow_shot/presentation/screenshottextresultwindow.h"

#include "snow_shot/presentation/components/icons/snowshoticons.h"
#include "snow_shot/presentation/styles/thememanager.h"
#include "snow_shot/presentation/windowcloseshortcut.h"

#include "widgets/button.h"
#include "widgets/input_text_edit.h"
#include "widgets/modal.h"
#include "widgets/select.h"

#include <QClipboard>
#include <QCoreApplication>
#include <QEvent>
#include <QFrame>
#include <QGraphicsPixmapItem>
#include <QGraphicsScene>
#include <QGraphicsView>
#include <QGuiApplication>
#include <QHBoxLayout>
#include <QLabel>
#include <QMouseEvent>
#include <QPainter>
#include <QResizeEvent>
#include <QScreen>
#include <QScrollArea>
#include <QSignalBlocker>
#include <QSplitter>
#include <QStringConverter>
#include <QVBoxLayout>
#include <QWheelEvent>

#include <algorithm>
#include <cmath>

namespace snow_shot::presentation {
namespace {

using adqt::widgets::AdButton;
using adqt::widgets::AdSelect;
using adqt::widgets::AdTextEdit;

constexpr int kDefaultWidth = 1120;
constexpr int kDefaultHeight = 720;
constexpr int kMinimumWidth = 760;
constexpr int kMinimumHeight = 480;
constexpr int kPreviewMinimumWidth = 320;

QString text(const char* source) {
    return QCoreApplication::translate("ScreenshotTextResultWindow",
                                       source);
}

QLabel* makeLabel(const QString& value, QWidget* parent) {
    auto* label = new QLabel(value, parent);
    label->setWordWrap(false);
    return label;
}

QLabel* makeSectionTitle(QWidget* parent) {
    auto* label = new QLabel(parent);
    QFont font = label->font();
    font.setBold(true);
    label->setFont(font);
    return label;
}

AdButton* makeIconButton(const adqt::icons::IconRef& icon, QWidget* parent) {
    auto* button = new AdButton(parent);
    button->setIconRef(icon);
    button->setButtonStyle(AdButton::ButtonStyle::Text);
    button->setShape(AdButton::Shape::Circle);
    button->setSizeClass(AdButton::SizeClass::Small);
    return button;
}

AdButton* makeTextButton(const QString& label, QWidget* parent, bool primary) {
    auto* button = new AdButton(parent);
    button->setText(label);
    button->setSizeClass(AdButton::SizeClass::Medium);
    button->setButtonStyle(primary ? AdButton::ButtonStyle::Solid : AdButton::ButtonStyle::Outline);
    if (primary)
        button->setAccentRole(AdButton::AccentRole::Primary);
    return button;
}

QColor mutedTextColor() {
    return styles::ThemeManager::instance().themeColorScheme().alias.textMuted;
}

} // namespace

// Zoomable preview of the captured region. Wheel zoom and drag panning mirror the companion
// preview window; double-click returns to the fitted scale.
class ScreenshotTextResultPreviewView final : public QGraphicsView {
  public:
    explicit ScreenshotTextResultPreviewView(QWidget* parent = nullptr)
        : QGraphicsView(parent), m_scene(new QGraphicsScene(this)) {
        setObjectName(QStringLiteral("screenshotTextResultPreview"));
        setScene(m_scene);
        setFrameShape(QFrame::NoFrame);
        setDragMode(QGraphicsView::ScrollHandDrag);
        setTransformationAnchor(QGraphicsView::AnchorUnderMouse);
        setResizeAnchor(QGraphicsView::AnchorViewCenter);
        setRenderHint(QPainter::SmoothPixmapTransform, true);
        setHorizontalScrollBarPolicy(Qt::ScrollBarAsNeeded);
        setVerticalScrollBarPolicy(Qt::ScrollBarAsNeeded);
        setMinimumWidth(kPreviewMinimumWidth);
        applyTheme();
        m_item = m_scene->addPixmap(QPixmap());
    }

    void applyTheme() {
        const auto scheme = styles::ThemeManager::instance().themeColorScheme();
        setBackgroundBrush(scheme.alias.surfaceAltBg);
        setStyleSheet(
            QStringLiteral("QGraphicsView { border: 1px solid %1; background: %2; }")
                .arg(scheme.alias.subtleBorder.name(), scheme.alias.surfaceAltBg.name()));
    }

    void setImage(const QImage& image) {
        m_image = image;
        if (image.isNull()) {
            m_item->setPixmap(QPixmap());
            m_scene->setSceneRect(QRectF());
            resetTransform();
            return;
        }
        m_item->setPixmap(QPixmap::fromImage(image));
        m_scene->setSceneRect(QRectF(QPointF(0, 0), QSizeF(image.size())));
        m_userZoom = false;
        fitImage();
    }

    [[nodiscard]] QImage image() const {
        return m_image;
    }

  protected:
    void resizeEvent(QResizeEvent* event) override {
        QGraphicsView::resizeEvent(event);
        if (!m_userZoom)
            fitImage();
    }

    void wheelEvent(QWheelEvent* event) override {
        if (m_image.isNull()) {
            QGraphicsView::wheelEvent(event);
            return;
        }
        const qreal steps = event->angleDelta().y() / 120.0;
        if (qFuzzyIsNull(steps)) {
            QGraphicsView::wheelEvent(event);
            return;
        }
        const qreal current = transform().m11();
        const qreal next = std::clamp(current * std::pow(1.15, steps), 0.05, 16.0);
        if (qFuzzyCompare(next, current)) {
            event->accept();
            return;
        }
        scale(next / current, next / current);
        m_userZoom = true;
        event->accept();
    }

    void mouseDoubleClickEvent(QMouseEvent* event) override {
        if (m_image.isNull()) {
            QGraphicsView::mouseDoubleClickEvent(event);
            return;
        }
        m_userZoom = false;
        fitImage();
        event->accept();
    }

  private:
    void fitImage() {
        if (m_image.isNull()) {
            resetTransform();
            return;
        }
        // Fitting can change scroll bar visibility, which resizes the viewport again.
        if (m_fitting)
            return;
        m_fitting = true;
        fitInView(QRectF(QPointF(0, 0), QSizeF(m_image.size())), Qt::KeepAspectRatio);
        m_fitting = false;
    }

    QGraphicsScene* m_scene = nullptr;
    QGraphicsPixmapItem* m_item = nullptr;
    QImage m_image;
    bool m_userZoom = false;
    bool m_fitting = false;
};

ScreenshotTextResultWindow::ScreenshotTextResultWindow(QObject* parent)
    : QObject(parent), m_modal(new adqt::widgets::AdModal(this)) {
    using adqt::widgets::AdModal;
    m_modal->setObjectName(QStringLiteral("screenshotTextResultModal"));
    m_modal->setMode(AdModal::Mode::Window);
    m_modal->setWindowModeDetached(true);
    m_modal->setWindowModality(Qt::NonModal);
    m_modal->setCentered(true);
    m_modal->setWindowResizable(true);
    m_modal->setWindowTaskbarVisible(true);
    m_modal->setWindowMinimizeButtonVisible(true);
    m_modal->setWindowMaximizeButtonVisible(true);
    m_modal->setWindowAlwaysOnTopButtonVisible(true);
    // The capture overlay and its recognition surface stay above other windows, so the result
    // window must do the same or it would open behind the screenshot it describes.
    m_modal->setWindowAlwaysOnTop(true);
    m_modal->setFooterVisible(false);
    m_modal->setMaskVisible(false);
    m_modal->setCloseOnMaskClick(false);
    m_modal->setCloseOnEscape(true);
    m_modal->setClosePolicy(AdModal::ClosePolicy::Automatic);
    m_modal->setWindowPreferredSize(QSize(kDefaultWidth, kDefaultHeight));
    m_modal->setWindowMinimumSize(QSize(kMinimumWidth, kMinimumHeight));
    AdModal::ComponentTokens tokens;
    tokens.contentPaddingHorizontal = 0;
    tokens.contentPaddingVertical = 0;
    tokens.headerMarginBottom = 0;
    m_modal->setComponentTokens(tokens);

    buildUi();
    m_modal->setContentWidget(m_body);
    connect(m_modal, &AdModal::closed, this, [this] {
        if (m_preview != nullptr)
            m_preview->setImage(QImage());
        emit ScreenshotTextResultWindow::closed();
    });
    connect(&styles::ThemeManager::instance(), &styles::ThemeManager::themeChanged, this,
            [this](const styles::ThemeColorScheme&) {
                if (m_preview != nullptr)
                    m_preview->applyTheme();
                // Section labels and muted hints are re-styled during retranslation.
                retranslate();
            });
}

ScreenshotTextResultWindow::~ScreenshotTextResultWindow() {
    if (m_modal == nullptr)
        return;
    // Teardown must not re-enter the controller through the closed() notification.
    QObject::disconnect(m_modal, nullptr, this, nullptr);
    m_modal->close();
}

void ScreenshotTextResultWindow::buildUi() {
    m_body = new QWidget;
    m_body->setObjectName(QStringLiteral("screenshotTextResultBody"));
    m_body->installEventFilter(this);
    auto* root = new QHBoxLayout(m_body);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    m_splitter = new QSplitter(Qt::Horizontal, m_body);
    m_splitter->setObjectName(QStringLiteral("screenshotTextResultSplitter"));
    m_splitter->setChildrenCollapsible(false);
    m_splitter->setHandleWidth(1);
    root->addWidget(m_splitter);

    // Left: the captured region, unchanged and zoomable.
    auto* previewPanel = new QWidget(m_splitter);
    previewPanel->setObjectName(QStringLiteral("screenshotTextResultPreviewPanel"));
    auto* previewLayout = new QVBoxLayout(previewPanel);
    previewLayout->setContentsMargins(12, 10, 12, 12);
    previewLayout->setSpacing(8);
    auto* previewHeader = new QHBoxLayout;
    previewHeader->setContentsMargins(0, 0, 0, 0);
    previewHeader->setSpacing(6);
    m_previewTitle = makeSectionTitle(previewPanel);
    previewHeader->addWidget(m_previewTitle);
    previewHeader->addStretch(1);
    m_elapsedLabel = makeLabel(QString(), previewPanel);
    m_elapsedLabel->setObjectName(QStringLiteral("screenshotTextResultElapsed"));
    previewHeader->addWidget(m_elapsedLabel);
    m_imageCopy = makeIconButton(icons::custom::outlined::ScreenshotCopy(), previewPanel);
    m_imageCopy->setObjectName(QStringLiteral("screenshotTextResultCopyImage"));
    previewHeader->addWidget(m_imageCopy);
    previewLayout->addLayout(previewHeader);
    m_preview = new ScreenshotTextResultPreviewView(previewPanel);
    previewLayout->addWidget(m_preview, 1);
    m_splitter->addWidget(previewPanel);

    // Right: settings, recognized text, translation.
    auto* scroll = new QScrollArea(m_splitter);
    scroll->setObjectName(QStringLiteral("screenshotTextResultScroll"));
    scroll->setFrameShape(QFrame::NoFrame);
    scroll->setWidgetResizable(true);
    auto* rightPanel = new QWidget(scroll);
    rightPanel->setObjectName(QStringLiteral("screenshotTextResultRightPanel"));
    auto* rightLayout = new QVBoxLayout(rightPanel);
    rightLayout->setContentsMargins(12, 10, 12, 12);
    rightLayout->setSpacing(10);

    m_settingsTitle = makeSectionTitle(rightPanel);
    rightLayout->addWidget(m_settingsTitle);

    auto* languageRow = new QHBoxLayout;
    languageRow->setContentsMargins(0, 0, 0, 0);
    languageRow->setSpacing(8);
    m_sourceLabel = makeLabel(QString(), rightPanel);
    m_sourceSelect = new AdSelect(rightPanel);
    m_sourceSelect->setObjectName(QStringLiteral("screenshotTextResultSourceLanguage"));
    m_sourceSelect->setSearchEnabled(true);
    m_sourceSelect->setSearchFilterFields({QStringLiteral("label")});
    m_targetLabel = makeLabel(QString(), rightPanel);
    m_targetSelect = new AdSelect(rightPanel);
    m_targetSelect->setObjectName(QStringLiteral("screenshotTextResultTargetLanguage"));
    m_targetSelect->setSearchEnabled(true);
    m_targetSelect->setSearchFilterFields({QStringLiteral("label")});
    m_translate = makeTextButton(QString(), rightPanel, true);
    m_translate->setObjectName(QStringLiteral("screenshotTextResultTranslate"));
    languageRow->addWidget(m_sourceLabel);
    languageRow->addWidget(m_sourceSelect, 1);
    languageRow->addWidget(m_targetLabel);
    languageRow->addWidget(m_targetSelect, 1);
    languageRow->addWidget(m_translate);
    rightLayout->addLayout(languageRow);

    auto* actionRow = new QHBoxLayout;
    actionRow->setContentsMargins(0, 0, 0, 0);
    actionRow->setSpacing(8);
    m_recognize = makeTextButton(QString(), rightPanel, false);
    m_recognize->setObjectName(QStringLiteral("screenshotTextResultRecognize"));
    m_translationSettings = makeTextButton(QString(), rightPanel, false);
    m_translationSettings->setObjectName(QStringLiteral("screenshotTextResultTranslateSettings"));
    m_typesettingLabel = makeLabel(QString(), rightPanel);
    m_typesettingSelect = new AdSelect(rightPanel);
    m_typesettingSelect->setObjectName(QStringLiteral("screenshotTextResultTypesetting"));
    m_typesettingSelect->setAllowClear(false);
    actionRow->addWidget(m_recognize);
    actionRow->addWidget(m_translationSettings);
    actionRow->addStretch(1);
    actionRow->addWidget(m_typesettingLabel);
    actionRow->addWidget(m_typesettingSelect);
    rightLayout->addLayout(actionRow);

    auto* divider = new QFrame(rightPanel);
    divider->setFrameShape(QFrame::HLine);
    divider->setFrameShadow(QFrame::Plain);
    rightLayout->addWidget(divider);

    auto makeTextSection = [rightPanel, rightLayout](QLabel*& title, QLabel*& status,
                                                     AdButton*& copy, AdButton*& save) {
        auto* header = new QHBoxLayout;
        header->setContentsMargins(0, 0, 0, 0);
        header->setSpacing(8);
        title = makeSectionTitle(rightPanel);
        status = makeLabel(QString(), rightPanel);
        status->hide();
        copy = makeIconButton(icons::custom::outlined::ScreenshotCopy(), rightPanel);
        save = makeIconButton(icons::custom::outlined::Save(), rightPanel);
        header->addWidget(title);
        header->addWidget(status);
        header->addStretch(1);
        header->addWidget(copy);
        header->addWidget(save);
        rightLayout->addLayout(header);
    };

    makeTextSection(m_ocrTitle, m_ocrStatus, m_ocrCopy, m_ocrSave);
    m_ocrCopy->setObjectName(QStringLiteral("screenshotTextResultCopyOcr"));
    m_ocrSave->setObjectName(QStringLiteral("screenshotTextResultSaveOcr"));
    m_ocrText = new AdTextEdit(rightPanel);
    m_ocrText->setObjectName(QStringLiteral("screenshotTextResultOcrText"));
    m_ocrText->setHeightMode(AdTextEdit::HeightMode::FixedGeometry);
    m_ocrText->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    m_ocrText->setReadOnly(true);
    m_ocrText->setMinimumHeight(150);
    rightLayout->addWidget(m_ocrText, 3);

    makeTextSection(m_translationTitle, m_translationStatus, m_translationCopy, m_translationSave);
    m_translationCopy->setObjectName(QStringLiteral("screenshotTextResultCopyTranslation"));
    m_translationSave->setObjectName(QStringLiteral("screenshotTextResultSaveTranslation"));
    m_translationText = new AdTextEdit(rightPanel);
    m_translationText->setObjectName(QStringLiteral("screenshotTextResultTranslationText"));
    m_translationText->setHeightMode(AdTextEdit::HeightMode::FixedGeometry);
    m_translationText->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    m_translationText->setReadOnly(true);
    m_translationText->setMinimumHeight(150);
    rightLayout->addWidget(m_translationText, 3);

    scroll->setWidget(rightPanel);
    m_splitter->addWidget(scroll);
    m_splitter->setStretchFactor(0, 5);
    m_splitter->setStretchFactor(1, 6);

    connect(m_imageCopy, &AdButton::clicked, this, &ScreenshotTextResultWindow::copyImageRequested);
    connect(m_ocrCopy, &AdButton::clicked, this, [this] { copyText(ocrText()); });
    connect(m_translationCopy, &AdButton::clicked, this,
            [this] { copyText(translationText()); });
    connect(m_ocrSave, &AdButton::clicked, this,
            &ScreenshotTextResultWindow::saveOcrRequested);
    connect(m_translationSave, &AdButton::clicked, this,
            &ScreenshotTextResultWindow::saveTranslationRequested);
    connect(m_recognize, &AdButton::clicked, this,
            &ScreenshotTextResultWindow::recognizeRequested);
    connect(m_translate, &AdButton::clicked, this, [this] {
        emit translateRequested(m_sourceSelect->currentValue().toString(),
                                m_targetSelect->currentValue().toString());
    });
    connect(m_translationSettings, &AdButton::clicked, this,
            &ScreenshotTextResultWindow::translationSettingsRequested);
    connect(m_typesettingSelect, &AdSelect::currentValueChanged, this,
            [this](const QVariant& value) {
                if (m_suppressControlSignals)
                    return;
                emit typesettingChanged(value.toString());
            });

    retranslate();
    updateRecognizeControls();
    updateTranslateControls();
}

void ScreenshotTextResultWindow::copyText(const QString& value) {
    if (value.isEmpty() || QGuiApplication::clipboard() == nullptr)
        return;
    QGuiApplication::clipboard()->setText(value);
}

void ScreenshotTextResultWindow::retranslate() {
    if (m_modal != nullptr)
        m_modal->setWindowTitle(text(QT_TRANSLATE_NOOP(
            "ScreenshotTextResultWindow", "Text Recognition")));
    m_previewTitle->setText(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Preview")));
    m_settingsTitle->setText(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Settings")));
    m_ocrTitle->setText(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Recognized Text")));
    m_translationTitle->setText(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Translation")));
    m_sourceLabel->setText(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Source Language")));
    m_targetLabel->setText(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Target Language")));
    m_typesettingLabel->setText(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Typesetting")));
    m_recognize->setText(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Recognize Again")));
    m_translate->setText(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Translate")));
    m_translationSettings->setText(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "More Settings")));
    m_imageCopy->setToolTip(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Copy image")));
    m_ocrCopy->setToolTip(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Copy recognized text")));
    m_ocrSave->setToolTip(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Save recognized text")));
    m_translationCopy->setToolTip(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Copy translation")));
    m_translationSave->setToolTip(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Save translation")));
    m_ocrText->setPlaceholderText(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Recognized text appears here")));
    m_translationText->setPlaceholderText(text(QT_TRANSLATE_NOOP(
        "ScreenshotTextResultWindow", "Translation appears here")));
    const auto muted = mutedTextColor().name();
    for (auto* label : {m_sourceLabel, m_targetLabel, m_typesettingLabel, m_elapsedLabel})
        label->setStyleSheet(QStringLiteral("color: %1;").arg(muted));
}

void ScreenshotTextResultWindow::present(QScreen* screen, const QImage& image) {
    if (m_preview != nullptr && !image.isNull())
        m_preview->setImage(image);
    if (m_modal == nullptr)
        return;
    if (screen != nullptr)
        m_modal->setWindowScreen(screen);
    m_modal->present();
    if (!m_shortcutInstalled && m_body != nullptr && m_body->window() != nullptr) {
        installWindowCloseShortcut(m_body->window(), [this] { close(); });
        m_shortcutInstalled = true;
    }
}

bool ScreenshotTextResultWindow::isVisible() const {
    return m_modal != nullptr && m_modal->isOpen();
}

QWidget* ScreenshotTextResultWindow::windowWidget() const {
    return m_body != nullptr ? m_body->window() : nullptr;
}

void ScreenshotTextResultWindow::close() {
    if (m_modal != nullptr)
        m_modal->close();
}

void ScreenshotTextResultWindow::setElapsedMilliseconds(std::optional<qint64> milliseconds) {
    if (m_elapsedLabel == nullptr)
        return;
    if (!milliseconds.has_value()) {
        m_elapsedLabel->clear();
        return;
    }
    const qint64 value = std::max<qint64>(0, *milliseconds);
    m_elapsedLabel->setText(
        text(QT_TRANSLATE_NOOP("ScreenshotTextResultWindow",
                               "Elapsed: %1 s"))
            .arg(QString::number(double(value) / 1000.0, 'f', 2)));
    m_elapsedLabel->setToolTip(
        text(QT_TRANSLATE_NOOP("ScreenshotTextResultWindow",
                               "Time from the recognition request to the result")));
}

void ScreenshotTextResultWindow::setOcrText(const QString& value) {
    if (m_ocrText == nullptr || m_ocrText->toPlainText() == value)
        return;
    const QSignalBlocker blocker(m_ocrText);
    m_ocrText->setPlainText(value);
}

QString ScreenshotTextResultWindow::ocrText() const {
    return m_ocrText != nullptr ? m_ocrText->toPlainText() : QString();
}

QString ScreenshotTextResultWindow::translationText() const {
    return m_translationText != nullptr ? m_translationText->toPlainText() : QString();
}

void ScreenshotTextResultWindow::setTranslationText(const QString& value) {
    if (m_translationText == nullptr || m_translationText->toPlainText() == value)
        return;
    const QSignalBlocker blocker(m_translationText);
    m_translationText->setPlainText(value);
}

void ScreenshotTextResultWindow::setRecognizing(bool busy) {
    if (m_recognizing == busy)
        return;
    m_recognizing = busy;
    updateRecognizeControls();
}

void ScreenshotTextResultWindow::setTranslating(bool busy, bool streaming) {
    // Streaming only changes how the text arrives; the pane stays readable throughout.
    Q_UNUSED(streaming)
    m_translating = busy;
    updateTranslateControls();
}

void ScreenshotTextResultWindow::updateRecognizeControls() {
    if (m_recognize == nullptr)
        return;
    m_recognize->setBusy(m_recognizing);
    m_recognize->setEnabled(!m_recognizing);
}

void ScreenshotTextResultWindow::updateTranslateControls() {
    if (m_translate == nullptr)
        return;
    m_translate->setBusy(m_translating);
    m_translate->setEnabled(!m_translating);
    if (m_sourceSelect != nullptr)
        m_sourceSelect->setEnabled(!m_translating);
    if (m_targetSelect != nullptr)
        m_targetSelect->setEnabled(!m_translating);
}

void ScreenshotTextResultWindow::setOcrStatus(const QString& message, bool error) {
    setStatus(m_ocrStatus, message, error);
}

void ScreenshotTextResultWindow::setTranslationStatus(const QString& message, bool error) {
    setStatus(m_translationStatus, message, error);
}

void ScreenshotTextResultWindow::setStatus(QLabel* label, const QString& message, bool error) {
    if (label == nullptr)
        return;
    label->setText(message);
    const auto scheme = styles::ThemeManager::instance().themeColorScheme();
    const QColor color = error ? scheme.alias.error : scheme.alias.textMuted;
    label->setStyleSheet(QStringLiteral("color: %1;").arg(color.name()));
    const bool translationHidden = label == m_translationStatus && !m_translationAvailable;
    label->setVisible(!message.isEmpty() && !translationHidden);
}

void ScreenshotTextResultWindow::clearTranslationResult() {
    setTranslationText(QString());
    setTranslationStatus(QString(), false);
    m_translating = false;
    updateTranslateControls();
}

void ScreenshotTextResultWindow::setLanguages(
    const QVector<ScreenshotTextResultOption>& sources, const QString& source,
    const QVector<ScreenshotTextResultOption>& targets, const QString& target) {
    m_suppressControlSignals = true;
    auto toOptions = [](const QVector<ScreenshotTextResultOption>& values) {
        QVector<AdSelect::Option> options;
        options.reserve(values.size());
        for (const auto& value : values)
            options.append({value.id, value.label});
        return options;
    };
    if (m_sourceSelect != nullptr) {
        const QSignalBlocker blocker(m_sourceSelect);
        m_sourceSelect->setOptions(toOptions(sources));
        if (!source.isEmpty())
            m_sourceSelect->setCurrentValue(source);
    }
    if (m_targetSelect != nullptr) {
        const QSignalBlocker blocker(m_targetSelect);
        m_targetSelect->setOptions(toOptions(targets));
        if (!target.isEmpty())
            m_targetSelect->setCurrentValue(target);
    }
    m_suppressControlSignals = false;
}

void ScreenshotTextResultWindow::setTypesettingOptions(
    const QVector<ScreenshotTextResultOption>& options, const QString& current) {
    if (m_typesettingSelect == nullptr)
        return;
    m_suppressControlSignals = true;
    QVector<AdSelect::Option> values;
    values.reserve(options.size());
    for (const auto& option : options)
        values.append({option.id, option.label});
    const QSignalBlocker blocker(m_typesettingSelect);
    m_typesettingSelect->setOptions(values);
    if (!current.isEmpty())
        m_typesettingSelect->setCurrentValue(current);
    m_suppressControlSignals = false;
}

void ScreenshotTextResultWindow::setTranslationAvailable(bool available) {
    if (m_translationAvailable == available)
        return;
    m_translationAvailable = available;
    QWidget* const panes[] = {
        static_cast<QWidget*>(m_sourceLabel),       static_cast<QWidget*>(m_sourceSelect),
        static_cast<QWidget*>(m_targetLabel),       static_cast<QWidget*>(m_targetSelect),
        static_cast<QWidget*>(m_translate),         static_cast<QWidget*>(m_translationSettings),
        static_cast<QWidget*>(m_translationTitle),  static_cast<QWidget*>(m_translationStatus),
        static_cast<QWidget*>(m_translationCopy),   static_cast<QWidget*>(m_translationSave),
        static_cast<QWidget*>(m_translationText)};
    for (QWidget* widget : panes) {
        if (widget != nullptr)
            widget->setVisible(available);
    }
}

QString ScreenshotTextResultWindow::typesettingOption() const {
    return m_typesettingSelect != nullptr ? m_typesettingSelect->currentValue().toString()
                                          : QString();
}

QImage ScreenshotTextResultWindow::previewImage() const {
    return m_preview != nullptr ? m_preview->image() : QImage();
}

bool ScreenshotTextResultWindow::eventFilter(QObject* watched, QEvent* event) {
    if (watched == m_body && event->type() == QEvent::LanguageChange) {
        retranslate();
        updateRecognizeControls();
        updateTranslateControls();
    }
    return QObject::eventFilter(watched, event);
}

} // namespace snow_shot::presentation
