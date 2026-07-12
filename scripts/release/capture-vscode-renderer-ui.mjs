import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { inflateSync } from "node:zlib";

const CDP_REQUEST_TIMEOUT_MS = 10000;
const CDP_CONNECT_RETRY_TIMEOUT_MS = 60000;
const CDP_CONNECT_RETRY_INTERVAL_MS = 500;
const REQUIRED_TOKEN_CAPTURE_TIMEOUT_MS = 10000;
const REQUIRED_TOKEN_CAPTURE_INTERVAL_MS = 250;

async function main() {
const args = parseArgs(process.argv.slice(2));
const remoteDebuggingPort = requiredInteger(args, "remote-debugging-port");
const outputRoot = requiredString(args, "output-root");
const expectationsPath = requiredString(args, "expectations-path");
const target = requiredString(args, "target");

await mkdir(outputRoot, { recursive: true });

const expectations = JSON.parse(await readFile(expectationsPath, "utf8"));
const domTokens = requiredTokenArray(expectations.requiredDomTokens, "requiredDomTokens");
const accessibilityTokens = requiredTokenArray(
  expectations.requiredAccessibilityTokens,
  "requiredAccessibilityTokens",
);
const forbiddenDomTokens = optionalTokenArray(expectations.forbiddenDomTokens, "forbiddenDomTokens");
const forbiddenAccessibilityTokens = optionalTokenArray(
  expectations.forbiddenAccessibilityTokens,
  "forbiddenAccessibilityTokens",
);
const clickButtonText = optionalString(expectations.clickButtonText, "clickButtonText");
const inputText = optionalString(expectations.inputText, "inputText");
const submitKey = optionalString(expectations.submitKey, "submitKey");
const cancelKey = optionalString(expectations.cancelKey, "cancelKey");
const cancelAction = optionalString(expectations.cancelAction, "cancelAction");
const quickPickItemText = optionalString(expectations.quickPickItemText, "quickPickItemText");
const quickInputSubmitKey = optionalString(expectations.quickInputSubmitKey, "quickInputSubmitKey");
if ((inputText === undefined) !== (submitKey === undefined)) {
  throw new Error("inputText and submitKey must be provided together.");
}
if (submitKey !== undefined && quickInputSubmitKey !== undefined) {
  throw new Error("submitKey and quickInputSubmitKey cannot be provided together.");
}
if (cancelAction !== undefined && cancelAction !== "closeNotification") {
  throw new Error(`Unsupported cancelAction: ${cancelAction}.`);
}
const interactionCount = [clickButtonText, inputText, cancelKey, cancelAction, quickPickItemText, quickInputSubmitKey].filter((value) => value !== undefined).length;
if (interactionCount > 1) {
  throw new Error("Renderer expectations must use exactly one interaction kind when an interaction is requested.");
}

const domPath = path.join(outputRoot, "dom-text.txt");
const accessibilityPath = path.join(outputRoot, "accessibility-tree.json");
const screenshotPath = path.join(outputRoot, "screenshot.png");
const capturePath = path.join(outputRoot, "renderer-capture.json");

let captureReport;

try {
  const selectedTarget = await selectWorkbenchTarget(remoteDebuggingPort);
  const cdp = await CdpConnection.connect(selectedTarget.webSocketDebuggerUrl);
  try {
    await cdp.send("Page.enable").catch(() => undefined);
    await cdp.send("Runtime.enable").catch(() => undefined);
    await cdp.send("Accessibility.enable").catch(() => undefined);
    await cdp.send("Page.bringToFront").catch(() => undefined);
    const capturedState = await captureRequiredTokenState(cdp, domTokens, accessibilityTokens);
    const domState = capturedState.domState;
    const domText = String(domState.innerText ?? "");
    await writeFile(domPath, domText, "utf8");

    const accessibilityTree = capturedState.accessibilityTree;
    await writeFile(accessibilityPath, JSON.stringify(accessibilityTree, null, 2), "utf8");
    const accessibilityText = capturedState.accessibilityText;

    const screenshot = await captureScreenshotWithRetry(cdp);
    const screenshotBytes = Buffer.from(String(screenshot.data), "base64");
    await writeFile(screenshotPath, screenshotBytes);
    const screenshotInfo = inspectPng(screenshotBytes);

    const domMatches = matchTokens(domText, domTokens);
    const accessibilityMatches = matchTokens(accessibilityText, accessibilityTokens);
    const forbiddenDomMatches = matchTokens(domText, forbiddenDomTokens);
    const forbiddenAccessibilityMatches = matchTokens(accessibilityText, forbiddenAccessibilityTokens);
    const interaction =
      clickButtonText !== undefined
        ? await clickButtonByText(cdp, clickButtonText, domTokens)
        : inputText !== undefined
          ? await submitQuickInput(cdp, inputText, submitKey)
          : quickInputSubmitKey !== undefined
            ? await submitCurrentQuickInput(cdp, quickInputSubmitKey, domTokens)
            : quickPickItemText !== undefined
              ? await selectQuickPickItem(cdp, quickPickItemText)
              : cancelKey !== undefined
                ? await cancelInteraction(cdp, cancelKey, domTokens)
                : cancelAction !== undefined
                  ? await closeNotification(cdp, domTokens)
                  : undefined;

    captureReport = {
      schemaVersion: 1,
      schema: "subversionr.release.installed-source-control-ui-renderer-capture.v1",
      target,
      capturedAt: new Date().toISOString(),
      remoteDebugging: {
        port: remoteDebuggingPort,
        selectedTarget: {
          id: selectedTarget.id,
          type: selectedTarget.type,
          title: selectedTarget.title,
          url: selectedTarget.url,
        },
      },
      viewport: {
        title: domState.title,
        url: domState.url,
        readyState: domState.readyState,
        devicePixelRatio: domState.devicePixelRatio,
        innerWidth: domState.innerWidth,
        innerHeight: domState.innerHeight,
      },
      artifacts: {
        dom: artifact("captured", outputRoot, domPath, {
          requiredTokens: domTokens,
          matchedTokens: domMatches.matched,
          missingTokens: domMatches.missing,
          forbiddenTokens: forbiddenDomTokens,
          presentForbiddenTokens: forbiddenDomMatches.matched,
        }),
        accessibility: artifact("captured", outputRoot, accessibilityPath, {
          requiredTokens: accessibilityTokens,
          matchedTokens: accessibilityMatches.matched,
          missingTokens: accessibilityMatches.missing,
          forbiddenTokens: forbiddenAccessibilityTokens,
          presentForbiddenTokens: forbiddenAccessibilityMatches.matched,
        }),
        screenshot: artifact("captured", outputRoot, screenshotPath, {
          width: screenshotInfo.width,
          height: screenshotInfo.height,
          bitDepth: screenshotInfo.bitDepth,
          colorType: screenshotInfo.colorType,
          nonBlank: screenshotInfo.nonBlank,
          uniqueColorSampleCount: screenshotInfo.uniqueColorSampleCount,
        }),
      },
      assertions: {
        domRequiredTokensPresent: domMatches.missing.length === 0,
        accessibilityRequiredTokensPresent: accessibilityMatches.missing.length === 0,
        domForbiddenTokensAbsent: forbiddenDomMatches.matched.length === 0,
        accessibilityForbiddenTokensAbsent: forbiddenAccessibilityMatches.matched.length === 0,
        screenshotCaptured: true,
        screenshotNonBlank: screenshotInfo.nonBlank,
        ...(interaction && clickButtonText !== undefined ? { clickButtonCompleted: interaction.clicked } : {}),
        ...(interaction && inputText !== undefined ? { inputTextSubmitted: interaction.submitted === true } : {}),
        ...(interaction && quickInputSubmitKey !== undefined ? { quickInputSubmitted: interaction.submitted === true } : {}),
        ...(interaction && quickPickItemText !== undefined ? { quickPickItemSelected: interaction.selected === true } : {}),
        ...(interaction && (cancelKey !== undefined || cancelAction !== undefined) ? {
          interactionCancelled: interaction.cancelled === true,
          ...(interaction.surface === "quickInput" ? { quickInputCancelled: interaction.cancelled === true } : {}),
          ...(interaction.surface === "dialog" ? { dialogCancelled: interaction.cancelled === true } : {}),
          ...(interaction.surface === "notification" ? { notificationCancelled: interaction.cancelled === true } : {}),
        } : {}),
      },
      ...(interaction ? { interaction } : {}),
    };

    await writeCaptureReport(capturePath, captureReport);
    const failures = [];
    if (domMatches.missing.length > 0) {
      failures.push(`DOM snapshot missing tokens: ${domMatches.missing.join(", ")}`);
    }
    if (accessibilityMatches.missing.length > 0) {
      failures.push(`accessibility tree missing tokens: ${accessibilityMatches.missing.join(", ")}`);
    }
    if (forbiddenDomMatches.matched.length > 0) {
      failures.push(`DOM snapshot contains forbidden tokens: ${forbiddenDomMatches.matched.join(", ")}`);
    }
    if (forbiddenAccessibilityMatches.matched.length > 0) {
      failures.push(`accessibility tree contains forbidden tokens: ${forbiddenAccessibilityMatches.matched.join(", ")}`);
    }
    if (!screenshotInfo.nonBlank) {
      failures.push("screenshot PNG pixel sample was blank");
    }
    if (failures.length > 0) {
      throw new Error(failures.join("; "));
    }
  } finally {
    cdp.close();
  }
} catch (error) {
  if (!captureReport) {
    captureReport = {
      schemaVersion: 1,
      schema: "subversionr.release.installed-source-control-ui-renderer-capture.v1",
      target,
      capturedAt: new Date().toISOString(),
      remoteDebugging: {
        port: remoteDebuggingPort,
      },
      artifacts: {
        dom: failedArtifact(domPath, error),
        accessibility: failedArtifact(accessibilityPath, error),
        screenshot: failedArtifact(screenshotPath, error),
      },
      assertions: {
        domRequiredTokensPresent: false,
        accessibilityRequiredTokensPresent: false,
        domForbiddenTokensAbsent: false,
        accessibilityForbiddenTokensAbsent: false,
        screenshotCaptured: false,
        screenshotNonBlank: false,
      },
      error: {
        message: error instanceof Error ? error.message : String(error),
      },
    };
    await writeCaptureReport(capturePath, captureReport);
  }
  throw error;
}
}

