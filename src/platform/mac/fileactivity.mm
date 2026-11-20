#include "uploads/fileactivity.h"
#include "macprocess.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#include <QCoreApplication>
#include <QDateTime>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRectF>
#include <QSet>
#include <QTimer>
#include <QUuid>
#include <QUrl>
#include <cstdio>
#include <cmath>
#include <algorithm>

namespace {
CFTypeRef attribute(AXUIElementRef element, CFStringRef key)
{
    CFTypeRef value = nullptr;
    if (element) {
        AXUIElementSetMessagingTimeout(element, 0.025);
        AXUIElementCopyAttributeValue(element, key, &value);
    }
    return value;
}

QString text(AXUIElementRef element, CFStringRef key)
{
    const auto value = attribute(element, key);
    QString result;
    if (value && CFGetTypeID(value) == CFStringGetTypeID())
        result = QString::fromCFString(static_cast<CFStringRef>(value));
    else if (value && CFGetTypeID(value) == CFURLGetTypeID())
        result = QString::fromCFString(CFURLGetString(static_cast<CFURLRef>(value)));
    if (value) CFRelease(value);
    return result;
}

bool flag(AXUIElementRef element, CFStringRef key)
{
    const auto value = attribute(element, key);
    int number = 0;
    const bool result = value && ((CFGetTypeID(value) == CFBooleanGetTypeID()
        && CFBooleanGetValue(static_cast<CFBooleanRef>(value)))
        || (CFGetTypeID(value) == CFNumberGetTypeID()
            && CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberIntType, &number) && number == 1));
    if (value) CFRelease(value);
    return result;
}

template<typename Function>
void elements(AXUIElementRef element, CFStringRef key, Function function)
{
    const auto value = attribute(element, key);
    if (value && CFGetTypeID(value) == CFArrayGetTypeID()) {
        const auto array = static_cast<CFArrayRef>(value);
        for (CFIndex i = 0; i < CFArrayGetCount(array) && i < 300; ++i) {
            const auto child = static_cast<AXUIElementRef>(CFArrayGetValueAtIndex(array, i));
            if (CFGetTypeID(child) == AXUIElementGetTypeID()) function(child);
        }
    }
    if (value) CFRelease(value);
}

QString resolvedFileReference(const QString &reference)
{
    if (!reference.startsWith("file:", Qt::CaseInsensitive)) return reference;
    NSURL *url = [NSURL URLWithString:reference.toNSString()];
    if (!url.isFileURL || url.query || url.fragment || url.user || url.password || (url.host.length && ![url.host.lowercaseString isEqualToString:@"localhost"])) return {};
    NSURL *resolved = url.filePathURL;
    return resolved ? QString::fromNSString(resolved.absoluteString) : QString();
}

struct Selection {
    QStringList paths;
    bool truncated = false;
};

void selectedPaths(AXUIElementRef element, int depth, int &budget, QElapsedTimer &elapsed,
                   Selection &selection, bool selectedScope = false)
{
    if (depth > 22 || --budget < 0 || elapsed.elapsed() > 350) {
        selection.truncated = true;
        return;
    }
    const auto role = text(element, kAXRoleAttribute);
    if (role == "AXWebArea" || role == "AXLink" || role == "AXSecureTextField")
        return;
    const bool selected = selectedScope || flag(element, kAXSelectedAttribute);
    if (selected) {
        for (const auto key : {kAXURLAttribute, kAXDocumentAttribute}) {
            const auto paths = localFileReferences({resolvedFileReference(text(element, key))});
            for (const auto &path : paths) {
                if (!QFileInfo(path).isDir() && !selection.paths.contains(path)) selection.paths.append(path);
            }
        }
    }
    for (const auto key : {kAXSelectedChildrenAttribute, kAXSelectedRowsAttribute}) {
        bool hasSelection = false;
        elements(element, key, [&](AXUIElementRef child) {
            hasSelection = true;
            selectedPaths(child, depth + 1, budget, elapsed, selection, true);
        });
        if (hasSelection) return; // Avoid scanning the same selection again through all children.
    }
    // Unselected file rows can contain thousands of unrelated entries; do not enumerate them.
    if ((role == "AXRow" || role == "AXCell") && !selected)
        return;
    elements(element, kAXChildrenAttribute, [&](AXUIElementRef child) {
        selectedPaths(child, depth + 1, budget, elapsed, selection, selected);
    });
}

