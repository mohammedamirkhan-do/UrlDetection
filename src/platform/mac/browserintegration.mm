#include "blocking/tabcloser.h"
#include "detection/browserprobe.h"
#include "macprocess.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreServices/CoreServices.h>
#include <libproc.h>
#include <unistd.h>
#include <cstring>
#include <vector>

pid_t applicationProcessId(pid_t reportedPid, NSString *executablePath)
{
    if (reportedPid > 0)
        return reportedPid;
    if (!executablePath.length)
        return 0;
    // Some macOS applications (including Safari) are reported by AppKit with pid -1.
    const int count = proc_listallpids(nullptr, 0);
    if (count <= 0)
        return 0;
    std::vector<pid_t> pids(size_t(count) + 64);
    const int found = proc_listallpids(pids.data(), int(pids.size() * sizeof(pid_t)));
    const char *expected = executablePath.stringByResolvingSymlinksInPath.fileSystemRepresentation;
    pid_t match = 0;
    for (int i = 0; i < found && size_t(i) < pids.size(); ++i) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pids[i], path, sizeof(path)) <= 0 || std::strcmp(path, expected) != 0)
            continue;
        proc_bsdinfo info{};
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)
            || info.pbi_uid != getuid())
            continue;
        if (match != 0)
            return 0; // Do not guess between multiple instances of the same executable.
        match = pids[i];
    }
    return match;
}

bool accessibilityAccess(bool prompt)
{
    @autoreleasepool {
        NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @(prompt)};
        return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    }
}

bool configureApplicationActivation(bool background)
{
    @autoreleasepool {
        const auto policy = background ? NSApplicationActivationPolicyProhibited
                                       : NSApplicationActivationPolicyRegular;
        return [NSApplication.sharedApplication setActivationPolicy:policy];
    }
}

BrowserApplication foregroundApplication()
{
    @autoreleasepool {
        NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
        return {QString::fromNSString(app.bundleIdentifier),
                QString::fromNSString(app.localizedName)};
    }
}

bool configureObserverActivation()
{
    @autoreleasepool {
        // Qt's native event loop needs an AppKit application; accessory mode keeps it out of the Dock.
        NSApplication *app = NSApplication.sharedApplication;
        return app.activationPolicy == NSApplicationActivationPolicyAccessory
            || [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
}

static QString attributeText(AXUIElementRef element, CFStringRef attribute)
{
    CFTypeRef value = nullptr;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess)
        return {};
    QString text;
    if (CFGetTypeID(value) == CFStringGetTypeID())
        text = QString::fromCFString(static_cast<CFStringRef>(value));
    else if (CFGetTypeID(value) == CFURLGetTypeID())
        text = QString::fromCFString(CFURLGetString(static_cast<CFURLRef>(value)));
    CFRelease(value);
    return text;
}

static QString documentUrl(AXUIElementRef element, int depth, int &remaining,
                           const QString &applicationId, bool allowAddressFields, bool inToolbar = false)
{
    // Vivaldi's web-based browser interface nests the active page around 20 levels deep.
    if (depth > (applicationId == "com.vivaldi.Vivaldi" ? 24 : 12) || --remaining < 0)
        return {};
    AXUIElementSetMessagingTimeout(element, 0.1);
    const QString role = attributeText(element, kAXRoleAttribute);
    // Page links, body text and password fields are not the active document's address.
    if (role == "AXLink" || role == "AXStaticText" || role == "AXTextArea" || role == "AXSecureTextField"
        || attributeText(element, kAXSubroleAttribute) == "AXSecureTextField")
        return {};
    QString url = attributeText(element, kAXDocumentAttribute);
    if (isFullUrl(url) && !isBrowserInterfaceUrl(applicationId, url))
        return url;
    if (role == "AXWebArea") {
        url = attributeText(element, kAXURLAttribute);
        if (isFullUrl(url) && !isBrowserInterfaceUrl(applicationId, url))
            return url;
        // Vivaldi wraps the page in a web-based browser UI; continue through that wrapper.
        if (!isBrowserInterfaceUrl(applicationId, url))
            return {};
    }
    inToolbar = inToolbar || role == "AXToolbar";
    if (allowAddressFields && inToolbar && (role == "AXTextField" || role == "AXComboBox")) {
        const QString identity = attributeText(element, kAXIdentifierAttribute) + " "
            + attributeText(element, kAXDescriptionAttribute);
        url = accessibleAddressUrl(role, identity, attributeText(element, kAXValueAttribute), inToolbar);
        if (!url.isEmpty())
            return url;
    }
    CFTypeRef children = nullptr;
    QString result;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children) == kAXErrorSuccess) {
        if (CFGetTypeID(children) == CFArrayGetTypeID()) {
            auto array = static_cast<CFArrayRef>(children);
            for (CFIndex i = 0; i < CFArrayGetCount(array) && remaining > 0; ++i) {
                auto child = static_cast<AXUIElementRef>(const_cast<void *>(CFArrayGetValueAtIndex(array, i)));
                if (CFGetTypeID(child) != AXUIElementGetTypeID())
                    continue;
                result = documentUrl(child, depth + 1, remaining, applicationId, allowAddressFields, inToolbar);
                if (!result.isEmpty())
                    break;
            }
        }
        CFRelease(children);
    }
    return result;
}

