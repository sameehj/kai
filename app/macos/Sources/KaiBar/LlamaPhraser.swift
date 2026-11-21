// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// The optional local phraser: a small GGUF model run in-process by llama.cpp
// (the pinned xcframework in app/macos/Packages/LlamaBinary). It only rewords
// AskEngine's answer (see AskPhraser.swift); any failure throws and the caller
// shows the template text.
//
// Privacy: prompts and outputs are never logged. llama.cpp's own log output
// is silenced. No network: the model is a local file from ModelStore.
//
// All llama state lives on one serial queue: phrase() and smokeTest() are
// safe to call from any thread, and calls run one at a time. The model is
// loaded on first use and kept.
//
// Built without the llama module (e.g. the swiftc app tests), this compiles
// to a stub that is never available.
import Foundation

#if canImport(llama)
import llama

final class LlamaPhraser: AskPhraser, @unchecked Sendable {
    var kind: PhraserKind { .local }

    private let model: LocalModel?
    private let explicitFile: URL?
    private let store: ModelStore
    private let queue = DispatchQueue(label: "io.github.sameehj.kai.llama", qos: .userInitiated)
    // Touched only on `queue`.
    private var llmModel: OpaquePointer?
    private var ctx: OpaquePointer?
    private var loadedPath: String?

    /// Context size: PhrasePrompts.clamp keeps the user turn near 1400 tokens,
    /// plus the system turn and up to maxTokens of output.
    private static let contextTokens: UInt32 = 2048

    /// A catalog model, used once ModelStore has it installed and verified.
    init(model: LocalModel = ModelStore.defaultModel, store: ModelStore = .shared) {
        self.model = model
        self.explicitFile = nil
        self.store = store
    }

    /// A specific GGUF file (tests, $KAI_LLAMA_MODEL). Not hash-checked here.
    init(modelFile: URL) {
        self.model = nil
        self.explicitFile = modelFile
        self.store = .shared
    }

    deinit {
        let m = llmModel, c = ctx
        if c != nil || m != nil, Self.libraryLoaded {
            queue.async {
                if let c { llama_free(c) }
                if let m { llama_model_free(m) }
            }
        }
    }

    private var resolvedFile: URL? {
        if let explicitFile {
            return FileManager.default.isReadableFile(atPath: explicitFile.path) ? explicitFile : nil
        }
        guard let model else { return nil }
        return store.installedURL(for: model)
    }

    /// llama.framework is weak-linked (project.yml): macOS refuses to load it
    /// into an ad-hoc signed, hardened app (`make app`: "different Team IDs"),
    /// and the app must still launch then. Team-signed builds load it.
    static let libraryLoaded: Bool = {
        guard let handle = dlopen(nil, RTLD_NOW) else { return false }
        return dlsym(handle, "llama_backend_init") != nil && dlsym(handle, "llama_decode") != nil
    }()

    var isAvailable: Bool { Self.libraryLoaded && resolvedFile != nil }