Selection selectionIn(AXUIElementRef panel)
{
    Selection result;
    int budget = 700;
    QElapsedTimer elapsed;
    elapsed.start();
    selectedPaths(panel, 0, budget, elapsed, result);
    result.paths = localFileReferences(result.paths, &result.truncated);
    return result;
}

QRectF rectangle(AXUIElementRef element)
{
    CGPoint position{};
    CGSize size{};
    const auto p = attribute(element, kAXPositionAttribute);
    const auto s = attribute(element, kAXSizeAttribute);
    const bool valid = p && s && CFGetTypeID(p) == AXValueGetTypeID() && CFGetTypeID(s) == AXValueGetTypeID()
        && AXValueGetValue(static_cast<AXValueRef>(p), static_cast<AXValueType>(kAXValueCGPointType), &position)
        && AXValueGetValue(static_cast<AXValueRef>(s), static_cast<AXValueType>(kAXValueCGSizeType), &size);
    if (p) CFRelease(p);
    if (s) CFRelease(s);
    return valid ? QRectF(position.x, position.y, size.width, size.height) : QRectF();
}

struct Context {
    pid_t pid = 0;
    QString id;
    QString name;
};

Context contextFor(NSRunningApplication *app)
{
    if (!app) return {};
    return {applicationProcessId(app.processIdentifier, app.executableURL.path),
        QString::fromNSString(app.bundleIdentifier), QString::fromNSString(app.localizedName)};
}

bool ignored(const Context &context)
{
    return context.pid <= 0 || context.id == "com.urldetection.desktop" || context.id == "com.apple.finder";
}

Context foreground()
{
    return contextFor(NSWorkspace.sharedWorkspace.frontmostApplication);
}

Context applicationAt(CGPoint point)
{
    AXUIElementRef system = AXUIElementCreateSystemWide();
    AXUIElementRef element = nullptr;
    AXUIElementSetMessagingTimeout(system, 0.025);
    AXUIElementCopyElementAtPosition(system, point.x, point.y, &element);
    CFRelease(system);
    pid_t pid = 0;
    for (int depth = 0; element && depth < 20; ++depth) {
        AXUIElementGetPid(element, &pid);
        if (text(element, kAXRoleAttribute) == "AXWindow") break;
        const auto parent = attribute(element, kAXParentAttribute);
        CFRelease(element);
        element = parent && CFGetTypeID(parent) == AXUIElementGetTypeID() ? static_cast<AXUIElementRef>(parent) : nullptr;
        if (parent && !element) CFRelease(parent);
    }
    if (element) CFRelease(element);
    if (pid > 0) {
        const auto target = contextFor([NSRunningApplication runningApplicationWithProcessIdentifier:pid]);
        if (target.pid > 0) return target;
    }
    // Bounds and owner PID remain usable without taking a screenshot or reading window contents.
    const auto windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    Context result;
    for (NSDictionary *window in (__bridge NSArray *)windows) {
        if ([window[(id)kCGWindowLayer] intValue] != 0) continue;
        CGRect bounds{};
        if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds], &bounds)
            && CGRectContainsPoint(bounds, point)) {
            result = contextFor([NSRunningApplication runningApplicationWithProcessIdentifier:[window[(id)kCGWindowOwnerPID] intValue]]);
            break;
        }
    }
    if (windows) CFRelease(windows);
    return result;
}

