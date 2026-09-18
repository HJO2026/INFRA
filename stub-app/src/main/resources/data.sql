INSERT INTO stub_ping (id, note) VALUES (1, 'stub') ON CONFLICT (id) DO NOTHING;
SELECT setval('stub_ping_id_seq', GREATEST((SELECT max(id) FROM stub_ping), 1));
