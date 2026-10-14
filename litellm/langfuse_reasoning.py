"""给 LiteLLM 的 langfuse_otel 回调补上模型的思维链。

LiteLLM 往 Langfuse 写输出时只保留 role 和 content，思维链（reasoning_content /
thinking_blocks）被丢掉，社区问题见 https://github.com/BerriAI/litellm/issues/44520 。
本模块在原函数写完输出之后，把思维链按 Langfuse 官方 ChatML 格式补进同一份输出：

    {"role": "assistant", "content": "回答", "thinking": [{"type": "thinking", "content": "思维链"}]}

这样 Langfuse 界面会显示可折叠的 Thinking 区块，content 仍是普通字符串，原有按 content 取回答的查询不受影响。
流式请求结束后 LiteLLM 传给回调的是拼好的完整响应，所以流式也能覆盖。

开关：环境变量 LANGFUSE_LOG_REASONING（写在 .env 里），true 开启（默认），false 关闭。
关闭时行为与原生 langfuse_otel 完全一致。改了之后要重建 litellm 容器才生效（用 deploy.sh 部署的执行 ./deploy.sh）。

加载方式：config.yaml 的 litellm_settings.callbacks 里登记 "langfuse_reasoning.reasoning_logger"，
本文件放在 config.yaml 同一目录。
依赖 LiteLLM 内部函数 LangfuseOtelLogger._set_observation_output（在 v1.96.2 上验证），升级 LiteLLM 后请重新验证。
"""
import json
import os

from litellm._logging import verbose_logger
from litellm.integrations.custom_logger import CustomLogger
from litellm.integrations.langfuse.langfuse_otel import LangfuseOtelLogger
from litellm.litellm_core_utils.safe_json_dumps import safe_dumps
from litellm.types.integrations.langfuse_otel import LangfuseSpanAttributes

OUTPUT_ATTRIBUTE = LangfuseSpanAttributes.OBSERVATION_OUTPUT.value


def _enabled():
    return os.getenv("LANGFUSE_LOG_REASONING", "true").strip().lower() not in ("false", "0", "no", "off")


def _get(obj, key):
    if obj is None:
        return None
    if isinstance(obj, dict):
        return obj.get(key)
    return getattr(obj, key, None)


def _first_message(response_obj):
    choices = _get(response_obj, "choices") or []
    return _get(choices[0], "message") if choices else None


def _extract_reasoning(message):
    """DeepSeek 等 OpenAI 兼容服务商放在 reasoning_content；Anthropic 放在 thinking_blocks。"""
    text = _get(message, "reasoning_content")
    if text:
        return text
    blocks = _get(message, "thinking_blocks") or []
    return "\n\n".join(t for t in (_get(b, "thinking") for b in blocks) if t) or None


def _set_observation_output_with_reasoning(span, response_obj):
    _original_set_observation_output(span=span, response_obj=response_obj)
    if not _enabled():
        return
    try:
        message = _first_message(response_obj)
        reasoning = _extract_reasoning(message)
        if not reasoning:
            return
        current = (getattr(span, "attributes", None) or {}).get(OUTPUT_ATTRIBUTE)
        # 开了日志脱敏时，原函数写的是脱敏后的内容，思维链也不再补
        if current and "redacted-by-litellm" in current:
            return
        output = json.loads(current) if current else None
        thinking = [{"type": "thinking", "content": reasoning}]
        if isinstance(output, dict):
            output["thinking"] = thinking
        else:
            # 原输出是工具调用列表（或为空）时，改写成带 tool_calls 的 ChatML 消息，界面会同时显示思维链和工具调用
            output = {"role": "assistant", "content": _get(message, "content") or "", "thinking": thinking}
            tool_calls = _get(message, "tool_calls")
            if tool_calls:
                output["tool_calls"] = [tc.model_dump() if hasattr(tc, "model_dump") else tc for tc in tool_calls]
        span.set_attribute(OUTPUT_ATTRIBUTE, safe_dumps(output))
    except Exception as e:  # 补思维链失败不能影响原有日志
        verbose_logger.warning("langfuse_reasoning: 补充思维链失败，已保留原输出: %s", e)


# 只打一次补丁（模块被重复加载时不重复包装）
if not getattr(LangfuseOtelLogger, "_reasoning_patched", False):
    _original_set_observation_output = LangfuseOtelLogger._set_observation_output
    LangfuseOtelLogger._set_observation_output = staticmethod(_set_observation_output_with_reasoning)
    LangfuseOtelLogger._reasoning_patched = True
    if _enabled():
        print("langfuse_reasoning: 已开启，思维链会写入 Langfuse 的输出（LANGFUSE_LOG_REASONING=true）", flush=True)
    else:
        print("langfuse_reasoning: 已关闭，Langfuse 输出与原生一致（LANGFUSE_LOG_REASONING=false）", flush=True)

# LiteLLM 按 "模块.对象" 加载自定义回调，需要一个 CustomLogger 实例；它本身什么也不做
reasoning_logger = CustomLogger()
