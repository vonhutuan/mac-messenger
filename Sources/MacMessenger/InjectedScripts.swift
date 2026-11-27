import Foundation

enum InjectedScripts {
    /// Desktop macOS Safari User-Agent so Facebook enables WebRTC voice/video calling.
    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"

    /// Shims `window.Notification` and `navigator.permissions.query({ name: 'notifications' })`
    /// (not natively exposed in WKWebView) and forwards notifications to Swift (`messengerNotification`).
    static let notificationShimJS = #"""
    (function() {
        if (window.__macMessengerNotificationInstalled) return;
        window.__macMessengerNotificationInstalled = true;

        const callbacks = new Map();
        let nextId = 1;
        window.__macMessengerRecentNativeNotifTs = 0;

        class NativeNotification extends EventTarget {
            static permission = "granted";

            static requestPermission(cb) {
                if (typeof cb === "function") {
                    try { cb("granted"); } catch (_) {}
                }
                return Promise.resolve("granted");
            }

            constructor(title, options = {}) {
                super();
                this._id = String(nextId++);
                this.title = String(title || "Messenger");
                this.body = options && options.body ? String(options.body) : "";
                this.icon = options && options.icon ? String(options.icon) : "";
                this.tag = options && options.tag ? String(options.tag) : "";
                this.silent = Boolean(options && options.silent);
                this.data = options ? options.data : null;
                this.onclick = null;
                this.onclose = null;
                this.onerror = null;
                this.onshow = null;

                callbacks.set(this._id, this);
                window.__macMessengerRecentNativeNotifTs = Date.now();

                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.messengerNotification) {
                        window.webkit.messageHandlers.messengerNotification.postMessage({
                            id: this._id,
                            title: this.title,
                            body: this.body,
                            icon: this.icon,
                            tag: this.tag,
                            silent: this.silent,
                            threadHref: ""
                        });
                    }
                } catch (_) {}

                setTimeout(() => {
                    if (typeof this.onshow === "function") {
                        try { this.onshow(new Event("show")); } catch (_) {}
                    }
                    this.dispatchEvent(new Event("show"));
                }, 0);
            }

            close() {
                callbacks.delete(this._id);
                if (typeof this.onclose === "function") {
                    try { this.onclose(new Event("close")); } catch (_) {}
                }
                this.dispatchEvent(new Event("close"));
            }
        }

        window.__macMessengerNotificationClicked = function(id, threadHref) {
            if (threadHref) {
                const links = document.querySelectorAll('a[href*="/messages/"]');
                for (const link of links) {
                    const href = link.getAttribute("href") || "";
                    if (href === threadHref || href.includes(threadHref)) {
                        link.click();
                        return;
                    }
                }
            }
            const notif = callbacks.get(String(id));
            if (!notif) return;
            try {
                if (typeof notif.onclick === "function") {
                    notif.onclick(new Event("click"));
                }
                notif.dispatchEvent(new Event("click"));
            } catch (_) {}
            callbacks.delete(String(id));
        };

        try {
            Object.defineProperty(window, "Notification", {
                value: NativeNotification,
                configurable: true,
                writable: true
            });
        } catch (_) {
            window.Notification = NativeNotification;
        }