struct PasteboardFiles {
    QStringList paths;
    bool fileData = false;
    bool truncated = false;
    bool promise = false;
};

PasteboardFiles pasteboardFiles(NSPasteboard *board, bool allowImage = false)
{
    PasteboardFiles result;
    QStringList references;
    for (NSURL *url in [board readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}]) {
        result.fileData = true;
        if (references.size() < 300) references.append(resolvedFileReference(QString::fromNSString(url.absoluteString)));
        else result.truncated = true;
    }
    id legacy = [board propertyListForType:@"NSFilenamesPboardType"];
    if ([legacy isKindOfClass:NSArray.class])
        for (id path in legacy) {
            if (![path isKindOfClass:NSString.class]) continue;
            result.fileData = true;
            if (references.size() < 300) references.append(QString::fromNSString(path));
            else result.truncated = true;
        }
    int count = 0;
    for (NSPasteboardItem *item in board.pasteboardItems) {
        if (++count > 300) { result.truncated = true; break; }
        NSString *url = [item stringForType:NSPasteboardTypeFileURL];
        if (url) { result.fileData = true; references.append(resolvedFileReference(QString::fromNSString(url))); }
    }
    for (NSString *type in board.types) {
        if ([type rangeOfString:@"filepromise" options:NSCaseInsensitiveSearch].location != NSNotFound
            || [type isEqualToString:@"NSFilesPromisePboardType"]) result.promise = true;
        if (allowImage && ([type isEqualToString:NSPasteboardTypePNG] || [type isEqualToString:NSPasteboardTypeTIFF]))
            result.fileData = true; // Inspect the type only, never fetch image data or invent an original path.
    }
    bool capped = false;
    result.paths = localFileReferences(references, &capped);
    result.truncated = result.truncated || capped;
    result.paths.erase(std::remove_if(result.paths.begin(), result.paths.end(), [](const QString &path) {
        return QFileInfo(path).isDir();
    }), result.paths.end());
    return result;
}

bool isConfirm(AXUIElementRef button)
{
    const auto title = text(button, kAXTitleAttribute).trimmed().toLower();
    const auto identifier = text(button, kAXIdentifierAttribute).toLower();
    return identifier.contains("nsnavopenbutton") || QStringList{
        "open", "upload", "attach", "choose", "select", "send", "add", "open files", "choose files", "choose file"
    }.contains(title);
}

struct PanelShape {
    AXUIElementRef confirm = nullptr;
    bool cancel = false;
    bool list = false;
};

void panelShape(AXUIElementRef element, int depth, int &budget, QElapsedTimer &elapsed, PanelShape &shape)
{
    if (depth > 14 || --budget < 0 || elapsed.elapsed() > 200) return;
    const auto role = text(element, kAXRoleAttribute);
    if (role == "AXWebArea" || role == "AXSecureTextField") return;
    if (QStringList{"AXBrowser", "AXOutline", "AXTable", "AXList", "AXPathControl"}.contains(role)) { shape.list = true; return; }
    if (role == "AXButton") {
        if (!shape.confirm && isConfirm(element)) { shape.confirm = element; CFRetain(element); }
        if (text(element, kAXTitleAttribute).trimmed().toLower() == "cancel"
            || text(element, kAXIdentifierAttribute).toLower().contains("nsnavcancelbutton")) shape.cancel = true;
    }
    if (shape.list && shape.confirm && shape.cancel) return;
    // The rows themselves cannot contain the dialog's Open/Cancel buttons.
    if (role == "AXRow" || role == "AXCell") return;
    elements(element, kAXChildrenAttribute, [&](AXUIElementRef child) { panelShape(child, depth + 1, budget, elapsed, shape); });
}

struct FoundPanel { AXUIElementRef panel = nullptr; AXUIElementRef confirm = nullptr; };

