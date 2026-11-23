// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// The local model phraser (LlamaPhraser.swift): llama.cpp through LLamaSharp
// (pinned, with its CPU backend), loading only the verified model file from
// ModelStore. It rewords Kai's answer or picks one intent label; it never
// sees records, and its output is used only if Phrasers.Accept keeps it.
// ChatML prompt with an empty think block, low temperature, a hard token cap;
// a reply cut off before it ended is not used.
using Kai.Core;
using LLama;
using LLama.Common;
using LLama.Sampling;

namespace Kai;

public sealed class LlamaPhraser(string modelPath) : IAskPhraser, IDisposable
{
    LLamaWeights? _weights;
    ModelParams? _params;
    readonly SemaphoreSlim _one = new(1, 1);

    public PhraserKind Kind => PhraserKind.Local;
    public bool IsAvailable => File.Exists(modelPath);

    public async Task<string> PhraseAsync(PhrasePrompt prompt, CancellationToken ct = default)
    {
        await _one.WaitAsync(ct);
        try
        {
            if (_weights is null)
            {
                _params = new ModelParams(modelPath) { ContextSize = 2048, GpuLayerCount = 0 };
                _weights = await LLamaWeights.LoadFromFileAsync(_params, ct);
            }
            var exec = new StatelessExecutor(_weights, _params!);
            var text = "<|im_start|>system\n" + prompt.System + "<|im_end|>\n<|im_start|>user\n" + prompt.User
                       + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
            var ip = new InferenceParams
            {
                MaxTokens = prompt.MaxTokens,
                AntiPrompts = new[] { "<|im_end|>", "<|im_start|>" },
                SamplingPipeline = new DefaultSamplingPipeline { Temperature = 0.2f },
            };
            var sb = new System.Text.StringBuilder();
            int tokens = 0;
            await foreach (var piece in exec.InferAsync(text, ip, ct))
            {
                sb.Append(piece);
                tokens++;
            }
            var o = sb.ToString();
            bool ended = o.Contains("<|im_end|>", StringComparison.Ordinal) || tokens < prompt.MaxTokens;
            if (!ended && prompt.MaxTokens > 8) throw new InvalidOperationException("the model's reply was cut off");
            o = o.Replace("<|im_end|>", "").Replace("<|im_start|>", "");
            int think;
            while ((think = o.IndexOf("<think>", StringComparison.Ordinal)) >= 0)
            {
                int end = o.IndexOf("</think>", think, StringComparison.Ordinal);
                o = end < 0 ? o[..think] : o[..think] + o[(end + 8)..];
            }
            o = o.Trim();
            if (o.Length == 0) throw new InvalidOperationException("the model gave no answer");
            return o;
        }
        finally { _one.Release(); }
    }

    public void Dispose()
    {
        _weights?.Dispose();
        _weights = null;
    }
}