static QString focusedDocumentUrl(AXUIElementRef application, const QString &applicationId)
{
    CFTypeRef focused = nullptr;
    if (AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute, &focused) != kAXErrorSuccess)
        return {};
    QString url;
    bool reachedWindow = false;
    const int maximumDepth = applicationId == "com.vivaldi.Vivaldi" ? 32 : 16;
    for (int depth = 0; focused && depth < maximumDepth; ++depth) {
        if (CFGetTypeID(focused) != AXUIElementGetTypeID())
            break;
        auto element = static_cast<AXUIElementRef>(focused);
        AXUIElementSetMessagingTimeout(element, 0.05);
        const QString role = attributeText(element, kAXRoleAttribute);
        if (role == "AXWindow" || role == "AXApplication") {
            reachedWindow = true;
            break;
        }
        if (role == "AXWebArea") {
            QString candidate = attributeText(element, kAXURLAttribute);
            if (!isFullUrl(candidate))
                candidate = attributeText(element, kAXDocumentAttribute);
            // Keep the outer document URL rather than an embedded iframe's address.
            if (!isBrowserInterfaceUrl(applicationId, candidate))
                url = isFullUrl(candidate) ? candidate : QString();
        }
        CFTypeRef parent = nullptr;
        AXUIElementCopyAttributeValue(element, kAXParentAttribute, &parent);
        CFRelease(focused);
        focused = parent;
    }
    if (focused)
        CFRelease(focused);
    return reachedWindow ? url : QString();
}

static bool hasSelectedBrowserTab(AXUIElementRef element, int depth, int &remaining, bool inTabGroup = false);
static AXUIElementRef tabCloseControl(AXUIElementRef tab, int depth);