async function captureRequiredTokenState(cdp, domTokens, accessibilityTokens) {
  const started = Date.now();
  let lastState;
  do {
    await sleep(250);
    const domState = await evaluate(cdp, `(() => ({
      title: document.title,
      url: location.href,
      innerText: document.body ? document.body.innerText : "",
      devicePixelRatio: window.devicePixelRatio,
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      readyState: document.readyState
    }))()`);
    const accessibilityTree = await cdp.send("Accessibility.getFullAXTree");
    const domText = String(domState.innerText ?? "");
    const accessibilityText = accessibilityTreeText(accessibilityTree);
    const domMatches = matchTokens(domText, domTokens);
    const accessibilityMatches = matchTokens(accessibilityText, accessibilityTokens);
    lastState = {
      domState,
      accessibilityTree,
      accessibilityText,
      domMatches,
      accessibilityMatches,
    };
    if (domMatches.missing.length === 0 && accessibilityMatches.missing.length === 0) {
      return lastState;
    }
    await sleep(REQUIRED_TOKEN_CAPTURE_INTERVAL_MS);
  } while (Date.now() - started < REQUIRED_TOKEN_CAPTURE_TIMEOUT_MS);
  return lastState;
}

function parseArgs(argv) {
  const parsed = new Map();
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith("--")) {
      throw new Error(`Unexpected argument: ${arg}`);
    }
    const name = arg.slice(2);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`Missing value for --${name}.`);
    }
    parsed.set(name, value);
    index += 1;
  }
  return parsed;
}

function requiredString(args, name) {
  const value = args.get(name);
  if (!value || value.trim().length === 0) {
    throw new Error(`--${name} is required.`);
  }
  return value;
}

function requiredInteger(args, name) {
  const value = Number.parseInt(requiredString(args, name), 10);
  if (!Number.isInteger(value) || value < 1 || value > 65535) {
    throw new Error(`--${name} must be a TCP port.`);
  }
  return value;
}

function requiredTokenArray(value, name) {
  if (
    !Array.isArray(value) ||
    value.length === 0 ||
    value.some((token) => typeof token !== "string" || token.trim().length === 0)
  ) {
    throw new Error(`${name} must be a non-empty string array.`);
  }
  return value;
}

function optionalTokenArray(value, name) {
  if (value === undefined) {
    return [];
  }
  if (!Array.isArray(value) || value.some((token) => typeof token !== "string" || token.trim().length === 0)) {
    throw new Error(`${name} must be a string array when provided.`);
  }
  return value;
}

