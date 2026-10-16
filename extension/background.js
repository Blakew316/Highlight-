// Opens PDFs in the Highlight page that ships with the extension: the toolbar
// button (or Alt+Shift+H) opens the PDF in the current tab, and right-clicking a
// PDF link or a PDF page offers "Open in Highlight". The PDF is fetched by that
// page, after the user allows the site once; nothing is sent anywhere else.

const APP = chrome.runtime.getURL("app.html");
const PDF_PATTERNS = ["*://*/*.pdf", "*://*/*.pdf?*", "*://*/*.PDF", "*://*/*.PDF?*", "file:///*.pdf", "file:///*.PDF"];

/** True for http(s) and file URLs whose path ends in .pdf. */
function looksLikePdf(url) {
  try {
    const u = new URL(url);
    return /^(https?|file):$/.test(u.protocol) && /\.pdf$/i.test(u.pathname);
  } catch {
    return false;
  }
}

/** Opens Highlight in a new tab next to `tab`, with the PDF at `url` if given. */
function openInApp(url, tab) {
  const target = url ? `${APP}?src=${encodeURIComponent(url)}` : APP;
  const options = { url: target };
  if (tab && tab.index >= 0) { options.index = tab.index + 1; options.openerTabId = tab.id; }
  return chrome.tabs.create(options);
}
self.openInApp = openInApp; // for tests

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: "open-link", title: "Open PDF in Highlight", contexts: ["link"], targetUrlPatterns: PDF_PATTERNS,
    });
    chrome.contextMenus.create({
      id: "open-page", title: "Open this PDF in Highlight", contexts: ["page", "frame"], documentUrlPatterns: PDF_PATTERNS,
    });
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const url = info.menuItemId === "open-link" ? info.linkUrl : (info.frameUrl || info.pageUrl);
  openInApp(url, tab);
});

chrome.action.onClicked.addListener((tab) => {
  openInApp(tab && looksLikePdf(tab.url || "") ? tab.url : null, tab);
});
