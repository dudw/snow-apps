#include "globalshortcutbackend_p.h"

namespace snow_shot::presentation {
namespace {

// Platform backends in this namespace also define a `validation` helper. Unity
// builds merge those translation units, so keep this one named for its purpose.
GlobalShortcutValidationResult
unsupportedValidation(const shortcuts::ShortcutBinding& binding) {
    GlobalShortcutValidationResult result;
    result.binding = binding;
    result.shortcut = binding.portableText;
    result.supported = false;
    result.failureReason = GlobalShortcutFailureReason::UnsupportedPlatform;
    return result;
}

class UnsupportedGlobalShortcutBackend final : public GlobalShortcutBackend {
  public:
    void setActivationHandler(ActivationHandler) override {}

    GlobalShortcutValidationResult
    validateShortcut(const shortcuts::ShortcutBinding& binding) const override {
        return unsupportedValidation(binding);
    }

    GlobalShortcutBackendResult registerShortcut(int, const shortcuts::ShortcutBinding&) override {
        return {false, GlobalShortcutFailureReason::UnsupportedPlatform, 0};
    }

    void unregisterShortcut(int) override {}
};

} // namespace

std::unique_ptr<GlobalShortcutBackend> createPlatformGlobalShortcutBackend() {
#ifdef Q_OS_WIN
    return createWindowsGlobalShortcutBackend();
#elif defined(Q_OS_MACOS)
    return createMacOSGlobalShortcutBackend();
#else
    return std::make_unique<UnsupportedGlobalShortcutBackend>();
#endif
}

} // namespace snow_shot::presentation
