import PiDurableKit

/// The pinned runtime's JS hook replaces only one request. Keeping this transform
/// in JS avoids Swift Message decoding dropping opaque provider thought signatures.
/// Durable tool results remain intact for recovery and historical image previews.
enum DeviceImageContext {
    static let runtimeExtension = Extension("eiscue-device-image-context", javaScript: #"""
    const { defineExtension, hook, GenerationTask } = require("@earendil-works/pi-durable");
    module.exports = defineExtension({
        name: "eiscue-device-image-context",
        hooks: [hook(GenerationTask, {
            beforeRequest(request) {
                let remaining = 2;
                const messages = request.messages.slice();
                for (let i = messages.length - 1; i >= 0; i--) {
                    const message = messages[i];
                    if (message.role !== "toolResult" || typeof message.toolName !== "string"
                        || !message.toolName.startsWith("device_") || !Array.isArray(message.content)) continue;
                    let changed = false;
                    const content = message.content.slice();
                    for (let j = content.length - 1; j >= 0; j--) {
                        if (content[j].type !== "image") continue;
                        if (remaining > 0) { remaining--; continue; }
                        content[j] = { type: "text", text: "[Older device screenshot omitted from model context; retained in history. Observe again if needed.]" };
                        changed = true;
                    }
                    if (changed) messages[i] = { ...message, content };
                }
                return { messages };
            }
        })]
    });
    """#)
}