function optionalString(value, name) {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${name} must be a non-empty string when provided.`);
  }
  return value;
}

async function selectWorkbenchTarget(port) {
  // The Chromium remote-debugging endpoint binds asynchronously during VS Code
  // startup, so the first connection must tolerate ECONNREFUSED and a not-yet
  // enumerated workbench target within a bounded retry window.
  const deadline = Date.now() + CDP_CONNECT_RETRY_TIMEOUT_MS;
  let lastError = null;
  for (;;) {
    try {
      const targets = await fetchJson(`http://127.0.0.1:${port}/json/list`);
      const candidates = targets.filter(
        (target) =>
          target.webSocketDebuggerUrl &&
          (target.type === "page" || target.type === "webview" || target.type === "other"),
      );
      const workbenchTargets = candidates.filter((target) =>
        `${target.url ?? ""} ${target.title ?? ""}`.toLowerCase().includes("workbench"),
      );
      if (workbenchTargets.length === 1) {
        return workbenchTargets[0];
      }
      lastError = new Error(
        `Expected exactly one VS Code workbench CDP target; found ${workbenchTargets.length}.`,
      );
      console.error(
        `[cdp-retry] targets=${targets.length} candidates=${candidates.length} workbench=${workbenchTargets.length} :: ${targets.map((t) => `${t.type}|${(t.title ?? "").slice(0, 40)}|${(t.url ?? "").slice(0, 80)}`).join(" ;; ")}`,
      );
    } catch (error) {
      lastError = error;
      console.error(`[cdp-retry] fetch error: ${error?.cause?.code ?? error.message}`);
    }
    if (Date.now() >= deadline) {
      throw lastError;
    }
    await sleep(CDP_CONNECT_RETRY_INTERVAL_MS);
  }
}

async function fetchJson(url) {
  const response = await fetch(url, { signal: AbortSignal.timeout(CDP_REQUEST_TIMEOUT_MS) });
  if (!response.ok) {
    throw new Error(`CDP endpoint ${url} returned ${response.status}.`);
  }
  return response.json();
}

class CdpConnection {
  static async connect(url) {
    const socket = new WebSocket(url);
    const connection = new CdpConnection(socket);
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("CDP WebSocket open timed out.")), CDP_REQUEST_TIMEOUT_MS);
      socket.addEventListener(
        "open",
        () => {
          clearTimeout(timeout);
          resolve();
        },
        { once: true },
      );
      socket.addEventListener(
        "error",
        () => {
          clearTimeout(timeout);
          reject(new Error("CDP WebSocket failed before open."));
        },
        { once: true },
      );
    });
    return connection;
  }

  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    socket.addEventListener("message", (event) => this.onMessage(event));
    socket.addEventListener("close", () => {
      for (const pending of this.pending.values()) {
        clearTimeout(pending.timeout);
        pending.reject(new Error("CDP WebSocket closed."));
      }
      this.pending.clear();
    });
  }

  send(method, params = {}) {
    const id = this.nextId;
    this.nextId += 1;
    const payload = JSON.stringify({ id, method, params });
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP request timed out: ${method}`));
      }, CDP_REQUEST_TIMEOUT_MS);
      this.pending.set(id, { resolve, reject, timeout });
      this.socket.send(payload);
    });
  }

  close() {
    this.socket.close();
  }

  onMessage(event) {
    const message = JSON.parse(String(event.data));
    if (!message.id || !this.pending.has(message.id)) {
      return;
    }
    const pending = this.pending.get(message.id);
    this.pending.delete(message.id);
    clearTimeout(pending.timeout);
    if (message.error) {
      pending.reject(new Error(`${message.error.message ?? "CDP error"} (${message.error.code ?? "no-code"})`));
      return;
    }
    pending.resolve(message.result);
  }
}

async function evaluate(cdp, expression) {
  const result = await cdp.send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (result.exceptionDetails) {
    throw new Error("Runtime.evaluate failed in the VS Code workbench target.");
  }
  return result.result.value;
}

async function clickButtonByText(cdp, buttonText, domTokens) {
  const started = Date.now();
  const timeoutMs = CDP_REQUEST_TIMEOUT_MS;
  const expected = JSON.stringify(buttonText);
  const notificationTokens = JSON.stringify(domTokens.filter((token) => token !== buttonText));
  let lastResult;
  while (Date.now() - started < timeoutMs) {
    const result = await evaluate(
      cdp,
      `(() => {
        ${clickNotificationActionSource()}
        const expected = ${expected};
        const notificationTokens = ${notificationTokens};
        const normalize = (value) => String(value ?? "").replace(/\\s+/g, " ").trim();
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          return rect.width > 0 &&
            rect.height > 0 &&
            rect.right > 0 &&
            rect.bottom > 0 &&
            rect.left < window.innerWidth &&
            rect.top < window.innerHeight;
        };
        const elements = Array.from(document.querySelectorAll("button, [role='button'], a.monaco-button, .monaco-button"));
        const match = elements.find((element) =>
          visible(element) &&
          (
            normalize(element.textContent) === expected ||
            normalize(element.getAttribute("aria-label")) === expected ||
            normalize(element.getAttribute("title")) === expected
          )
        );
        if (match) {
          match.click();
          return {
            clicked: true,
            clickedButtonText: normalize(match.textContent) || normalize(match.getAttribute("aria-label")) || normalize(match.getAttribute("title")),
            tagName: match.tagName,
            className: typeof match.className === "string" ? match.className : ""
          };
        }
        return clickNotificationAction(expected, notificationTokens, normalize, visible);
      })()`,
    );
    lastResult = result;
    if (result && result.clicked === true) {
      return result;
    }
    if (result && result.hoverTarget && Number.isFinite(result.hoverTarget.x) && Number.isFinite(result.hoverTarget.y)) {
      await cdp.send("Input.dispatchMouseEvent", {
        type: "mouseMoved",
        x: result.hoverTarget.x,
        y: result.hoverTarget.y,
      });
    }
    await sleep(250);
  }
  const diagnostic = lastResult ? ` Last interaction state: ${JSON.stringify(lastResult).slice(0, 1000)}` : "";
  throw new Error(`Timed out waiting for VS Code renderer button: ${buttonText}.${diagnostic}`);
}

function clickNotificationActionSource() {
  return String.raw`
