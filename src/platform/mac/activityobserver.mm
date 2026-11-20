#include "detection/activitytrigger.h"
#include "detection/browserprobe.h"
#include "macprocess.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <vector>

struct ActivityObserverState {
    id activationToken = nil;
    AXObserverRef observer = nullptr;
    std::vector<std::pair<AXUIElementRef, CFStringRef>> subscriptions;

    void clearAccessibility()
    {
        if (!observer)
            return;
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes);
        for (const auto &entry : subscriptions) {
            AXObserverRemoveNotification(observer, entry.first, entry.second);
            CFRelease(entry.first);
        }
        subscriptions.clear();
        CFRelease(observer);
        observer = nullptr;
    }

    void subscribe(AXUIElementRef element, CFStringRef notification, ActivityTrigger *trigger)
    {
        if (AXObserverAddNotification(observer, element, notification, trigger) == kAXErrorSuccess) {
            CFRetain(element);
            subscriptions.emplace_back(element, notification);
        }
        // Unsupported notifications are covered by the slower fallback check.
    }
};

static AXUIElementRef elementAttribute(AXUIElementRef element, CFStringRef attribute)
{
    CFTypeRef value = nullptr;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess)
        return nullptr;
    if (CFGetTypeID(value) == AXUIElementGetTypeID())
        return static_cast<AXUIElementRef>(value);
    CFRelease(value);
    return nullptr;
}

static void accessibilityChanged(AXObserverRef, AXUIElementRef, CFStringRef, void *context)
{
    static_cast<ActivityTrigger *>(context)->requestCheck();
}

static bool attributeEquals(AXUIElementRef element, CFStringRef attribute, CFStringRef expected)
{
    CFTypeRef value = nullptr;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess)
        return false;
    const bool equal = CFEqual(value, expected);
    CFRelease(value);
    return equal;
}

void ActivityTrigger::startNative()
{
    auto *state = new ActivityObserverState;
    nativeState = state;
    state->activationToken = [[NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *) {
            requestCheck();
        }] retain];
}

void ActivityTrigger::stopNative()
{
    auto *state = static_cast<ActivityObserverState *>(nativeState);
    if (!state)
        return;
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:state->activationToken];
    [state->activationToken release];
    state->clearAccessibility();
    delete state;
    nativeState = nullptr;
}

void ActivityTrigger::refreshNative()
{
    @autoreleasepool {
        auto *state = static_cast<ActivityObserverState *>(nativeState);
        if (!state)
            return;
        state->clearAccessibility();
        NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
        if (!app || app.processIdentifier == NSProcessInfo.processInfo.processIdentifier
            || [app.bundleIdentifier isEqualToString:@"com.urldetection.desktop"] || !accessibilityAccess())
            return;
        const pid_t pid = applicationProcessId(app.processIdentifier, app.executableURL.path);
        if (pid <= 0 || AXObserverCreate(pid, accessibilityChanged, &state->observer) != kAXErrorSuccess)
            return;
        AXUIElementRef application = AXUIElementCreateApplication(pid);
        AXUIElementSetMessagingTimeout(application, 0.05);
        // Requesting the root role also wakes Firefox's accessibility tree.
        CFTypeRef role = nullptr;
        if (AXUIElementCopyAttributeValue(application, kAXRoleAttribute, &role) == kAXErrorSuccess)
            CFRelease(role);
        for (auto notification : {kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                                  kAXFocusedUIElementChangedNotification, kAXWindowCreatedNotification})
            state->subscribe(application, notification, this);
        AXUIElementRef window = elementAttribute(application, kAXFocusedWindowAttribute);
        if (window) {
            AXUIElementSetMessagingTimeout(window, 0.05);
            for (auto notification : {kAXTitleChangedNotification, kAXSelectedChildrenChangedNotification,
                                      kAXLayoutChangedNotification, kAXUIElementDestroyedNotification})
                state->subscribe(window, notification, this);
        }

        // Watch the focused control and its ancestors, without walking page contents.
        AXUIElementRef element = elementAttribute(application, kAXFocusedUIElementAttribute);
        AXUIElementRef addressField = nullptr;
        for (int depth = 0; element && depth < 10; ++depth) {
            AXUIElementSetMessagingTimeout(element, 0.05);
            for (auto notification : {kAXTitleChangedNotification, kAXSelectedChildrenChangedNotification,
                                      CFSTR("AXLoadComplete"), kAXUIElementDestroyedNotification})
                state->subscribe(element, notification, this);
            if (depth == 0
                && (attributeEquals(element, kAXRoleAttribute, kAXTextFieldRole)
                    || attributeEquals(element, kAXRoleAttribute, kAXComboBoxRole))
                && !attributeEquals(element, kAXSubroleAttribute, kAXSecureTextFieldSubrole)) {
                addressField = element;
                CFRetain(addressField);
            }
            if (addressField && attributeEquals(element, kAXRoleAttribute, kAXToolbarRole)) {
                state->subscribe(addressField, kAXValueChangedNotification, this);
                CFRelease(addressField);
                addressField = nullptr;
            }
            if (attributeEquals(element, kAXRoleAttribute, CFSTR("AXWebArea")))
                state->subscribe(element, kAXValueChangedNotification, this);
            AXUIElementRef parent = elementAttribute(element, kAXParentAttribute);
            const bool atWindow = window && CFEqual(element, window);
            CFRelease(element);
            element = parent;
            if (atWindow)
                break;
        }
        if (element)
            CFRelease(element);
        if (addressField)
            CFRelease(addressField);
        if (window)
            CFRelease(window);
        CFRelease(application);
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(state->observer), kCFRunLoopCommonModes);
    }
}
