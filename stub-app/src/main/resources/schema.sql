-- 스텁 앱 전용 테이블. 실제 스키마(역할 1)와 무관.
CREATE TABLE IF NOT EXISTS stub_ping (
    id         BIGSERIAL PRIMARY KEY,
    note       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
