#include "browserprobe.h"
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