function clickNotificationAction(expected, notificationTokens, normalize, visible) {
  const notificationSelectors = [
    ".notifications-toasts .notification-toast",
    ".notifications-toasts .monaco-list-row",
    ".notifications-list-container .notification-list-item",
    ".notifications-list-container .monaco-list-row",
    ".notification-toast",
    ".notification-list-item",
    "[aria-label*='notification']",
    "[role='alert']"
  ];
  const actionSelectors = [
    ".notification-actions button",
    ".notification-actions [role='button']",
    ".notification-actions .monaco-button",
    ".monaco-button",
    "button",
    "[role='button']"
  ];
  const closeTokens = ["close", "clear", "hide"];
  const notifications = notificationSelectors.flatMap((selector) => Array.from(document.querySelectorAll(selector)));
  const notification = notifications.find((candidate) => {
    const candidateText = normalize(candidate.innerText) || normalize(candidate.textContent) || normalize(candidate.getAttribute("aria-label"));
    return visible(candidate) && notificationTokens.every((token) => candidateText.includes(normalize(token)));
  });
  if (!notification) {
    const dismissed = dismissUnmatchedVisibleNotification(notifications, notificationTokens, normalize, visible);
    if (dismissed.dismissed === true) {
      return {
        clicked: false,
        notificationMatchedByTokens: false,
        dismissedUnmatchedNotification: true,
        dismissedNotificationText: dismissed.notificationText
      };
    }
    return { clicked: false, notificationMatchedByTokens: false };
  }
  const notificationRect = notification.getBoundingClientRect();
  const hoverTarget = {
    x: notificationRect.left + Math.max(1, notificationRect.width / 2),
    y: notificationRect.top + Math.max(1, notificationRect.height / 2)
  };
  const actions = actionSelectors
    .flatMap((selector) => Array.from(notification.querySelectorAll(selector)))
    .filter((element, index, elements) => elements.indexOf(element) === index)
    .filter((element) => {
      if (!visible(element) || element.disabled === true || element.getAttribute("aria-disabled") === "true") {
        return false;
      }
      const label = normalize(element.textContent) || normalize(element.getAttribute("aria-label")) || normalize(element.getAttribute("title"));
      const lower = label.toLowerCase();
      return !closeTokens.some((token) => lower.includes(token));
    });
  const action = actions.find((element) => {
    const label = normalize(element.textContent) || normalize(element.getAttribute("aria-label")) || normalize(element.getAttribute("title"));
    return label === expected;
  }) || actions[0];
  if (!action) {
    return {
      clicked: false,
      notificationMatchedByTokens: true,
      notificationActionVisible: false,
      hoverTarget,
      notificationText: (normalize(notification.innerText) || normalize(notification.textContent) || normalize(notification.getAttribute("aria-label"))).slice(0, 500)
    };
  }
  const clickedButtonText = normalize(action.textContent) || normalize(action.getAttribute("aria-label")) || normalize(action.getAttribute("title")) || expected;
  action.click();
  return {
    clicked: true,
    surface: "notification",
    notificationMatchedByTokens: true,
    notificationActionVisible: true,
    clickedButtonText,
    tagName: action.tagName,
    className: typeof action.className === "string" ? action.className : ""
  };
}

