#include "browserprobe.h"
#include "macprocess.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
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

static QString documentUrl(AXUIElementRef element, int depth, int &remaining, bool inToolbar = false)
{
    if (depth > 12 || --remaining < 0)
        return {};
    AXUIElementSetMessagingTimeout(element, 0.1);
    const QString role = attributeText(element, kAXRoleAttribute);
    // Page links, body text and password fields are not the active document's address.
    if (role == "AXLink" || role == "AXStaticText" || role == "AXTextArea" || role == "AXSecureTextField"
        || attributeText(element, kAXSubroleAttribute) == "AXSecureTextField")
        return {};
    QString url = attributeText(element, kAXDocumentAttribute);
    if (isFullUrl(url))
        return url;
    if (role == "AXWebArea") {
        url = attributeText(element, kAXURLAttribute);
        return isFullUrl(url) ? url : QString();
    }
    inToolbar = inToolbar || role == "AXToolbar";
    if (inToolbar && (role == "AXTextField" || role == "AXComboBox")) {
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
                result = documentUrl(child, depth + 1, remaining, inToolbar);
                if (!result.isEmpty())
                    break;
            }
        }
        CFRelease(children);
    }
    return result;
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
    CFTypeRef window = nullptr;
    BrowserResult result;
    const AXError error = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute, &window);
    if (error == kAXErrorSuccess) {
        if (CFGetTypeID(window) == AXUIElementGetTypeID()) {
            auto element = static_cast<AXUIElementRef>(window);
            AXUIElementSetMessagingTimeout(element, 0.1);
            result.title = attributeText(element, kAXTitleAttribute);
            int remaining = 100;
            result.url = documentUrl(element, 0, remaining);
        }
        CFRelease(window);
    } else if (error == kAXErrorAPIDisabled) {
        result.error = "Accessibility access is disabled. Enable it in System Settings, then retry.";
    }
    CFRelease(application);
    return result;
}

BrowserResult readBrowserUrl(const QString &id)
{
    @autoreleasepool {
        NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
        if (QString::fromNSString(app.bundleIdentifier) != id)
            return {};

        if (!isSupportedBrowser(id) || id == "org.mozilla.firefox") {
            const BrowserResult result = readAccessibleWindow(app);
            if (QString::fromNSString(NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier) != id)
                return {};
            return result;
        }

        // Only fixed, supported bundle IDs enter the script; no URL or page text is executed.
        const bool safari = id.startsWith("com.apple.Safari");
        QString source = "with timeout of 3 seconds\ntell application id \"" + id
            + "\"\nif (count of windows) is 0 then return {\"\", \"\"}\nset selectedTab to "
            + (safari ? "current tab" : "active tab")
            + " of front window\nreturn {URL of selectedTab, "
            + (safari ? "name" : "title")
            + " of selectedTab}\nend tell\nend timeout";
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
        return {url, message, title};
    }
}