        try {
            if (navigator.permissions && typeof navigator.permissions.query === "function") {
                const origQuery = navigator.permissions.query.bind(navigator.permissions);
                navigator.permissions.query = function(desc) {
                    if (desc && desc.name === "notifications") {
                        return Promise.resolve({
                            name: "notifications",
                            state: "granted",
                            onchange: null,
                            addEventListener: function() {},
                            removeEventListener: function() {},
                            dispatchEvent: function() { return false; }
                        });
                    }
                    return origQuery(desc);
                };
            }
        } catch (_) {}
    })();
    """#

    /// Scroll-safe unread counter and incoming-message watcher:
    /// - Never observes `document.body` or `[role="main"]` (prevents scroll-frame DOM work)
    /// - Skips scans while the user is actively scrolling
    /// - Avoids `innerText` and `getBoundingClientRect` loops (zero layout thrashing)
    static let unreadObserverJS = #"""
    (function() {
        if (window.__macMessengerUnreadInstalled) return;
        window.__macMessengerUnreadInstalled = true;

        let lastReportedCount = -1;
        let baselineReady = false;
        let firstThreadsSeenAt = 0;
        let lastScrollTs = 0;
        const knownThreads = new Map(); // threadKey -> { name, preview, isUnread, href }
        let domNotifCounter = 1;

        window.addEventListener("scroll", function() {
            lastScrollTs = Date.now();
        }, { capture: true, passive: true });

        window.addEventListener("wheel", function() {
            lastScrollTs = Date.now();
        }, { capture: true, passive: true });

        function parseTitleUnreadCount() {
            const title = document.title || "";
            const match = title.match(/^\((\d+)\+?\)/);
            return match ? parseInt(match[1], 10) : 0;
        }

        function parseBannerUnreadCount() {
            const banner = document.querySelector('[role="banner"]');
            if (!banner) return 0;

            let maxCount = 0;
            const candidates = banner.querySelectorAll('[aria-label*="Messenger" i], [aria-label*="Chats" i]');
            for (const el of candidates) {
                const label = el.getAttribute("aria-label") || "";
                const labelMatch = label.match(/(\d+)/);
                if (labelMatch) {
                    const n = parseInt(labelMatch[1], 10);
                    if (!Number.isNaN(n) && n > maxCount) maxCount = n;
                }
                const spans = el.querySelectorAll("span");
                for (const sp of spans) {
                    const t = (sp.textContent || "").trim();
                    if (/^\d+\+?$/.test(t)) {
                        const n = parseInt(t, 10);
                        if (!Number.isNaN(n) && n > maxCount) maxCount = n;
                    }
                }
            }
            return maxCount;
        }

        function normalizeThreadKey(href) {
            const m = href.match(/\/messages\/(?:e2ee\/)?t\/([^/?#]+)/);
            return m ? m[0] : href.split("?")[0];
        }

        function collectLeafTextSpans(root) {
            const results = [];
            const spans = root.querySelectorAll("span");
            for (const sp of spans) {
                if (sp.childElementCount > 0) continue;
                const txt = (sp.textContent || "").trim();
                if (!txt || txt === "·" || txt === "•") continue;
                results.push({ el: sp, text: txt });
            }
            return results;
        }

        function extractThreadInfo(link) {
            const href = link.getAttribute("href") || "";
            const key = normalizeThreadKey(href);
            const row = link.closest('[role="row"]') || link.closest('[role="listitem"]') || link;

            const leafSpans = collectLeafTextSpans(link);

            // Check explicit ARIA/text unread markers first (avoid matching "Mark as unread")
            let isUnread = Boolean(
                row.querySelector('[aria-label*="Mark as read" i], [aria-label*="unread message" i], [aria-label*="unread chat" i]')
            );

            let name = "";
            let preview = "";
            let previewSpan = null;

            for (const item of leafSpans) {
                const t = item.text;
                if (/^unread\b/i.test(t) || /\bunread message/i.test(t)) {
                    isUnread = true;
                    continue;
                }
                if (/^mark as read/i.test(t)) {
                    isUnread = true;
                    continue;
                }
                if (/^active\b/i.test(t) || /^\d+[smhdwy]$/i.test(t)) {
                    continue;
                }
                if (!name) {
                    name = t;
                } else if (!preview) {
                    preview = t;
                    previewSpan = item.el;
                }
            }

            if (!name) name = "Messenger";

            // Single targeted style check on the preview span only if ARIA didn't already confirm unread
            if (!isUnread && previewSpan && !/^You:/i.test(preview)) {
                const fw = parseInt(window.getComputedStyle(previewSpan).fontWeight, 10) || 400;
                if (fw >= 600) {
                    isUnread = true;
                }
            }

            return { key, href, name, preview, isUnread };
        }

        function scanThreads() {
            const mainEl = document.querySelector('[role="main"]');
            const links = document.querySelectorAll('a[href*="/messages/t/"], a[href*="/messages/e2ee/t/"]');
            const seen = new Set();
            const threads = [];

            for (const link of links) {
                if (mainEl && mainEl.contains(link)) continue;
                const href = link.getAttribute("href") || "";
                const key = normalizeThreadKey(href);
                if (seen.has(key)) continue;
                seen.add(key);

                threads.push(extractThreadInfo(link));
                // Cap scan to the top 25 sidebar threads so work stays tiny
                if (threads.length >= 25) break;
            }
            return threads;
        }

        function postDOMNotification(thread) {
            if (Date.now() - (window.__macMessengerRecentNativeNotifTs || 0) < 4000) {
                return;
            }
            try {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.messengerNotification) {
                    window.webkit.messageHandlers.messengerNotification.postMessage({
                        id: "dom-" + String(domNotifCounter++),
                        title: thread.name || "Messenger",
                        body: thread.preview || "New message",
                        icon: "",
                        tag: thread.key,
                        silent: false,
                        threadHref: thread.key
                    });
                }
            } catch (_) {}
        }

        function checkNow(force) {
            // Never interrupt active scrolling
            if (!force && (Date.now() - lastScrollTs < 1200)) {
                return;
            }

            const titleCount = parseTitleUnreadCount();
            const bannerCount = parseBannerUnreadCount();
            const threads = scanThreads();

            let sidebarUnreadCount = 0;
            for (const t of threads) {
                if (t.isUnread) sidebarUnreadCount++;
            }

            if (threads.length > 0 && !firstThreadsSeenAt) {
                firstThreadsSeenAt = Date.now();
            }
            if (!baselineReady && firstThreadsSeenAt && (Date.now() - firstThreadsSeenAt > 2500)) {
                baselineReady = true;
            }

            for (const t of threads) {
                const prev = knownThreads.get(t.key);
                if (baselineReady && t.isUnread && !/^You:/i.test(t.preview)) {
                    const becameUnread = !prev || !prev.isUnread;
                    const previewChanged = prev && t.preview && prev.preview !== t.preview;
                    if (becameUnread || previewChanged) {
                        postDOMNotification(t);
                    }
                }
                knownThreads.set(t.key, t);
            }

            // Ignore document.title's "(N)" count because on facebook.com/messages it includes
            // general Facebook bell notifications (likes/comments), not just Messenger chats.
            const totalUnread = Math.max(bannerCount, sidebarUnreadCount);
            window.__macMessengerDebugState = {
                title: document.title || "",
                ignoredTitleCount: titleCount,
                bannerCount,
                sidebarUnreadCount,
                totalUnread,
                scannedThreads: threads.length,
                baselineReady,
                unreadThreads: threads.filter(t => t.isUnread).map(t => ({ name: t.name, preview: t.preview }))
            };

            if (totalUnread !== lastReportedCount) {
                lastReportedCount = totalUnread;
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.messengerUnread) {
                        window.webkit.messageHandlers.messengerUnread.postMessage({
                            count: totalUnread,
                            title: document.title || ""
                        });
                    }
                } catch (_) {}
            }
        }

        function setup() {
            setTimeout(() => checkNow(true), 1000);

            const titleEl = document.querySelector("title");
            if (titleEl) {
                new MutationObserver(() => checkNow(false)).observe(titleEl, {
                    subtree: true,
                    characterData: true,
                    childList: true
                });
            }

            // Gentle background poll — skipped automatically while scrolling
            setInterval(() => checkNow(false), 3000);
        }

        if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", setup, { once: true });
        } else {
            setup();
        }
    })();
    """#

    /// Injects CSS to hide the duplicate outer scrollbar on `/messages`, optionally hide
    /// Facebook's top navigation chrome, and expand Messenger containers to full `100vh`
    /// without universal `*` selectors or body-wide MutationObservers.
    static func cleanModeScript(enabled: Bool) -> String {
        let enabledLiteral = enabled ? "true" : "false"
        return #"""
        (function() {
            const STYLE_ID = "mac-messenger-clean-css";
            const CSS = `
                html.mac-messenger-messages,
                html.mac-messenger-messages body {
                    overflow: hidden !important;
                    overflow-y: hidden !important;
                    height: 100vh !important;
                    max-height: 100vh !important;
                }
                html.mac-messenger-clean,
                html.mac-messenger-clean body,
                html.mac-messenger-clean .__fb-dark-mode,
                html.mac-messenger-clean .__fb-light-mode {
                    --header-height: 0px !important;
                    --fds-header-height: 0px !important;
                }
                html.mac-messenger-clean [role="banner"] {
                    display: none !important;
                    height: 0 !important;
                    min-height: 0 !important;
                    overflow: hidden !important;
                }
                html.mac-messenger-clean [data-mm-fix-h] {
                    height: 100vh !important;
                }
                html.mac-messenger-clean [data-mm-fix-minh] {
                    min-height: 100vh !important;
                }
                html.mac-messenger-clean [data-mm-fix-maxh] {
                    max-height: 100vh !important;
                }
                html.mac-messenger-clean [data-mm-fix-inset-h] {
                    height: calc(100vh - var(--mm-inset, 0px)) !important;
                }
                html.mac-messenger-clean [data-mm-fix-inset-minh] {
                    min-height: calc(100vh - var(--mm-inset, 0px)) !important;
                }
                html.mac-messenger-clean [data-mm-fix-inset-maxh] {
                    max-height: calc(100vh - var(--mm-inset, 0px)) !important;
                }
            `;

            function isMessagesRoute() {
                return window.location.pathname.startsWith("/messages");
            }

            const HEADER_GAP = 56;
            const FIX_ATTRS = [
                "data-mm-fix-h",
                "data-mm-fix-minh",
                "data-mm-fix-maxh",
                "data-mm-fix-inset-h",
                "data-mm-fix-inset-minh",
                "data-mm-fix-inset-maxh"
            ];

            function clearHeightFixes() {
                const selector = FIX_ATTRS.map(a => `[${a}]`).join(",");
                document.querySelectorAll(selector).forEach(el => {
                    FIX_ATTRS.forEach(a => el.removeAttribute(a));
                    el.style.removeProperty("--mm-inset");
                });
            }

            function parsePx(value) {
                if (!value || !value.endsWith("px")) return NaN;
                return parseFloat(value);
            }

            function collectLayoutCandidates() {
                const set = new Set();
                const roots = document.querySelectorAll('[role="main"], [role="navigation"], [aria-label="Chats"]');
                roots.forEach(node => {
                    let cur = node;
                    while (cur && cur !== document.body && cur !== document.documentElement) {
                        set.add(cur);
                        cur = cur.parentElement;
                    }
                    const walk = (el, depth) => {
                        if (!el || depth > 3) return;
                        const role = el.getAttribute && el.getAttribute("role");
                        if (role === "dialog" || role === "menu" || role === "grid") return;
                        set.add(el);
                        for (const child of el.children) {
                            walk(child, depth + 1);
                        }
                    };
                    walk(node, 0);
                });
                return set;
            }

            function fixHardcodedHeaderHeights() {
                if (!window.__macMessengerCleanEnabled || !isMessagesRoute()) {
                    clearHeightFixes();
                    return;
                }

                const vh = window.innerHeight;
                if (vh < 200) return;

                const targetFull = vh - HEADER_GAP;
                const candidates = collectLayoutCandidates();

                // Phase 1: Batch all reads first (prevents layout thrashing)
                const pendingWrites = [];
                candidates.forEach(el => {
                    if (el.hasAttribute("data-mm-fix-h") || el.hasAttribute("data-mm-fix-inset-h")) {
                        return;
                    }
                    const cs = window.getComputedStyle(el);
                    if (cs.display === "none") return;

                    const h = parsePx(cs.height);
                    const minH = parsePx(cs.minHeight);
                    const maxH = parsePx(cs.maxHeight);

                    const rect = el.getBoundingClientRect();
                    const topInset = Math.round(rect.top);
                    const symInset = (topInset > 0 && topInset <= 32) ? topInset * 2 : 0;
                    const targetInset = vh - HEADER_GAP - symInset;

                    const attrs = [];
                    let insetToSet = 0;

                    if (Math.abs(h - targetFull) <= 2) {
                        attrs.push("data-mm-fix-h");
                    } else if (symInset > 0 && Math.abs(h - targetInset) <= 2) {
                        attrs.push("data-mm-fix-inset-h");
                        insetToSet = symInset;
                    }

                    if (Math.abs(minH - targetFull) <= 2) {
                        attrs.push("data-mm-fix-minh");
                    } else if (symInset > 0 && Math.abs(minH - targetInset) <= 2) {
                        attrs.push("data-mm-fix-inset-minh");
                        insetToSet = symInset;
                    }

                    if (Math.abs(maxH - targetFull) <= 2) {
                        attrs.push("data-mm-fix-maxh");
                    } else if (symInset > 0 && Math.abs(maxH - targetInset) <= 2) {
                        attrs.push("data-mm-fix-inset-maxh");
                        insetToSet = symInset;
                    }

                    if (attrs.length > 0) {
                        pendingWrites.push({ el, attrs, insetToSet });
                    }
                });

                // Phase 2: Apply all writes together
                for (const item of pendingWrites) {
                    if (item.insetToSet > 0) {
                        item.el.style.setProperty("--mm-inset", `${item.insetToSet}px`);
                    }
                    for (const attr of item.attrs) {
                        item.el.setAttribute(attr, "1");
                    }
                }
            }

            function scheduleInitialHeightFixes() {
                setTimeout(fixHardcodedHeaderHeights, 250);
                setTimeout(fixHardcodedHeaderHeights, 900);
                setTimeout(fixHardcodedHeaderHeights, 2000);
            }

            window.__macMessengerSetCleanMode = function(enabled) {
                window.__macMessengerCleanEnabled = Boolean(enabled);
                let style = document.getElementById(STYLE_ID);
                const target = document.head || document.documentElement;
                if (!style && target) {
                    style = document.createElement("style");
                    style.id = STYLE_ID;
                    style.textContent = CSS;
                    target.appendChild(style);
                }
                const onMessages = isMessagesRoute();
                document.documentElement.classList.toggle("mac-messenger-messages", onMessages);
                document.documentElement.classList.toggle("mac-messenger-clean", window.__macMessengerCleanEnabled && onMessages);
                scheduleInitialHeightFixes();
            };

            function applyCurrent() {
                window.__macMessengerSetCleanMode(window.__macMessengerCleanEnabled);
            }

            window.__macMessengerCleanEnabled = \#(enabledLiteral);

            if (document.readyState === "loading") {
                document.addEventListener("DOMContentLoaded", applyCurrent, { once: true });
            } else {
                applyCurrent();
            }

            const origPush = history.pushState;
            history.pushState = function() {
                const res = origPush.apply(this, arguments);
                setTimeout(applyCurrent, 150);
                return res;
            };
            const origReplace = history.replaceState;
            history.replaceState = function() {
                const res = origReplace.apply(this, arguments);
                setTimeout(applyCurrent, 150);
                return res;
            };
            window.addEventListener("popstate", () => setTimeout(applyCurrent, 150));
        })();
        """#
    }
}
