-- 仅在 Postgres 数据卷首次初始化时执行。
-- langfuse 库由 POSTGRES_DB 创建；这里给 LiteLLM 单独建一个库，两边的表互不干扰。
CREATE DATABASE litellm;