static BrowserResult readAccessibleWindow(NSRunningApplication *app)
{
    if (!accessibilityAccess())
        return {{}, "Enable UrlDetection in System Settings > Privacy & Security > Accessibility, then click Retry permissions."};
    const pid_t pid = applicationProcessId(app.processIdentifier, app.executableURL.path);
    if (pid <= 0)
        return {};
    AXUIElementRef application = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(application, 0.2);
    // Firefox initializes its page accessibility tree when the application role is requested.
    attributeText(application, kAXRoleAttribute);
    const QString id = QString::fromNSString(app.bundleIdentifier);
    // Opera does not expose page web areas until Chromium accessibility is requested.
    if (id == "com.operasoftware.Opera" || id == "com.operasoftware.OperaGX")
        AXUIElementSetAttributeValue(application, CFSTR("AXEnhancedUserInterface"), kCFBooleanTrue);
    CFTypeRef window = nullptr;
    BrowserResult result;
    const AXError error = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute, &window);
    if (error == kAXErrorSuccess) {
        if (CFGetTypeID(window) == AXUIElementGetTypeID()) {
            auto element = static_cast<AXUIElementRef>(window);
            AXUIElementSetMessagingTimeout(element, 0.1);
            result.title = attributeText(element, kAXTitleAttribute);
            int tabBudget = 300;
            // Yandex retains a stale web area after closing its last tab; it is no longer an active document.
            if (id == "ru.yandex.desktop.yandex-browser" && !hasSelectedBrowserTab(element, 0, tabBudget)) {
                CFRelease(window);
                CFRelease(application);
                return result;
            }
            const bool browser = isSupportedBrowser(id);
            if (browser)
                result.url = focusedDocumentUrl(application, id);
            int remaining = id == "com.vivaldi.Vivaldi" ? 300 : 100;
            if (result.url.isEmpty())
                result.url = documentUrl(element, 0, remaining, id, !browser);
        }
        CFRelease(window);
    } else if (error == kAXErrorAPIDisabled) {
        result.error = "Accessibility access is disabled. Enable it in System Settings, then retry.";
    }
    CFRelease(application);
    return result;
}

static bool browserAutomationGranted(NSRunningApplication *app)
{
    const pid_t pid = applicationProcessId(app.processIdentifier, app.executableURL.path);
    if (pid <= 0)
        return false;
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithProcessIdentifier:pid];
    // This preflight runs only in the reader subprocess and never requests consent.
    return target && AEDeterminePermissionToAutomateTarget(target.aeDesc, kAECoreSuite, kAEGetData, false) == noErr;
}

BrowserResult readBrowserUrl(const QString &id, bool allowAutomationPrompt)
{
    @autoreleasepool {
        NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
        if (QString::fromNSString(app.bundleIdentifier) != id)
            return {};

        const QString source = browserUrlScript(id);
        if (source.isEmpty() || (!allowAutomationPrompt && !browserAutomationGranted(app))) {
            const BrowserResult result = readAccessibleWindow(app);
            if (QString::fromNSString(NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier) != id)
                return {};
            return result;
        }

        NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source.toNSString()];
        NSDictionary *error = nil;
        NSAppleEventDescriptor *reply = [script executeAndReturnError:&error];
        QString url = QString::fromNSString([reply descriptorAtIndex:1].stringValue);
        QString title = QString::fromNSString([reply descriptorAtIndex:2].stringValue);
        QString message;
        if (error) {
            const int code = [error[NSAppleScriptErrorNumber] intValue];
            message = code == -1743
                ? "Automation access denied. Enable this browser for UrlDetection in System Settings > Privacy & Security > Automation, then retry."
                : "Cannot read the active tab: " + QString::fromNSString(error[NSAppleScriptErrorMessage]);
        }
        [script release];
        if (QString::fromNSString(NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier) != id)
            return {};
        if ((!message.isEmpty() || !isFullUrl(url) || title.trimmed().isEmpty()) && accessibilityAccess()) {
            const BrowserResult fallback = readAccessibleWindow(app);
            if (QString::fromNSString(NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier) != id)
                return {};
            if (message.isEmpty() && isFullUrl(url)) {
                if (title.trimmed().isEmpty() && !fallback.title.trimmed().isEmpty()
                    && (fallback.url.isEmpty() || fallback.url == url))
                    title = fallback.title;
            } else if (isFullUrl(fallback.url) || (fallback.error.isEmpty() && !fallback.title.isEmpty())) {
                return fallback;
            }
        }
        return {url, message, title};
    }
}

static bool trueAttribute(AXUIElementRef element, CFStringRef attribute)
{
    CFTypeRef value = nullptr;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess)
        return false;
    int number = 0;
    const bool result = (CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(static_cast<CFBooleanRef>(value)))
        || (CFGetTypeID(value) == CFNumberGetTypeID()
            && CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberIntType, &number) && number == 1);
    CFRelease(value);
    return result;
}