FoundPanel locatePanel(AXUIElementRef element, int depth, int &budget, QElapsedTimer &elapsed)
{
    if (depth > 8 || --budget < 0 || elapsed.elapsed() > 400) return {};
    const auto role = text(element, kAXRoleAttribute);
    if (role == "AXWebArea") return {};
    if (role == "AXWindow") {
        FoundPanel sheet;
        for (const auto key : {CFSTR("AXSheets"), kAXChildrenAttribute})
            elements(element, key, [&](AXUIElementRef child) {
                const auto childRole = text(child, kAXRoleAttribute);
                if (!sheet.panel && (childRole == "AXSheet" || childRole == "AXDialog"))
                    sheet = locatePanel(child, depth + 1, budget, elapsed);
            });
        if (sheet.panel) return sheet; // Keep document/sidebar selections outside the chooser out of capture.
    }
    if (role == "AXSheet" || role == "AXWindow" || role == "AXDialog") {
        PanelShape shape;
        int nodes = 500;
        QElapsedTimer timer; timer.start();
        panelShape(element, 0, nodes, timer, shape);
        if (shape.confirm && shape.cancel && shape.list) {
            CFRetain(element);
            return {element, shape.confirm};
        }
        if (shape.confirm) CFRelease(shape.confirm);
    }
    FoundPanel result;
    for (const auto key : {CFSTR("AXSheets"), kAXChildrenAttribute})
        elements(element, key, [&](AXUIElementRef child) {
            if (!result.panel) result = locatePanel(child, depth + 1, budget, elapsed);
        });
    return result;
}

class FileActivityWorker : public QObject
{
public:
    explicit FileActivityWorker(QCoreApplication &app) : application(app)
    {
        clock.start();
        immediatePoll.setSingleShot(true);
        connect(&immediatePoll, &QTimer::timeout, this, [this] { pollTimer.stop(); poll(); pollTimer.start(250); });
        pollTimer.setSingleShot(true);
        connect(&pollTimer, &QTimer::timeout, this, [this] { poll(); pollTimer.start(250); });
        pollTimer.start(250);
        connect(&heartbeat, &QTimer::timeout, this, [this] { sendLine("alive\n"); });
        heartbeat.start(5000);
        sendLine("alive\n");
        if (AXIsProcessTrusted()) {
            tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
                CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventLeftMouseDown)
                | CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventLeftMouseUp), callback, this);
        }
        if (tap) {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
            if (source) CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
            CGEventTapEnable(tap, true);
        }
        emitJson({{"kind", "status"}, {"message", tap && source
            ? "File gestures and dialogs are being observed. Only exposed paths are captured; uploads are not verified."
            : "Input capture is unavailable. Enable Accessibility and, if required, Input Monitoring, then Retry capture. File-dialog polling remains best effort."}});
    }

    ~FileActivityWorker() override
    {
        clearPanel();
        clearObserver();
        if (source) { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes); CFRelease(source); }
        if (tap) { CFMachPortInvalidate(tap); CFRelease(tap); }
    }

