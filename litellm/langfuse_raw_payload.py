"""把 LiteLLM 收到的原始请求和返回的原始响应，原样（不截断）附加到 Langfuse 的记录上。

LiteLLM 原生的 langfuse_otel 只把请求和响应拆成 input / output / 若干元数据发给 Langfuse，
LiteLLM 内部的大部分字段（user_api_key_auth、hidden_params 等）和响应里的 finish_reason 等都不会保存。
本模块在原函数写完 Langfuse 属性之后，再补两个元数据字段：

    litellm.raw_request   与 LiteLLM 日志页 Request 页签相同的请求 JSON（LiteLLM 加工后的请求体，含 metadata）
    litellm.raw_response  与 LiteLLM 日志页 Response 页签相同的响应 JSON（流式请求为拼好的完整响应）

两者在 Langfuse 里显示为 Attributes 页签 Metadata 下的 attributes.litellm.raw_request / raw_response。
与 LiteLLM 自己的日志不同，这里不截断；也不受 store_prompts_in_spend_logs 开关影响。
失败的请求只有 raw_request。

注意：原始请求里有完整的请求头（包括浏览器 cookie）和 key 的鉴权信息，能登录 Langfuse 的人都能看到。

开关：环境变量 LANGFUSE_LOG_RAW_PAYLOAD（写在 .env 里），true 开启，false 关闭（默认）。
开了 LiteLLM 的消息脱敏（turn_off_message_logging 等）时不写入，避免绕过脱敏设置。
改了开关后要重建 litellm 容器才生效。

加载方式：config.yaml 的 litellm_settings.callbacks 里登记 "langfuse_raw_payload.raw_payload_logger"，
本文件放在 config.yaml 同一目录。
依赖 LiteLLM 内部函数 LangfuseOtelLogger._set_langfuse_specific_attributes（在 v1.96.2 上验证），升级 LiteLLM 后请重新验证。
"""
import os

import litellm
from litellm._logging import verbose_logger
from litellm.integrations.custom_logger import CustomLogger
from litellm.integrations.langfuse.langfuse_otel import LangfuseOtelLogger
from litellm.litellm_core_utils.redact_messages import should_redact_message_logging
from litellm.litellm_core_utils.safe_json_dumps import safe_dumps

RAW_REQUEST_ATTRIBUTE = "litellm.raw_request"
RAW_RESPONSE_ATTRIBUTE = "litellm.raw_response"


def _enabled():
    return os.getenv("LANGFUSE_LOG_RAW_PAYLOAD", "false").strip().lower() in ("true", "1", "yes", "on")


def _redaction_on(kwargs):
    if litellm.turn_off_message_logging:
        return True
    litellm_params = kwargs.get("litellm_params", {}) or {}
    return should_redact_message_logging(model_call_details={
        "litellm_params": litellm_params,
        "standard_callback_dynamic_params": kwargs.get("standard_callback_dynamic_params"),
    })


def _raw_response(kwargs, response_obj):
    # 与 LiteLLM 日志表的 response 列同源：标准日志结构里的 response（流式时是拼好的完整响应）
    payload = kwargs.get("standard_logging_object") or {}
    response = payload.get("response")
    if response is None and response_obj is not None:
        response = response_obj.model_dump() if hasattr(response_obj, "model_dump") else response_obj
    return response


def _set_langfuse_specific_attributes_with_raw_payload(span, kwargs, response_obj):
    _original_set_langfuse_specific_attributes(span=span, kwargs=kwargs, response_obj=response_obj)
    if not _enabled():
        return
    try:
        if _redaction_on(kwargs):
            return
        # 与 LiteLLM 日志表的 proxy_server_request 列同源：LiteLLM 加工后的请求体
        proxy_request = (kwargs.get("litellm_params", {}) or {}).get("proxy_server_request") or {}
        request_body = proxy_request.get("body")
        if request_body:
            span.set_attribute(RAW_REQUEST_ATTRIBUTE, safe_dumps(request_body))
        response = _raw_response(kwargs, response_obj)
        if response:
            span.set_attribute(RAW_RESPONSE_ATTRIBUTE, safe_dumps(response))
    except Exception as e:  # 附加原始报文失败不能影响原有日志
        verbose_logger.warning("langfuse_raw_payload: 附加原始请求/响应失败，已保留原有日志: %s", e)


# 只打一次补丁（模块被重复加载时不重复包装）
if not getattr(LangfuseOtelLogger, "_raw_payload_patched", False):
    _original_set_langfuse_specific_attributes = LangfuseOtelLogger._set_langfuse_specific_attributes
    LangfuseOtelLogger._set_langfuse_specific_attributes = staticmethod(_set_langfuse_specific_attributes_with_raw_payload)
    LangfuseOtelLogger._raw_payload_patched = True
    if _enabled():
        print("langfuse_raw_payload: 已开启，原始请求和响应会附加到 Langfuse（LANGFUSE_LOG_RAW_PAYLOAD=true）", flush=True)
    else:
        print("langfuse_raw_payload: 已关闭（LANGFUSE_LOG_RAW_PAYLOAD=false）", flush=True)

# LiteLLM 按 "模块.对象" 加载自定义回调，需要一个 CustomLogger 实例；它本身什么也不做
raw_payload_logger = CustomLogger()