    func phrase(_ prompt: PhrasePrompt) async throws -> String {
        guard Self.libraryLoaded, let file = resolvedFile else { throw PhraserError.unavailable }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let out = try self.generate(file: file, system: prompt.system, user: prompt.user,
                                                maxTokens: prompt.maxTokens, requireEnd: true)
                    cont.resume(returning: out)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Loads the model and generates `tokens` tokens from a fixed prompt.
    /// Returns the raw text (may be cut mid-sentence). For tests only.
    func smokeTest(tokens: Int = 8) throws -> String {
        guard Self.libraryLoaded, let file = resolvedFile else { throw PhraserError.unavailable }
        return try queue.sync {
            try generate(file: file, system: "You are a helpful assistant.",
                         user: "Say hello in one short sentence.",
                         maxTokens: tokens, requireEnd: false, keepRaw: true)
        }
    }

    // MARK: - On `queue`

    private static let backend: Void = {
        // Silence llama.cpp/ggml logs (they can include model metadata and
        // timings; we never want prompt-derived text in system logs).
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    private func load(_ file: URL) throws {
        if loadedPath == file.path, ctx != nil { return }
        if let c = ctx { llama_free(c); ctx = nil }
        if let m = llmModel { llama_model_free(m); llmModel = nil }
        loadedPath = nil
        _ = Self.backend

        var mp = llama_model_default_params()
        #if arch(x86_64)
        mp.n_gpu_layers = 0          // Intel Macs: CPU only (Metal there is slow or unsupported)
        #else
        mp.n_gpu_layers = 99         // Apple silicon: all layers on the GPU
        #endif
        guard let m = llama_model_load_from_file(file.path, mp) else { throw PhraserError.unavailable }

        var cp = llama_context_default_params()
        cp.n_ctx = Self.contextTokens
        cp.n_batch = Self.contextTokens
        cp.n_ubatch = 512
        cp.n_seq_max = 1
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        cp.no_perf = true
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw PhraserError.unavailable
        }
        llmModel = m
        ctx = c
        loadedPath = file.path
    }

    /// The chat-formatted prompt: the model's own template when llama.cpp
    /// knows it, else ChatML. Thinking models get an empty think block so
    /// they answer directly.
    private func formatted(system: String, user: String) -> String {
        guard let m = llmModel else { return Self.chatML(system: system, user: user) }
        let tmpl = llama_model_chat_template(m, nil).map { String(cString: $0) }
        var text: String?
        if let tmpl {
            text = system.withCString { sys in
                user.withCString { usr in
                    "system".withCString { rs in
                        "user".withCString { ru in
                            var msgs = [llama_chat_message(role: rs, content: sys),
                                        llama_chat_message(role: ru, content: usr)]
                            var cap = Int32((system.utf8.count + user.utf8.count) * 2 + 512)
                            for _ in 0..<2 {
                                var buf = [CChar](repeating: 0, count: Int(cap))
                                let n = llama_chat_apply_template(tmpl, &msgs, msgs.count, true, &buf, cap)
                                if n < 0 { return nil }
                                if n <= cap {
                                    return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                                }
                                cap = n + 1
                            }
                            return nil
                        }
                    }
                }
            }
        }
        var out = text ?? Self.chatML(system: system, user: user)
        if let tmpl, tmpl.contains("<think>"), !out.hasSuffix("</think>\n\n") {
            out += "<think>\n\n</think>\n\n"
        }
        return out
    }

    private static func chatML(system: String, user: String) -> String {
        "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
    }

    private func generate(file: URL, system: String, user: String, maxTokens: Int,
                          requireEnd: Bool, keepRaw: Bool = false) throws -> String {
        try load(file)
        guard let m = llmModel, let c = ctx, let vocab = llama_model_get_vocab(m) else {
            throw PhraserError.unavailable
        }
        llama_memory_clear(llama_get_memory(c), true)

        let prompt = formatted(system: system, user: user)
        var tokens = [llama_token](repeating: 0, count: prompt.utf8.count + 16)
        let n = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, Int32(tokens.count), true, true)
        guard n > 0 else { throw PhraserError.unavailable }
        tokens.removeSubrange(Int(n)...)
        let budget = max(1, maxTokens)
        guard tokens.count + budget <= Int(llama_n_ctx(c)), tokens.count <= Int(llama_n_batch(c)) else {
            throw PhraserError.tooLong
        }

        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(chain) }
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.1, 0, 0))
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())

        let rc = tokens.withUnsafeMutableBufferPointer { buf in
            llama_decode(c, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
        }
        guard rc == 0 else { throw PhraserError.unavailable }

        var bytes: [UInt8] = []
        var piece = [CChar](repeating: 0, count: 256)
        var produced = 0
        var ended = false
        while produced < budget {
            var tok = llama_sampler_sample(chain, c, -1)
            if llama_vocab_is_eog(vocab, tok) { ended = true; break }
            let len = llama_token_to_piece(vocab, tok, &piece, Int32(piece.count), 0, false)
            if len > 0 { bytes.append(contentsOf: piece.prefix(Int(len)).map { UInt8(bitPattern: $0) }) }
            produced += 1
            let r = llama_decode(c, llama_batch_get_one(&tok, 1))
            guard r == 0 else { throw PhraserError.unavailable }
        }
        guard produced > 0 else { throw PhraserError.emptyOutput }
        let text = String(decoding: bytes, as: UTF8.self)
        if keepRaw { return text }
        if requireEnd && !ended { throw PhraserError.tooLong }   // cut mid-answer: use the template
        let clean = Self.stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw PhraserError.emptyOutput }
        return clean
    }

    private static func stripThinking(_ s: String) -> String {
        var out = s
        while let open = out.range(of: "<think>") {
            if let close = out.range(of: "</think>", range: open.upperBound..<out.endIndex) {
                out.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                out.removeSubrange(open.lowerBound..<out.endIndex)
            }
        }
        return out
    }
}

#else

/// Built without llama.cpp: never available.
final class LlamaPhraser: AskPhraser {
    var kind: PhraserKind { .local }
    var isAvailable: Bool { false }
    init(model: LocalModel = ModelStore.defaultModel, store: ModelStore = .shared) {}
    init(modelFile: URL) {}
    func phrase(_ prompt: PhrasePrompt) async throws -> String { throw PhraserError.unavailable }
    func smokeTest(tokens: Int = 8) throws -> String { throw PhraserError.unavailable }
}

#endif