private:
    struct Input { CGEventType type; CGPoint point; int key; CGEventFlags flags; bool repeat; long dragBaseline; QString frontId; quint64 timestamp; long clipboardVersion; };
    static CGEventRef callback(CGEventTapProxy, CGEventType type, CGEventRef event, void *context)
    {
        auto *self = static_cast<FileActivityWorker *>(context);
        if (type == kCGEventTapDisabledByTimeout) {
            CGEventTapEnable(self->tap, true);
            return event;
        }
        if (type == kCGEventTapDisabledByUserInput) {
            self->emitJson({{"kind", "status"}, {"message", "macOS disabled input capture. Some gestures may be missed; Retry capture when permitted."}});
            return event;
        }
        const int key = type == kCGEventKeyDown ? int(CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode)) : 0;
        const auto flags = CGEventGetFlags(event);
        if (type == kCGEventKeyDown && key != 36 && key != 76 && key != 53 && !(key == 9 && (flags & kCGEventFlagMaskCommand)))
            return event; // Never inspect or record ordinary keystrokes or typed text.
        if (type == kCGEventLeftMouseDragged && self->dragQueued) return event;
        if (type == kCGEventLeftMouseDragged) self->dragQueued = true;
        if (type == kCGEventLeftMouseDown) self->dragQueued = false;
        const Input input{type, CGEventGetLocation(event), key, flags,
            type == kCGEventKeyDown && CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0,
            type == kCGEventLeftMouseDown ? [NSPasteboard pasteboardWithName:NSPasteboardNameDrag].changeCount : -1,
            QString::fromNSString(NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier), CGEventGetTimestamp(event),
            type == kCGEventKeyDown && key == 9 ? NSPasteboard.generalPasteboard.changeCount : -1};
        // Accessibility scans and pasteboard providers run after returning from the event tap.
        QTimer::singleShot(0, self, [self, input] {
            if (input.type == kCGEventLeftMouseDragged) self->dragQueued = false;
            self->input(input);
        });
        return event;
    }

    static void axChanged(AXObserverRef, AXUIElementRef, CFStringRef, void *context)
    {
        auto *self = static_cast<FileActivityWorker *>(context);
        if (!self->immediatePoll.isActive()) self->immediatePoll.start(150);
    }

    void sendLine(const QByteArray &line)
    {
        if (std::fwrite(line.constData(), 1, size_t(line.size()), stdout) != size_t(line.size()) || std::fflush(stdout) != 0)
            application.quit();
    }
    void emitJson(const QJsonObject &event) { sendLine(QJsonDocument(event).toJson(QJsonDocument::Compact) + '\n'); }

    void clearPanel()
    {
        if (panel && observer) {
            AXObserverRemoveNotification(observer, panel, kAXSelectedChildrenChangedNotification);
            AXObserverRemoveNotification(observer, panel, CFSTR("AXSelectedRowsChanged"));
        }
        if (panel) CFRelease(panel);
        if (confirm) CFRelease(confirm);
        panel = confirm = nullptr;
        selected = {};
        confirmBounds = {};
        panelId.clear();
        panelClicked = panelReported = false;
        panelGoneAt = 0;
    }
    void clearObserver()
    {
        if (observer) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes);
            CFRelease(observer);
        }
        observer = nullptr;
        observerPid = 0;
    }

    void observe(pid_t pid)
    {
        if (pid == observerPid) return;
        clearObserver();
        if (pid <= 0 || AXObserverCreate(pid, axChanged, &observer) != kAXErrorSuccess) return;
        observerPid = pid;
        auto root = AXUIElementCreateApplication(pid);
        AXUIElementSetMessagingTimeout(root, 0.025);
        for (const auto key : {kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification})
            AXObserverAddNotification(observer, root, key, this);
        CFRelease(root);
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes);
    }

    void poll()
    {
        @autoreleasepool {
            if (dragActive) refreshDrag();
            if (!AXIsProcessTrusted()) return;
            const auto owner = foreground();
            if (owner.pid <= 0 || owner.id == "com.urldetection.desktop") { clearPanel(); return; }
            observe(owner.pid);
            auto root = AXUIElementCreateApplication(owner.pid);
            AXUIElementSetMessagingTimeout(root, 0.025);
            const auto window = attribute(root, kAXFocusedWindowAttribute);
            FoundPanel found;
            int budget = 500;
            QElapsedTimer elapsed; elapsed.start();
            if (window && CFGetTypeID(window) == AXUIElementGetTypeID())
                found = locatePanel(static_cast<AXUIElementRef>(window), 0, budget, elapsed);
            if (!found.panel) {
                elements(root, kAXWindowsAttribute, [&](AXUIElementRef candidate) {
                    if (!found.panel) found = locatePanel(candidate, 0, budget, elapsed);
                });
            }
            // Focused UI can be owned by an XPC file-picker service, outside the app's window subtree.
            if (!found.panel) {
                const auto focused = attribute(root, kAXFocusedUIElementAttribute);
                AXUIElementRef current = focused && CFGetTypeID(focused) == AXUIElementGetTypeID() ? static_cast<AXUIElementRef>(focused) : nullptr;
                if (focused && !current) CFRelease(focused);
                for (int depth = 0; current && depth < 16 && !found.panel; ++depth) {
                    found = locatePanel(current, 0, budget, elapsed);
                    const auto parent = attribute(current, kAXParentAttribute);
                    CFRelease(current);
                    current = parent && CFGetTypeID(parent) == AXUIElementGetTypeID() ? static_cast<AXUIElementRef>(parent) : nullptr;
                    if (parent && !current) CFRelease(parent);
                }
                if (current) CFRelease(current);
            }
            if (window) CFRelease(window);
            CFRelease(root);
            if (foreground().pid != owner.pid) { if (found.panel) CFRelease(found.panel); if (found.confirm) CFRelease(found.confirm); return; }
            if (!found.panel) {
                // Listen-only input callbacks can arrive after the target has dismissed its chooser.
                if (panel && owner.pid == panelOwner.pid && clock.elapsed() - panelSeen <= 1500) {
                    if (!panelGoneAt) {
                        auto now = CGEventCreate(nullptr);
                        if (now) { panelGoneAt = CGEventGetTimestamp(now); CFRelease(now); }
                    }
                    return;
                }
                clearPanel(); return;
            }
            panelGoneAt = 0;
            if (!panel || !CFEqual(panel, found.panel) || panelOwner.pid != owner.pid) {
                clearPanel();
                panel = found.panel;
                confirm = found.confirm;
                panelOwner = owner;
                panelId = QUuid::createUuid().toString(QUuid::WithoutBraces);
                if (observer) {
                    AXObserverAddNotification(observer, panel, kAXSelectedChildrenChangedNotification, this);
                    AXObserverAddNotification(observer, panel, CFSTR("AXSelectedRowsChanged"), this);
                }
            } else { CFRelease(found.panel); CFRelease(found.confirm); }
            selected = selectionIn(panel);
            confirmBounds = rectangle(confirm);
            panelSeen = clock.elapsed();
        }
    }

    void report(Context destination, const QString &method, const QStringList &paths, bool unavailable,
                 const QString &detail, bool truncated = false, const QString &actionId = {})
    {
        if (ignored(destination)) return;
        emitJson({{"kind", "file_activity"}, {"actionId", actionId.isEmpty() ? QUuid::createUuid().toString(QUuid::WithoutBraces) : actionId},
            {"timestamp", QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs)},
            {"application", destination.name}, {"applicationId", destination.id}, {"applicationPid", int(destination.pid)},
            {"method", method}, {"paths", QJsonArray::fromStringList(paths)}, {"pathUnavailable", unavailable},
            {"detail", detail}, {"truncated", truncated}});
    }

    void confirmPanel()
    {
        if (!panel || panelReported || clock.elapsed() - panelSeen > 1500 || foreground().pid != panelOwner.pid) return;
        panelReported = true;
        report(panelOwner, "dialog", selected.paths, selected.paths.isEmpty(),
            selected.paths.isEmpty()
                ? "Confirmation gesture on a recognized file chooser; no selected file path was exposed. Selection, acceptance and upload are not verified."
                : "Confirmation gesture on a recognized file chooser; paths from its recent exposed selection. Dialog acceptance and upload are not verified.", selected.truncated, panelId);
    }

    void refreshDrag()
    {
        NSPasteboard *board = [NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
        if (clock.elapsed() - dragStarted > 30000) { dragActive = false; return; }
        if (board.changeCount <= dragBaseline) return;
        const auto files = pasteboardFiles(board);
        if (!files.paths.isEmpty() || files.fileData || files.promise) dragFiles = files;
    }

    void input(const Input &event)
    {
        @autoreleasepool {
            if (event.type == kCGEventKeyDown) {
                if (event.repeat) return;
                if (event.key == 53) { clearPanel(); return; }
                if ((event.key == 36 || event.key == 76) && !(event.flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate))) {
                    if (!panelGoneAt || event.timestamp <= panelGoneAt) confirmPanel();
                } else if (event.key == 9 && (event.flags & kCGEventFlagMaskCommand)) {
                    const auto destination = foreground();
                    if (ignored(destination) || destination.id != event.frontId) return;
                    NSPasteboard *board = NSPasteboard.generalPasteboard;
                    if (board.changeCount != event.clipboardVersion) return;
                    const auto files = pasteboardFiles(board, true);
                    if (!files.paths.isEmpty() || files.fileData || files.promise)
                        report(destination, "paste", files.paths, files.paths.isEmpty(),
                            files.paths.isEmpty() ? "File/image paste gesture; the clipboard exposes no original local file path. Receiving-app acceptance is not verified."
                                : "Command-V gesture with explicit file URLs in the general pasteboard; not proof that the application accepted or sent the file.", files.truncated);
                }
                return;
            }
            const QPointF point(event.point.x, event.point.y);
            if (event.type == kCGEventLeftMouseDown) {
                dragStart = event.point;
                dragStarted = clock.elapsed();
                dragBaseline = event.dragBaseline;
                dragFiles = {};
                dragActive = false;
                panelClicked = panel && !panelReported && clock.elapsed() - panelSeen <= 1500 && (!panelGoneAt || event.timestamp <= panelGoneAt) && confirmBounds.contains(point);
                if (!panel) poll();
            } else if (event.type == kCGEventLeftMouseDragged) {
                if (std::hypot(event.point.x - dragStart.x, event.point.y - dragStart.y) >= 5.0) {
                    dragActive = true;
                    panelClicked = false;
                    refreshDrag();
                }
            } else if (event.type == kCGEventLeftMouseUp) {
                if (panelClicked && confirmBounds.contains(point) && (!panelGoneAt || event.timestamp <= panelGoneAt)) confirmPanel();
                panelClicked = false;
                if (!dragActive) return;
                refreshDrag();
                dragActive = false;
                if (!dragFiles.paths.isEmpty() || dragFiles.fileData || dragFiles.promise) {
                    const auto destination = applicationAt(event.point);
                    report(destination, "drag-drop", dragFiles.paths, dragFiles.paths.isEmpty(),
                        "File-typed drag pasteboard changed during this gesture; target inferred from pointer hit-test. A drop gesture does not confirm target acceptance or transfer.", dragFiles.truncated);
                }
            }
        }
    }

    QCoreApplication &application;
    QTimer pollTimer;
    QTimer heartbeat;
    QTimer immediatePoll{this};
    QElapsedTimer clock;
    AXObserverRef observer = nullptr;
    pid_t observerPid = 0;
    CFMachPortRef tap = nullptr;
    CFRunLoopSourceRef source = nullptr;
    AXUIElementRef panel = nullptr;
    AXUIElementRef confirm = nullptr;
    Context panelOwner;
    QString panelId;
    Selection selected;
    QRectF confirmBounds;
    qint64 panelSeen = 0;
    quint64 panelGoneAt = 0;
    bool panelClicked = false;
    bool panelReported = false;
    bool dragQueued = false;
    bool dragActive = false;
    CGPoint dragStart{};
    long dragBaseline = -1;
    qint64 dragStarted = 0;
    PasteboardFiles dragFiles;
};
} // namespace

bool requestFileInputPermission() { return CGRequestListenEventAccess(); }

int runFileActivityWorker(QCoreApplication &application)
{
    FileActivityWorker worker(application);
    return application.exec();
}