static bool hasSelectedBrowserTab(AXUIElementRef element, int depth, int &remaining, bool inTabGroup)
{
    if (depth > 24 || --remaining < 0)
        return false;
    AXUIElementSetMessagingTimeout(element, 0.05);
    const auto role = attributeText(element, kAXRoleAttribute);
    if (role == "AXWebArea" || role == "AXStaticText" || role == "AXLink" || role == "AXTextArea")
        return false;
    inTabGroup = inTabGroup || role == "AXTabGroup";
    if ((role == "AXRadioButton" || role == "AXTab")
        && (trueAttribute(element, kAXSelectedAttribute) || trueAttribute(element, kAXValueAttribute))) {
        if (inTabGroup || role == "AXTab")
            return true;
        // Yandex also exposes tabs directly in an AXGroup, with their own close child.
        if (auto close = tabCloseControl(element, 0)) {
            CFRelease(close);
            return true;
        }
    }
    CFTypeRef children = nullptr;
    bool found = false;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children) == kAXErrorSuccess) {
        if (CFGetTypeID(children) == CFArrayGetTypeID()) {
            const auto array = static_cast<CFArrayRef>(children);
            for (CFIndex i = 0; i < CFArrayGetCount(array) && remaining > 0; ++i) {
                const auto child = static_cast<AXUIElementRef>(CFArrayGetValueAtIndex(array, i));
                if (CFGetTypeID(child) == AXUIElementGetTypeID() && hasSelectedBrowserTab(child, depth + 1, remaining, inTabGroup)) {
                    found = true;
                    break;
                }
            }
        }
        CFRelease(children);
    }
    return found;
}

static AXUIElementRef tabCloseControl(AXUIElementRef tab, int depth = 0)
{
    if (depth > 3)
        return nullptr;
    AXUIElementSetMessagingTimeout(tab, 0.05);
    const auto role = attributeText(tab, kAXRoleAttribute);
    if (role == "AXWebArea")
        return nullptr;
    if (role == "AXButton") {
        const auto description = attributeText(tab, kAXDescriptionAttribute).trimmed().toLower();
        const auto title = attributeText(tab, kAXTitleAttribute).trimmed().toLower();
        const auto identifier = attributeText(tab, kAXIdentifierAttribute).toLower();
        if (description == "close" || description == "close tab" || title == "close tab"
            || identifier.endsWith("tab-close-button") || identifier.endsWith("close-tab-button")) {
            CFRetain(tab);
            return tab;
        }
    }
    CFTypeRef children = nullptr;
    AXUIElementRef found = nullptr;
    if (AXUIElementCopyAttributeValue(tab, kAXChildrenAttribute, &children) == kAXErrorSuccess) {
        if (CFGetTypeID(children) == CFArrayGetTypeID()) {
            const auto array = static_cast<CFArrayRef>(children);
            for (CFIndex i = 0; i < CFArrayGetCount(array) && i < 30; ++i) {
                const auto child = static_cast<AXUIElementRef>(CFArrayGetValueAtIndex(array, i));
                if (CFGetTypeID(child) == AXUIElementGetTypeID() && (found = tabCloseControl(child, depth + 1)))
                    break;
            }
        }
        CFRelease(children);
    }
    return found;
}