function dismissUnmatchedVisibleNotification(notifications, notificationTokens, normalize, visible) {
  const closeSelectors = [
    "button[aria-label*='Close']",
    "button[aria-label*='Clear']",
    "button[title*='Close']",
    "button[title*='Clear']",
    "[role='button'][aria-label*='Close']",
    "[role='button'][aria-label*='Clear']",
    "[role='button'][title*='Close']",
    "[role='button'][title*='Clear']",
    ".notification-close",
    ".action-label.codicon-close",
    ".codicon-close",
    ".codicon-notifications-hide"
  ];
  for (const notification of notifications) {
    if (!visible(notification)) {
      continue;
    }
    const notificationText = normalize(notification.innerText) || normalize(notification.textContent) || normalize(notification.getAttribute("aria-label"));
    if (notificationTokens.every((token) => notificationText.includes(normalize(token)))) {
      continue;
    }
    notification.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    const close = closeSelectors
      .flatMap((selector) => Array.from(notification.querySelectorAll(selector)))
      .find((element) => visible(element));
    if (close) {
      close.click();
      return { dismissed: true, notificationText };
    }
  }
  return { dismissed: false };
}
`;
}

async function submitQuickInput(cdp, text, submitKey) {
  if (submitKey !== "Enter") {
    throw new Error(`Unsupported QuickInput submitKey: ${submitKey}`);
  }
  const started = Date.now();
  const timeoutMs = CDP_REQUEST_TIMEOUT_MS;
  let inputDetails;
  while (Date.now() - started < timeoutMs) {
    const result = await evaluate(
      cdp,
      `(() => {
        const selectors = [
          ".quick-input-widget input.input",
          ".quick-input-widget input",
          ".quick-input-widget textarea"
        ];
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        };
        const input = selectors
          .flatMap((selector) => Array.from(document.querySelectorAll(selector)))
          .find((element) => !element.disabled && visible(element));
        if (!input) {
          return { ready: false };
        }
        input.focus();
        if (typeof input.select === "function") {
          input.select();
        }
        return {
          ready: true,
          tagName: input.tagName,
          className: typeof input.className === "string" ? input.className : "",
          ariaLabel: input.getAttribute("aria-label") ?? "",
          placeholder: input.getAttribute("placeholder") ?? "",
          valueBefore: input.value ?? ""
        };
      })()`,
    );
    if (result && result.ready === true) {
      inputDetails = result;
      break;
    }
    await sleep(250);
  }
  if (!inputDetails) {
    throw new Error("Timed out waiting for VS Code QuickInput text field.");
  }

  await cdp.send("Input.insertText", { text });
  const valueResult = await evaluate(
    cdp,
    `(() => {
      const selectors = [
        ".quick-input-widget input.input",
        ".quick-input-widget input",
        ".quick-input-widget textarea",
        "input[aria-label]",
        "textarea[aria-label]"
      ];
      const visible = (element) => {
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const input = selectors
        .flatMap((selector) => Array.from(document.querySelectorAll(selector)))
        .find((element) => !element.disabled && visible(element));
      if (!input) {
        return { found: false };
      }
      return { found: true, value: input.value ?? "" };
    })()`,
  );
  if (!valueResult || valueResult.found !== true || valueResult.value !== text) {
    throw new Error("VS Code QuickInput value did not match the requested text.");
  }

  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyDown",
    key: "Enter",
    code: "Enter",
    windowsVirtualKeyCode: 13,
    nativeVirtualKeyCode: 13,
  });
  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyUp",
    key: "Enter",
    code: "Enter",
    windowsVirtualKeyCode: 13,
    nativeVirtualKeyCode: 13,
  });

  return {
    submitted: true,
    enteredText: text,
    submittedKey: submitKey,
    tagName: inputDetails.tagName,
    className: inputDetails.className,
    ariaLabel: inputDetails.ariaLabel,
    placeholder: inputDetails.placeholder,
    valueBefore: inputDetails.valueBefore,
  };
}

async function submitCurrentQuickInput(cdp, submitKey, domTokens) {
  if (submitKey !== "Enter") {
    throw new Error(`Unsupported QuickInput submitKey: ${submitKey}`);
  }
  const targetText = domTokens.length > 0 ? domTokens[0] : "";
  const started = Date.now();
  const timeoutMs = CDP_REQUEST_TIMEOUT_MS;
  let inputDetails;
  while (Date.now() - started < timeoutMs) {
    const result = await evaluate(
      cdp,
      `(() => {
        const targetText = ${JSON.stringify(targetText)};
        const normalize = (value) => String(value ?? "").replace(/\\s+/g, " ").trim();
        const selectors = [
          ".quick-input-widget input.input",
          ".quick-input-widget input",
          ".quick-input-widget textarea"
        ];
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        };
        const widgets = Array.from(document.querySelectorAll(".quick-input-widget"))
          .filter((element) => visible(element));
        const quickInput = widgets.find((element) =>
          !targetText ||
          normalize(element.textContent).includes(targetText) ||
          normalize(element.getAttribute("aria-label")).includes(targetText)
        );
        if (!quickInput) {
          return { ready: false };
        }
        const input = selectors
          .flatMap((selector) => Array.from(quickInput.querySelectorAll(selector)))
          .find((element) => !element.disabled && visible(element));
        if (!input) {
          return { ready: false };
        }
        input.focus();
        return {
          ready: true,
          tagName: input.tagName,
          className: typeof input.className === "string" ? input.className : "",
          ariaLabel: input.getAttribute("aria-label") ?? "",
          placeholder: input.getAttribute("placeholder") ?? "",
          valueBefore: input.value ?? "",
          targetText
        };
      })()`,
    );
    if (result && result.ready === true) {
      inputDetails = result;
      break;
    }
    await sleep(250);
  }
  if (!inputDetails) {
    throw new Error("Timed out waiting for VS Code QuickInput submit field.");
  }

  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyDown",
    key: "Enter",
    code: "Enter",
    windowsVirtualKeyCode: 13,
    nativeVirtualKeyCode: 13,
  });
  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyUp",
    key: "Enter",
    code: "Enter",
    windowsVirtualKeyCode: 13,
    nativeVirtualKeyCode: 13,
  });

  const closedStarted = Date.now();
  while (Date.now() - closedStarted < timeoutMs) {
    const closeResult = await evaluate(
      cdp,
      `(() => {
        const targetText = ${JSON.stringify(targetText)};
        const normalize = (value) => String(value ?? "").replace(/\\s+/g, " ").trim();
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        };
        const widgets = Array.from(document.querySelectorAll(".quick-input-widget"))
          .filter((element) => visible(element));
        const targetVisible = widgets.some((element) =>
          !targetText ||
          normalize(element.textContent).includes(targetText) ||
          normalize(element.getAttribute("aria-label")).includes(targetText)
        );
        return {
          quickInputVisible: widgets.length > 0,
          targetVisible
        };
      })()`,
    );
    if (!closeResult || closeResult.targetVisible !== true) {
      return {
        submitted: true,
        submittedKey: submitKey,
        surface: "quickInput",
        tagName: inputDetails.tagName,
        className: inputDetails.className,
        ariaLabel: inputDetails.ariaLabel,
        placeholder: inputDetails.placeholder,
        valueBefore: inputDetails.valueBefore,
        targetText: inputDetails.targetText,
        nextQuickInputVisible: closeResult?.quickInputVisible === true,
      };
    }
    await sleep(250);
  }
  throw new Error(`VS Code QuickInput remained visible after ${submitKey} submission.`);
}

async function selectQuickPickItem(cdp, itemText) {
  const started = Date.now();
  const timeoutMs = CDP_REQUEST_TIMEOUT_MS;
  const expected = JSON.stringify(itemText);
  let lastAvailableTexts = [];
  while (Date.now() - started < timeoutMs) {
    const candidate = await evaluate(
      cdp,
      `(() => {
        const expected = ${expected};
        const normalize = (value) => String(value ?? "").replace(/\\s+/g, " ").trim();
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        };
        const quickInput = Array.from(document.querySelectorAll(".quick-input-widget")).find((element) => visible(element));
        if (!quickInput) {
          return { ready: false, quickInputVisible: false, availableTexts: [] };
        }
        const rows = Array.from(new Set([
          ...quickInput.querySelectorAll(".quick-input-list .monaco-list-row"),
          ...quickInput.querySelectorAll(".monaco-list-row"),
          ...quickInput.querySelectorAll("[role='option']")
        ]));
        const candidates = rows
          .filter((row) => visible(row))
          .map((row) => {
            const rect = row.getBoundingClientRect();
            const label = normalize(row.querySelector(".quick-input-list-entry-label")?.textContent);
            const description = normalize(row.querySelector(".quick-input-list-entry-description")?.textContent);
            const text = normalize(row.textContent);
            return {
              text,
              label,
              description,
              x: rect.left + rect.width / 2,
              y: rect.top + rect.height / 2,
              tagName: row.tagName,
              className: typeof row.className === "string" ? row.className : "",
              ariaLabel: row.getAttribute("aria-label") ?? ""
            };
          });
        const matches = candidates.filter((candidate) =>
          candidate.text === expected ||
          candidate.text.includes(expected) ||
          candidate.label === expected ||
          candidate.label.includes(expected)
        );
        if (matches.length === 0) {
          return {
            ready: false,
            quickInputVisible: true,
            availableTexts: candidates.map((candidate) => candidate.text).filter((text) => text.length > 0).slice(0, 20)
          };
        }
        if (matches.length > 1) {
          return {
            ready: false,
            ambiguous: true,
            quickInputVisible: true,
            availableTexts: candidates.map((candidate) => candidate.text).filter((text) => text.length > 0).slice(0, 20),
            matchedTexts: matches.map((candidate) => candidate.text).filter((text) => text.length > 0).slice(0, 20)
          };
        }
        const match = matches[0];
        return {
          ready: true,
          quickInputVisible: true,
          availableTexts: candidates.map((candidate) => candidate.text).filter((text) => text.length > 0).slice(0, 20),
          ...match
        };
      })()`,
    );
    if (candidate && Array.isArray(candidate.availableTexts)) {
      lastAvailableTexts = candidate.availableTexts;
    }
    if (candidate && candidate.ambiguous === true) {
      const matches = Array.isArray(candidate.matchedTexts) ? ` Matches: ${candidate.matchedTexts.join(" | ")}` : "";
      throw new Error(`VS Code QuickPick item was ambiguous: ${itemText}.${matches}`);
    }
    if (!candidate || candidate.ready !== true) {
      await sleep(250);
      continue;
    }

    await cdp.send("Input.dispatchMouseEvent", {
      type: "mouseMoved",
      x: candidate.x,
      y: candidate.y,
    });
    await cdp.send("Input.dispatchMouseEvent", {
      type: "mousePressed",
      x: candidate.x,
      y: candidate.y,
      button: "left",
      clickCount: 1,
    });
    await cdp.send("Input.dispatchMouseEvent", {
      type: "mouseReleased",
      x: candidate.x,
      y: candidate.y,
      button: "left",
      clickCount: 1,
    });

    const closedStarted = Date.now();
    while (Date.now() - closedStarted < timeoutMs) {
      const closeResult = await evaluate(
        cdp,
        `(() => {
          const expected = ${expected};
          const normalize = (value) => String(value ?? "").replace(/\\s+/g, " ").trim();
          const visible = (element) => {
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };
          const quickInput = Array.from(document.querySelectorAll(".quick-input-widget")).find((element) => visible(element));
          if (!quickInput) {
            return {
              quickInputVisible: false,
              selectedItemStillVisible: false,
              availableTexts: []
            };
          }
          const rows = Array.from(new Set([
            ...quickInput.querySelectorAll(".quick-input-list .monaco-list-row"),
            ...quickInput.querySelectorAll(".monaco-list-row"),
            ...quickInput.querySelectorAll("[role='option']")
          ]));
          const candidates = rows
            .filter((row) => visible(row))
            .map((row) => ({
              text: normalize(row.textContent),
              label: normalize(row.querySelector(".quick-input-list-entry-label")?.textContent)
            }));
          const selectedItemStillVisible = candidates.some((candidate) =>
            candidate.text === expected ||
            candidate.text.includes(expected) ||
            candidate.label === expected ||
            candidate.label.includes(expected)
          );
          return {
            quickInputVisible: true,
            selectedItemStillVisible,
            availableTexts: candidates.map((candidate) => candidate.text).filter((text) => text.length > 0).slice(0, 20)
          };
        })()`,
      );
      if (
        !closeResult ||
        closeResult.quickInputVisible !== true ||
        closeResult.selectedItemStillVisible !== true
      ) {
        return {
          selected: true,
          surface: "quickPick",
          requestedText: itemText,
          selectedText: candidate.text,
          label: candidate.label,
          description: candidate.description,
          tagName: candidate.tagName,
          className: candidate.className,
          ariaLabel: candidate.ariaLabel,
          nextQuickInputVisible: closeResult?.quickInputVisible === true,
          nextAvailableTexts: Array.isArray(closeResult?.availableTexts) ? closeResult.availableTexts : [],
        };
      }
      await sleep(250);
    }
    throw new Error(`VS Code QuickPick remained visible after selecting item: ${itemText}`);
  }
  const available = lastAvailableTexts.length > 0 ? ` Available items: ${lastAvailableTexts.join(" | ")}` : "";
  throw new Error(`Timed out waiting for VS Code QuickPick item: ${itemText}.${available}`);
}

async function cancelInteraction(cdp, cancelKey, domTokens) {
  if (cancelKey !== "Escape" && cancelKey !== "Delete") {
    throw new Error(`Unsupported renderer cancelKey: ${cancelKey}`);
  }
  const keyEvent = cancelKey === "Escape"
    ? { key: "Escape", code: "Escape", windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 27 }
    : { key: "Delete", code: "Delete", windowsVirtualKeyCode: 46, nativeVirtualKeyCode: 46 };
  const targetText = domTokens.length > 0 ? domTokens[0] : "";
  const started = Date.now();
  const timeoutMs = CDP_REQUEST_TIMEOUT_MS;
  let surfaceDetails;
  while (Date.now() - started < timeoutMs) {
    const result = await evaluate(
      cdp,
      `(() => {
        const targetText = ${JSON.stringify(targetText)};
        const normalize = (value) => String(value ?? "").replace(/\\s+/g, " ").trim();
        const matchesTarget = (element) =>
          !targetText ||
          normalize(element.textContent).includes(targetText) ||
          normalize(element.getAttribute("aria-label")).includes(targetText);
        const quickInputSelectors = [
          ".quick-input-widget input.input",
          ".quick-input-widget input",
          ".quick-input-widget textarea"
        ];
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        };
        const input = quickInputSelectors
          .flatMap((selector) => Array.from(document.querySelectorAll(selector)))
          .find((element) => !element.disabled && visible(element));
        if (input) {
          input.focus();
          return {
            ready: true,
            surface: "quickInput",
            tagName: input.tagName,
            className: typeof input.className === "string" ? input.className : "",
            ariaLabel: input.getAttribute("aria-label") ?? "",
            placeholder: input.getAttribute("placeholder") ?? "",
            valueBefore: input.value ?? ""
          };
        }
        const notification = [
          ".notifications-toasts .notification-toast",
          ".notifications-toasts .monaco-list-row",
          ".notifications-list-container .notification-list-item",
          ".notifications-list-container .monaco-list-row",
          ".notification-toast",
          ".notification-list-item",
          "[aria-label*='notification']",
          "[role='alert']"
        ]
          .flatMap((selector) => Array.from(document.querySelectorAll(selector)))
          .find((element) => visible(element) && matchesTarget(element));
        if (notification) {
          if (typeof notification.focus === "function") {
            notification.focus();
          }
          return {
            ready: true,
            surface: "notification",
            tagName: notification.tagName,
            className: typeof notification.className === "string" ? notification.className : "",
            ariaLabel: notification.getAttribute("aria-label") ?? "",
            targetText,
            placeholder: "",
            valueBefore: ""
          };
        }
        const dialog = [
          ".monaco-dialog-box",
          ".dialog-box",
          "[role='dialog']"
        ]
          .flatMap((selector) => Array.from(document.querySelectorAll(selector)))
          .find((element) => visible(element));
        if (!dialog) {
          return { ready: false };
        }
        if (typeof dialog.focus === "function") {
          dialog.focus();
        }
        return {
          ready: true,
          surface: "dialog",
          tagName: dialog.tagName,
          className: typeof dialog.className === "string" ? dialog.className : "",
          ariaLabel: dialog.getAttribute("aria-label") ?? "",
          placeholder: "",
          valueBefore: ""
        };
      })()`,
    );
    if (result && result.ready === true) {
      surfaceDetails = result;
      break;
    }
    await sleep(250);
  }
  if (!surfaceDetails) {
    throw new Error("Timed out waiting for a cancellable VS Code renderer surface.");
  }

  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyDown",
    ...keyEvent,
  });
  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyUp",
    ...keyEvent,
  });

  const closedStarted = Date.now();
  while (Date.now() - closedStarted < timeoutMs) {
    const closeResult = await evaluate(
      cdp,
      `(() => {
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        };
        const quickInputSelectors = [
          ".quick-input-widget input.input",
          ".quick-input-widget input",
          ".quick-input-widget textarea"
        ];
        const input = quickInputSelectors
          .flatMap((selector) => Array.from(document.querySelectorAll(selector)))
          .find((element) => !element.disabled && visible(element));
        const dialog = [
          ".monaco-dialog-box",
          ".dialog-box",
          "[role='dialog']"
        ]
          .flatMap((selector) => Array.from(document.querySelectorAll(selector)))
          .find((element) => visible(element));
        const targetText = ${JSON.stringify(targetText)};
        const normalize = (value) => String(value ?? "").replace(/\\s+/g, " ").trim();
        const matchesTarget = (element) =>
          !targetText ||
          normalize(element.textContent).includes(targetText) ||
          normalize(element.getAttribute("aria-label")).includes(targetText);
        const notification = [
          ".notifications-toasts .notification-toast",
          ".notifications-toasts .monaco-list-row",
          ".notifications-list-container .notification-list-item",
          ".notifications-list-container .monaco-list-row",
          ".notification-toast",
          ".notification-list-item",
          "[aria-label*='notification']",
          "[role='alert']"
        ]
          .flatMap((selector) => Array.from(document.querySelectorAll(selector)))
          .find((element) => visible(element) && matchesTarget(element));
        return {
          quickInputVisible: Boolean(input),
          dialogVisible: Boolean(dialog),
          notificationVisible: Boolean(notification)
        };
      })()`,
    );
    const stillVisible = surfaceDetails.surface === "quickInput"
      ? closeResult && closeResult.quickInputVisible === true
      : surfaceDetails.surface === "dialog"
        ? closeResult && closeResult.dialogVisible === true
        : closeResult && closeResult.notificationVisible === true;
    if (!stillVisible) {
      return {
        cancelled: true,
        cancelledKey: cancelKey,
        surface: surfaceDetails.surface,
        tagName: surfaceDetails.tagName,
        className: surfaceDetails.className,
        ariaLabel: surfaceDetails.ariaLabel,
        placeholder: surfaceDetails.placeholder,
        valueBefore: surfaceDetails.valueBefore,
      };
    }
    await sleep(250);
  }
  throw new Error(`VS Code renderer surface remained visible after ${cancelKey} cancellation.`);
}

async function closeNotification(cdp, domTokens) {
  const targetTokens = domTokens.filter((token) => token && token.length > 0);
  const timeoutMs = 10000;
  let closeButtonDetails;
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    closeButtonDetails = await evaluate(
      cdp,
      `(() => {
        const targetTokens = ${JSON.stringify(targetTokens)};
        const targetText = targetTokens[0] ?? "";
        const visible = (element) => {
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0 && rect.right > 0 && rect.bottom > 0 && rect.left < window.innerWidth && rect.top < window.innerHeight;
        };
        const normalize = (value) => String(value ?? "").replace(/\\s+/g, " ").trim();
        const matchesTarget = (element) => {
          const text = normalize(element.textContent);
          const ariaLabel = normalize(element.getAttribute("aria-label"));
          return !targetText || text.includes(targetText) || ariaLabel.includes(targetText);
        };
        const notification = [
          ".notifications-toasts .notification-toast",
          ".notifications-toasts .monaco-list-row",
          ".notifications-list-container .notification-list-item",
          ".notifications-list-container .monaco-list-row",
          ".notification-toast",
          ".notification-list-item",
          "[aria-label*='notification']",
          "[role='alert']"
        ]
          .flatMap((selector) => Array.from(document.querySelectorAll(selector)))
          .find((element) => visible(element) && matchesTarget(element));
        if (!notification) {
          return { ready: false, notificationVisible: false };
        }
        const notificationRect = notification.getBoundingClientRect();
        const elementCenter = (element) => {
          const rect = element.getBoundingClientRect();
          return {
            x: rect.left + rect.width / 2,
            y: rect.top + rect.height / 2,
            rect
          };
        };
        const isTopRightCloseAffordance = (element) => {
          const center = elementCenter(element);
          return center.x >= notificationRect.left + notificationRect.width * 0.65 &&
            center.x <= notificationRect.right + 4 &&
            center.y >= notificationRect.top - 4 &&
            center.y <= notificationRect.top + Math.min(48, notificationRect.height * 0.5);
        };
        const closeSelectors = [
          "button[aria-label*='Close']",
          "button[aria-label*='Clear']",
          "button[title*='Close']",
          "button[title*='Clear']",
          "[role='button'][aria-label*='Close']",
          "[role='button'][aria-label*='Clear']",
          "[role='button'][title*='Close']",
          "[role='button'][title*='Clear']",
          ".notification-close",
          ".action-label.codicon-close",
          ".codicon-close",
          ".codicon-notifications-hide"
        ];
        const closeCandidates = closeSelectors
          .flatMap((selector) => Array.from(notification.querySelectorAll(selector)))
          .filter((element) => visible(element) && (!("disabled" in element) || element.disabled !== true));
        const closeButton = closeCandidates.find((element) => isTopRightCloseAffordance(element));
        const focusNotificationForClear = (fallbackFocus) => {
          if (typeof notification.focus === "function") {
            notification.focus();
          }
          if (document.activeElement !== notification && fallbackFocus && typeof fallbackFocus.focus === "function") {
            fallbackFocus.focus();
          }
          return document.activeElement === notification || document.activeElement === fallbackFocus;
        };
        if (!closeButton) {
          const fallbackX = notificationRect.right - Math.min(18, Math.max(8, notificationRect.width / 10));
          const fallbackY = notificationRect.top + Math.min(18, Math.max(8, notificationRect.height / 5));
          const fallbackElement = document.elementFromPoint(fallbackX, fallbackY);
          notification.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
          notification.dispatchEvent(new MouseEvent("mousemove", { bubbles: true }));
          const focused = focusNotificationForClear(fallbackElement);
          return {
            ready: true,
            notificationVisible: true,
            surface: "notification",
            x: fallbackX,
            y: fallbackY,
            focused,
            tagName: fallbackElement?.tagName ?? notification.tagName,
            className: typeof fallbackElement?.className === "string"
              ? fallbackElement.className
              : typeof notification.className === "string" ? notification.className : "",
            ariaLabel: fallbackElement?.getAttribute?.("aria-label") ?? notification.getAttribute("aria-label") ?? "",
            title: fallbackElement?.getAttribute?.("title") ?? "notificationTopRightFallback"
          };
        }
        const { rect } = elementCenter(closeButton);
        closeButton.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
        closeButton.dispatchEvent(new MouseEvent("mousemove", { bubbles: true }));
        const focused = focusNotificationForClear(closeButton);
        return {
          ready: true,
          surface: "notification",
          x: rect.left + rect.width / 2,
          y: rect.top + rect.height / 2,
          focused,
          tagName: closeButton.tagName,
          className: typeof closeButton.className === "string" ? closeButton.className : "",
          ariaLabel: closeButton.getAttribute("aria-label") ?? "",
          title: closeButton.getAttribute("title") ?? ""
        };
      })()`,
    );
    if (closeButtonDetails && closeButtonDetails.ready === true) {
      break;
    }
    if (closeButtonDetails?.hoverTarget) {
      await cdp.send("Input.dispatchMouseEvent", {
        type: "mouseMoved",
        x: closeButtonDetails.hoverTarget.x,
        y: closeButtonDetails.hoverTarget.y,
      });
    }
    await sleep(250);
  }
  if (!closeButtonDetails || closeButtonDetails.ready !== true) {
    throw new Error("Timed out waiting for a closeable VS Code notification.");
  }
  if (closeButtonDetails.focused !== true) {
    throw new Error(`VS Code notification close affordance was found but not focused. Close attempt: ${JSON.stringify(closeButtonDetails)}`);
  }
  const deleteKeyEvent = { key: "Delete", code: "Delete", windowsVirtualKeyCode: 46, nativeVirtualKeyCode: 46 };
  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyDown",
    ...deleteKeyEvent,
  });
  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyUp",
    ...deleteKeyEvent,
  });

  const closedStarted = Date.now();
  while (Date.now() - closedStarted < timeoutMs) {
    const closeResult = await evaluate(
      cdp,
      `(() => {
        const targetTokens = ${JSON.stringify(targetTokens)};
        const normalize = (value) => String(value ?? "").replace(/\\s+/g, " ").trim();
        const bodyText = normalize(document.body ? document.body.innerText : "");
        return {
          notificationVisible: targetTokens.length > 0 && targetTokens.every((token) => bodyText.includes(token))
        };
      })()`,
    );
    if (!closeResult || closeResult.notificationVisible !== true) {
      return {
        cancelled: true,
        cancelledAction: "closeNotification",
        surface: "notification",
        tagName: closeButtonDetails.tagName,
        className: closeButtonDetails.className,
        ariaLabel: closeButtonDetails.ariaLabel,
        title: closeButtonDetails.title,
      };
    }
    await sleep(250);
  }
  throw new Error(`VS Code notification remained visible after closeNotification cancellation. Close attempt: ${JSON.stringify(closeButtonDetails)}`);
}

function accessibilityTreeText(tree) {
  return (tree.nodes ?? [])
    .flatMap((node) => [node.role, node.name, node.value, node.description])
    .map((field) => {
      if (!field || typeof field !== "object") {
        return "";
      }
      return String(field.value ?? "");
    })
    .filter((value) => value.length > 0)
    .join("\n");
}

async function captureScreenshotWithRetry(cdp) {
  let lastError;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      await cdp.send("Page.bringToFront").catch(() => undefined);
      if (attempt > 1) {
        await sleep(500 * attempt);
      }
      return await cdp.send("Page.captureScreenshot", {
        format: "png",
        captureBeyondViewport: false,
      });
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new Error("CDP request timed out: Page.captureScreenshot");
}

function matchTokens(text, tokens) {
  const matched = tokens.filter((token) => text.includes(token));
  return {
    matched,
    missing: tokens.filter((token) => !matched.includes(token)),
  };
}

function artifact(status, outputRoot, artifactPath, extra) {
  return {
    status,
    relativePath: path.relative(outputRoot, artifactPath).replaceAll(path.sep, "/"),
    sha256: sha256File(artifactPath),
    ...extra,
  };
}

function failedArtifact(artifactPath, error) {
  return {
    status: "failed",
    relativePath: path.basename(artifactPath),
    sha256: existsSync(artifactPath) ? sha256File(artifactPath) : null,
    error: {
      message: error instanceof Error ? error.message : String(error),
    },
  };
}

function sha256File(filePath) {
  return createHash("sha256").update(requireFileBytes(filePath)).digest("hex");
}

function requireFileBytes(filePath) {
  if (!existsSync(filePath)) {
    throw new Error(`Expected artifact file does not exist: ${filePath}`);
  }
  return readFileSync(filePath);
}

function inspectPng(buffer) {
  const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (!buffer.subarray(0, signature.length).equals(signature)) {
    throw new Error("Screenshot artifact is not a PNG file.");
  }
  let offset = 8;
  let width;
  let height;
  let bitDepth;
  let colorType;
  const idatChunks = [];
  while (offset < buffer.length) {
    const length = buffer.readUInt32BE(offset);
    offset += 4;
    const type = buffer.subarray(offset, offset + 4).toString("ascii");
    offset += 4;
    const data = buffer.subarray(offset, offset + length);
    offset += length;
    offset += 4;
    if (type === "IHDR") {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data.readUInt8(8);
      colorType = data.readUInt8(9);
    } else if (type === "IDAT") {
      idatChunks.push(data);
    } else if (type === "IEND") {
      break;
    }
  }
  if (!width || !height || bitDepth !== 8 || ![0, 2, 6].includes(colorType)) {
    throw new Error(`Unsupported PNG format: ${width}x${height}, bitDepth=${bitDepth}, colorType=${colorType}.`);
  }
  const bytesPerPixel = colorType === 6 ? 4 : colorType === 2 ? 3 : 1;
  const inflated = inflateSync(Buffer.concat(idatChunks));
  const stride = width * bytesPerPixel;
  const previous = Buffer.alloc(stride);
  const current = Buffer.alloc(stride);
  const sampledColors = new Set();
  let inputOffset = 0;
  for (let y = 0; y < height; y += 1) {
    const filterType = inflated[inputOffset];
    inputOffset += 1;
    inflated.copy(current, 0, inputOffset, inputOffset + stride);
    inputOffset += stride;
    unfilterScanline(current, previous, bytesPerPixel, filterType);
    const sampleEvery = Math.max(1, Math.floor(width / 64));
    for (let x = 0; x < width; x += sampleEvery) {
      const pixelOffset = x * bytesPerPixel;
      sampledColors.add(
        `${current[pixelOffset]},${current[pixelOffset + Math.min(1, bytesPerPixel - 1)]},${
          current[pixelOffset + Math.min(2, bytesPerPixel - 1)]
        }`,
      );
    }
    current.copy(previous);
  }
  return {
    width,
    height,
    bitDepth,
    colorType,
    nonBlank: sampledColors.size > 1,
    uniqueColorSampleCount: sampledColors.size,
  };
}

function unfilterScanline(current, previous, bytesPerPixel, filterType) {
  for (let index = 0; index < current.length; index += 1) {
    const left = index >= bytesPerPixel ? current[index - bytesPerPixel] : 0;
    const up = previous[index];
    const upLeft = index >= bytesPerPixel ? previous[index - bytesPerPixel] : 0;
    let value;
    switch (filterType) {
      case 0:
        value = current[index];
        break;
      case 1:
        value = current[index] + left;
        break;
      case 2:
        value = current[index] + up;
        break;
      case 3:
        value = current[index] + Math.floor((left + up) / 2);
        break;
      case 4:
        value = current[index] + paethPredictor(left, up, upLeft);
        break;
      default:
        throw new Error(`Unsupported PNG filter type: ${filterType}.`);
    }
    current[index] = value & 0xff;
  }
}

function paethPredictor(left, up, upLeft) {
  const p = left + up - upLeft;
  const pa = Math.abs(p - left);
  const pb = Math.abs(p - up);
  const pc = Math.abs(p - upLeft);
  if (pa <= pb && pa <= pc) {
    return left;
  }
  if (pb <= pc) {
    return up;
  }
  return upLeft;
}

async function writeCaptureReport(reportPath, report) {
  await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

await main();
