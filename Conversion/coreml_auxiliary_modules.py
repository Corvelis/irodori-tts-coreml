"""Torch wrappers for the official Irodori v4.1 MF auxiliary weights.

Architecture adaptations follow Aratako/Irodori-TTS (MIT, Copyright 2026
Aratako). The source checkout is supplied explicitly and remains a dependency.
"""
import dataclasses
import json
import sys
import types

import torch
from safetensors import safe_open


def build(name, checkpoint, source_root, input_names):
    try:
        import transformers.initialization
    except ImportError:
        from transformers.modeling_utils import no_init_weights
        compatibility = types.ModuleType("transformers.initialization")
        compatibility.no_init_weights = no_init_weights
        sys.modules[compatibility.__name__] = compatibility
    sys.path.insert(0, str(source_root))
    import irodori_tts.model as upstream
    from irodori_tts.config import ModelConfig
    with safe_open(str(checkpoint), framework="pt", device="cpu") as source:
        metadata = source.metadata()
    raw = json.loads(metadata["config_json"])
    cfg = ModelConfig(**{k: v for k, v in raw.items()
                         if k in {f.name for f in dataclasses.fields(ModelConfig)}})

    class Context(torch.nn.Module):
        def __init__(self, kinds):
            super().__init__()
            self.kinds = kinds
            self.blocks = torch.nn.ModuleList()
            for i in range(cfg.num_layers):
                block = torch.nn.Module()
                a = torch.nn.Module()
                for kind in kinds:
                    dim = cfg.speaker_dim if kind == "speaker" else cfg.text_dim
                    setattr(a, "wk_" + kind, torch.nn.Linear(dim, cfg.model_dim, bias=False))
                    setattr(a, "wv_" + kind, torch.nn.Linear(dim, cfg.model_dim, bias=False))
                a.k_norm = upstream.RMSNorm((cfg.num_heads, cfg.model_dim // cfg.num_heads), cfg.norm_eps)
                block.attention = a
                self.blocks.append(block)

        def forward(self, *states):
            outputs = []
            for block in self.blocks:
                for kind in self.kinds:
                    state = states[input_names.index(kind + "_state")]
                    a = block.attention
                    shape = (state.shape[0], state.shape[1], cfg.num_heads, cfg.model_dim // cfg.num_heads)
                    outputs.extend((a.k_norm(getattr(a, "wk_" + kind)(state).reshape(shape)),
                                    getattr(a, "wv_" + kind)(state).reshape(shape)))
            return tuple(outputs)

    class Duration(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.duration_predictor = upstream.DurationPredictor(
                text_dim=cfg.text_dim, aux_dim=cfg.duration_aux_dim,
                hidden_dim=cfg.duration_hidden_dim, layers=cfg.duration_layers,
                dropout=cfg.duration_dropout, speaker_dim=cfg.speaker_dim,
                speaker_fusion=cfg.duration_speaker_fusion,
                caption_dim=cfg.caption_dim_resolved, caption_fusion=cfg.duration_caption_fusion,
                caption_pooling=cfg.duration_caption_pooling, attention_heads=cfg.duration_attention_heads,
                norm_eps=cfg.norm_eps, architecture=cfg.duration_architecture,
                token_init_frames=cfg.duration_token_init_frames)

        def forward(self, text_state, text_mask, speaker_state, has_speaker,
                    caption_state, caption_mask, has_caption):
            return self.duration_predictor(text_state, text_mask=text_mask > .5,
                aux_features=torch.zeros((text_state.shape[0], cfg.duration_aux_dim)),
                speaker_state=speaker_state, has_speaker=has_speaker > .5,
                caption_state=caption_state, caption_mask=caption_mask > .5,
                has_caption=has_caption > .5)

    class Text(torch.nn.Module):
        def __init__(self):
            super().__init__()
            config = json.loads(metadata["text_encoder_config_json"])
            config["_attn_implementation"] = "eager"
            config["reference_compile"] = False
            self.pretrained_text_backbone = upstream.PretrainedTextBackbone(
                cfg.text_tokenizer_repo, config_dict=config, load_pretrained_weights=False)
            self.pretrained_text_backbone.backbone.config._attn_implementation = "eager"
            for kind in ("text", "caption"):
                setattr(self, kind + "_encoder", upstream.PretrainedConditionProjector(
                    768, 512, projector_type=cfg.pretrained_projector_type,
                    hidden_ratio=cfg.pretrained_projector_hidden_ratio, norm_eps=cfg.norm_eps))
                setattr(self, kind + "_norm", upstream.RMSNorm(512, eps=cfg.norm_eps))

        def forward(self, input_ids, mask):
            mask = mask > .5
            state = self.pretrained_text_backbone(input_ids, mask)
            outputs = []
            for kind in ("text", "caption"):
                p = getattr(self, kind + "_encoder")
                value = p.projector(state)
                value = value + p.residual_down(torch.nn.functional.silu(p.residual_up(p.residual_norm(state))))
                outputs.append(getattr(self, kind + "_norm")(value * mask.unsqueeze(-1).float()))
            return tuple(outputs)

    class Speaker(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.speaker_encoder = upstream.ReferenceLatentEncoder(cfg)
            self.speaker_norm = upstream.RMSNorm(cfg.speaker_dim, eps=cfg.norm_eps)
            dim = self.speaker_encoder.head_dim
            angles = torch.outer(torch.arange(751, dtype=torch.float32),
                1.0 / (10000.0 ** (torch.arange(0, dim, 2, dtype=torch.float32) / dim)))
            self.speaker_encoder._freqs_cis_cache = torch.stack((angles.cos(), angles.sin()), dim=-1)

        def forward(self, ref_latent, mask):
            latent, mask = upstream.patch_sequence_with_mask(ref_latent, mask > .5, cfg.speaker_patch_size)
            state = self.speaker_norm(self.speaker_encoder(latent, mask))
            state, mask = upstream.TextToLatentRFDiT._prepend_masked_mean_token(state, mask)
            return state, mask.float()

    if name == "context_kv_text":
        module = Context(("text", "caption"))
    elif name == "context_kv_speaker":
        module = Context(("speaker",))
    elif name == "duration":
        module = Duration()
    elif name == "text_encoder":
        module = Text()
    elif name == "speaker_encoder":
        def real_rope(x, freqs):
            pair = x.float().reshape(*x.shape[:3], -1, 2)
            cosine, sine = freqs[None, :, None, :, 0], freqs[None, :, None, :, 1]
            rotated = torch.stack((pair[..., 0] * cosine - pair[..., 1] * sine,
                                   pair[..., 0] * sine + pair[..., 1] * cosine), dim=-1)
            return rotated.reshape_as(x).to(x.dtype)
        upstream.apply_rotary_emb = real_rope
        def masked_attention(q, k, v, key_mask):
            q, k, v = (a.transpose(1, 2) for a in (q, k, v))
            any_key = key_mask.any(dim=-1, keepdim=True)
            first_key = torch.arange(key_mask.shape[1], device=key_mask.device)[None, :] == 0
            safe_mask = torch.where(any_key, key_mask, first_key)
            scores = torch.matmul(q, k.transpose(-1, -2)) / (q.shape[-1] ** .5)
            scores = scores.masked_fill(~safe_mask[:, None, None, :], float("-inf"))
            result = torch.matmul(scores.softmax(dim=-1), v).transpose(1, 2)
            return result * any_key[:, :, None, None].float()
        upstream.prefix_key_mask_attention = masked_attention
        module = Speaker()
    else:
        raise ValueError(f"No official wrapper for {name}")
    with safe_open(str(checkpoint), framework="pt", device="cpu") as source:
        with torch.no_grad():
            for key, parameter in module.named_parameters():
                parameter.copy_(source.get_tensor(key))
    return module.eval()