static void selectedTabCloseControls(AXUIElementRef element, const QString &id, int depth, int &remaining,
                                     bool inTabGroup, std::vector<AXUIElementRef> &controls)
{
    if (depth > 24 || --remaining < 0 || controls.size() > 1)
        return;
    AXUIElementSetMessagingTimeout(element, 0.05);
    const auto role = attributeText(element, kAXRoleAttribute);
    if (role == "AXWebArea" && !isBrowserInterfaceUrl(id, attributeText(element, kAXURLAttribute)))
        return;
    if (role == "AXLink" || role == "AXStaticText" || role == "AXTextArea")
        return;
    inTabGroup = inTabGroup || role == "AXTabGroup";
    if (inTabGroup && (role == "AXRadioButton" || role == "AXTab")
        && (trueAttribute(element, kAXSelectedAttribute) || trueAttribute(element, kAXValueAttribute))) {
        if (auto control = tabCloseControl(element))
            controls.push_back(control);
        return;
    }
    CFTypeRef children = nullptr;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children) == kAXErrorSuccess) {
        if (CFGetTypeID(children) == CFArrayGetTypeID()) {
            const auto array = static_cast<CFArrayRef>(children);
            for (CFIndex i = 0; i < CFArrayGetCount(array) && remaining > 0; ++i) {
                const auto child = static_cast<AXUIElementRef>(CFArrayGetValueAtIndex(array, i));
                if (CFGetTypeID(child) == AXUIElementGetTypeID())
                    selectedTabCloseControls(child, id, depth + 1, remaining, inTabGroup, controls);
            }
        }
        CFRelease(children);
    }
}

static void closeTabMenuItems(AXUIElementRef element, const QString &id, int depth, int &remaining,
                              std::vector<AXUIElementRef> &tabs, AXUIElementRef &singleSafariWindow,
                              bool &disabledCloseTab)
{
    if (depth > 4 || --remaining < 0)
        return;
    AXUIElementSetMessagingTimeout(element, 0.05);
    if (attributeText(element, kAXRoleAttribute) == "AXMenuItem") {
        const auto title = attributeText(element, kAXTitleAttribute).trimmed().toLower();
        const bool enabled = trueAttribute(element, kAXEnabledAttribute);
        if (title == "close tab" && !enabled)
            disabledCloseTab = true;
        if ((title == "close tab" || title == "close current tab"
             || (id == "company.thebrowser.Browser" && title == "archive tab")) && enabled) {
            CFRetain(element);
            tabs.push_back(element);
        }
        if (title == "close window" && enabled && !singleSafariWindow
            && attributeText(element, kAXMenuItemCmdCharAttribute).toLower() == "w") {
            CFTypeRef modifiers = nullptr;
            int number = -1;
            if (AXUIElementCopyAttributeValue(element, kAXMenuItemCmdModifiersAttribute, &modifiers) == kAXErrorSuccess) {
                if (CFGetTypeID(modifiers) == CFNumberGetTypeID()
                    && CFNumberGetValue(static_cast<CFNumberRef>(modifiers), kCFNumberIntType, &number) && number == 0) {
                    singleSafariWindow = element;
                    CFRetain(element);
                }
                CFRelease(modifiers);
            }
        }
    }
    CFTypeRef children = nullptr;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children) == kAXErrorSuccess) {
        if (CFGetTypeID(children) == CFArrayGetTypeID()) {
            const auto array = static_cast<CFArrayRef>(children);
            for (CFIndex i = 0; i < CFArrayGetCount(array) && remaining > 0; ++i) {
                const auto child = static_cast<AXUIElementRef>(CFArrayGetValueAtIndex(array, i));
                if (CFGetTypeID(child) == AXUIElementGetTypeID())
                    closeTabMenuItems(child, id, depth + 1, remaining, tabs, singleSafariWindow, disabledCloseTab);
            }
        }
        CFRelease(children);
    }
}

