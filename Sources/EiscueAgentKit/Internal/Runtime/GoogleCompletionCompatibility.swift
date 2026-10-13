import Foundation
import PiDurableKit

enum GoogleCompletionCompatibility {
    static func applies(to configuration: AgentConfiguration) -> Bool {
        let url = configuration.baseURL
        return configuration.api == .openAICompletions && url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "generativelanguage.googleapis.com"
            && (url.port == nil || url.port == 443)
            && (url.path == "/v1beta/openai" || url.path == "/v1beta/openai/")
    }

    // The supported JS hook mutates the terminal response before Pi classifies
    // and journals it. Swift hooks receive a copy. Execution still belongs to
    // Pi's durable tool scheduler and the host's existing permission gates.
    static let runtimeExtension = Extension("eiscue-google-completion", javaScript: #"""
    const { defineExtension, hook, GenerationTask } = require("@earendil-works/pi-durable");
    const installed = Symbol.for("org.eiscue.google-completion-signatures.v1");
    const completeMessages = new WeakSet();

    function isGoogleCompletion(model) {
        if (model.api !== "openai-completions") return false;
        const url = new URL(model.baseUrl);
        return url.protocol === "https:" && url.hostname === "generativelanguage.googleapis.com"
            && (url.port === "" || url.port === "443")
            && (url.pathname === "/v1beta/openai" || url.pathname === "/v1beta/openai/")
            && !url.username && !url.password && !url.search && !url.hash;
    }

    function restoreSignatures(payload, context, model) {
        // Keep assistant groups in transcript order: call IDs can be reused in
        // later turns. Never transfer a signature across models or calls.
        const groups = context.messages.filter(message => message.role === "assistant"
            && message.stopReason !== "error" && message.stopReason !== "aborted")
            .map(message => ({ message, calls: message.content.filter(block => block.type === "toolCall") }))
            .filter(group => group.calls.length > 0);
        let index = 0;
        for (const wire of payload.messages || []) {
            if (wire.role !== "assistant" || !Array.isArray(wire.tool_calls) || wire.tool_calls.length === 0) continue;
            const group = groups[index++];
            if (!group || group.message.provider !== model.provider || group.message.api !== model.api
                || group.message.model !== model.id || group.calls.length !== wire.tool_calls.length) continue;
            for (let i = 0; i < group.calls.length; i++) {
                const call = group.calls[i], target = wire.tool_calls[i];
                if (call.id !== target.id || call.name !== target.function?.name
                    || typeof call.thoughtSignature !== "string" || call.thoughtSignature.length === 0) continue;
                target.extra_content = { ...target.extra_content,
                    google: { ...target.extra_content?.google, thought_signature: call.thoughtSignature } };
            }
        }
        return payload;
    }

    function preserveSignatures(models) {
        if (models[installed]) return;
        const original = models.streamSimple.bind(models);
        // This is a pinned-SDK adapter on this Models instance, not a global
        // fetch hook. The original provider still owns HTTP and cancellation.
        models.streamSimple = (model, context, options = {}) => {
            if (!isGoogleCompletion(model)) return original(model, context, options);
            const incoming = new Map();
            let bufferedCharacters = 0;
            const reserve = text => {
                bufferedCharacters += text.length;
                if (bufferedCharacters > 2 * 1024 * 1024) throw new Error("Google tool metadata is too large");
            };
            const stream = original(model, context, {
                ...options,
                onPayload: async (payload, currentModel) => {
                    const changed = await options.onPayload?.(payload, currentModel);
                    return restoreSignatures(changed ?? payload, context, currentModel);
                },
                onProviderStreamEvent: async (event, currentModel) => {
                    const deltas = event.choices?.[0]?.delta?.tool_calls || [];
                    for (let i = 0; i < deltas.length; i++) {
                        const delta = deltas[i];
                        let index = delta.index;
                        if (index == null) {
                            // Some Google chunks omit index. An explicit ID or
                            // a single outstanding call is unambiguous; parallel
                            // unidentified fragments must never inherit another call.
                            const known = [...incoming].find(([, entry]) => entry.id && entry.id === delta.id);
                            if (known) index = known[0];
                            else if (typeof delta.id === "string" && delta.id.length > 0) index = "id:" + delta.id;
                            else if (incoming.size === 1) index = incoming.keys().next().value;
                            else throw new Error("Ambiguous Google tool fragment");
                        } else if (!Number.isInteger(index) || index < 0) {
                            throw new Error("Invalid Google tool index");
                        } else if (!incoming.has(index) && typeof delta.id === "string" && delta.id.length > 0) {
                            const known = [...incoming].find(([, entry]) => entry.id === delta.id);
                            if (known) {
                                incoming.delete(known[0]);
                                incoming.set(index, known[1]);
                            }
                        }
                        const entry = incoming.get(index) || {};
                        if (entry.id && delta.id && entry.id !== delta.id) throw new Error("Conflicting Google tool ID");
                        if (typeof delta.id === "string" && delta.id.length > 0) entry.id = delta.id;
                        if (typeof delta.function?.arguments === "string") {
                            reserve(delta.function.arguments);
                            entry.arguments = (entry.arguments || "") + delta.function.arguments;
                        }
                        const signature = delta.extra_content?.google?.thought_signature;
                        if (typeof signature === "string" && signature.length > 0) {
                            if (entry.signature && entry.signature !== signature) throw new Error("Conflicting Google tool signature");
                            if (!entry.signature) reserve(signature);
                            entry.signature = signature;
                        }
                        incoming.set(index, entry);
                    }
                    await options.onProviderStreamEvent?.(event, currentModel);
                }
            });
            const result = stream.result.bind(stream);
            stream.result = async () => {
                const message = await result();
                const toolCalls = message.content.filter(block => block.type === "toolCall");
                // Pi repairs partial JSON for streaming previews. A mislabeled
                // stop must not promote an unfinished argument fragment to an action.
                const complete = toolCalls.every(call => {
                    const entries = [...incoming.values()].filter(entry => entry.id === call.id);
                    if (entries.length !== 1) return false;
                    try {
                        const parsed = JSON.parse(entries[0].arguments);
                        return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed);
                    } catch { return false; }
                });
                if (complete) completeMessages.add(message);
                for (const entry of incoming.values()) {
                    if (!entry.id || !entry.signature) continue;
                    const calls = message.content.filter(block => block.type === "toolCall" && block.id === entry.id);
                    if (calls.length !== 1) throw new Error("Ambiguous Google tool signature");
                    // Pi's existing opaque field survives JS persistence and is
                    // deliberately omitted from Swift tool arguments and UI.
                    calls[0].thoughtSignature = entry.signature;
                }
                return message;
            };
            return stream;
        };
        Object.defineProperty(models, installed, { value: completeMessages });
    }

    module.exports = defineExtension({
        name: "eiscue-google-completion",
        hooks: [hook(GenerationTask, {
            beforeRequest(request, api) { preserveSignatures(api.models); },
            afterResponse(message, api) {
                if (message.api !== "openai-completions" || message.stopReason !== "stop"
                    || message.rawStopReason !== "stop" || message.errorMessage
                    || !api.models[installed]?.has(message)) return;
                const calls = message.content.filter(block => block.type === "toolCall");
                if (calls.length === 0 || !calls.every(call =>
                    typeof call.id === "string" && call.id.trim().length > 0
                    && typeof call.name === "string" && call.name.trim().length > 0
                    && call.arguments !== null && typeof call.arguments === "object"
                    && !Array.isArray(call.arguments))) return;
                if (new Set(calls.map(call => call.id)).size !== calls.length) return;
                message.stopReason = "toolUse";
            }
        })]
    });
    """#)
}