QString requestCloseBrowserTab(const QString &id, const QString &expectedUrl, bool allowAutomationPrompt)
{
    @autoreleasepool {
        NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
        if (!isSupportedBrowser(id) || !isFullUrl(expectedUrl) || QString::fromNSString(app.bundleIdentifier) != id)
            return "Browser focus changed; no tab was closed.";
        const pid_t pid = applicationProcessId(app.processIdentifier, app.executableURL.path);
        if (pid <= 0)
            return "Cannot identify the browser process; no tab was closed.";
        if (accessibilityAccess()) {
            AXUIElementRef root = AXUIElementCreateApplication(pid);
            AXUIElementSetMessagingTimeout(root, 0.1);
            CFTypeRef value = nullptr;
            if (AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute, &value) == kAXErrorSuccess) {
                if (CFGetTypeID(value) == AXUIElementGetTypeID()) {
                    const auto window = static_cast<AXUIElementRef>(value);
                    int remaining = 300;
                    std::vector<AXUIElementRef> controls;
                    const bool preferMenu = id == "com.apple.Safari" || id == "com.apple.SafariTechnologyPreview"
                        || id == "org.uc.UC" || id == "ru.yandex.desktop.yandex-browser"
                        || id == "company.thebrowser.Browser" || id == "com.operasoftware.Opera"
                        || id == "com.operasoftware.OperaGX" || id == "com.vivaldi.Vivaldi";
                    if (!preferMenu)
                        selectedTabCloseControls(window, id, 0, remaining, false, controls);
                    if (controls.empty()) {
                        CFTypeRef menu = nullptr;
                        if (AXUIElementCopyAttributeValue(root, kAXMenuBarAttribute, &menu) == kAXErrorSuccess) {
                            if (CFGetTypeID(menu) == AXUIElementGetTypeID()) {
                                AXUIElementRef singleWindow = nullptr;
                                bool disabledTab = false;
                                remaining = 600;
                                closeTabMenuItems(static_cast<AXUIElementRef>(menu), id, 0, remaining, controls, singleWindow, disabledTab);
                                // Safari changes Command-W to Close Window only when its tab is the last one.
                                if (controls.empty() && browserReader(id) == BrowserReader::Safari && disabledTab && singleWindow) {
                                    CFRetain(singleWindow);
                                    controls.push_back(singleWindow);
                                }
                                if (singleWindow)
                                    CFRelease(singleWindow);
                            }
                            CFRelease(menu);
                        }
                    }
                    if (preferMenu && controls.empty()) {
                        remaining = 300;
                        selectedTabCloseControls(window, id, 0, remaining, false, controls);
                    }
                    // Only press a selected browser tab's close control, never a window close button.
                    const auto current = readAccessibleWindow(app);
                    CFTypeRef focused = nullptr;
                    const bool sameWindow = AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute, &focused) == kAXErrorSuccess
                        && CFEqual(window, focused);
                    if (focused)
                        CFRelease(focused);
                    const bool currentBrowser = QString::fromNSString(NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier) == id;
                    bool pressed = false;
                    if (controls.size() == 1 && sameWindow && currentBrowser && current.error.isEmpty() && current.url == expectedUrl)
                        pressed = AXUIElementPerformAction(controls.front(), kAXPressAction) == kAXErrorSuccess;
                    for (auto control : controls)
                        CFRelease(control);
                    if (pressed) {
                        CFRelease(value);
                        CFRelease(root);
                        return {};
                    }
                }
                CFRelease(value);
            }
            CFRelease(root);
        }
        const auto source = browserCloseTabScript(id, expectedUrl);
        if (source.isEmpty())
            return "This browser did not expose a supported active-tab close control. No tab was closed.";
        if (!allowAutomationPrompt && !browserAutomationGranted(app))
            return "Tab closing needs browser Automation access. Enable Allow browser Automation permission prompts, then retry.";
        if (QString::fromNSString(NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier) != id)
            return "Browser focus changed; no tab was closed.";
        NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source.toNSString()];
        NSDictionary *error = nil;
        NSAppleEventDescriptor *reply = [script executeAndReturnError:&error];
        const bool requested = reply.booleanValue;
        const auto message = error ? QString::fromNSString(error[NSAppleScriptErrorMessage]) : QString();
        [script release];
        return !message.isEmpty() ? "Could not close the browser tab: " + message
            : requested ? QString() : "The active tab changed; no tab was closed.";
    }
}
