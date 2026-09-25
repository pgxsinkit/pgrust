-- PGO training workload for pgo/pgo-build.sh: small OLTP statements, each sent by psql as its own
-- simple-query message (\gexec), on tables of its own, so the profile covers the per-statement
-- path (parse, analysis, rewrite, planning, executor start/run/end, portal, commit) rather than
-- one benchmark's exact texts. Run against an initdb'd cluster of the instrumented build.
\set ON_ERROR_STOP on
DROP TABLE IF EXISTS pgo_a, pgo_b, pgo_c;
CREATE TABLE pgo_a(id integer, v integer, s varchar(100));
CREATE TABLE pgo_b(id integer, v integer, s varchar(100));
-- autocommit single-row inserts, then a transaction of them
SELECT format('INSERT INTO pgo_a VALUES(%s, %s, %L);', g, (g * 7919) % 100000, 'row ' || g) FROM generate_series(1, 3000) g \gexec
BEGIN;
SELECT format('INSERT INTO pgo_a VALUES(%s, %s, %L);', g, (g * 7919) % 100000, 'row ' || g) FROM generate_series(3001, 20000) g \gexec
COMMIT;
INSERT INTO pgo_b SELECT id, v, s FROM pgo_a;
CREATE INDEX pgo_a_id ON pgo_a(id);
CREATE INDEX pgo_a_v ON pgo_a(v);
CREATE INDEX pgo_b_s ON pgo_b(s);
-- range aggregates through an index, point lookups, scans
BEGIN;
SELECT format('SELECT count(*), avg(v) FROM pgo_a WHERE v >= %s AND v < %s;', g * 50, g * 50 + 50) FROM generate_series(0, 3999) g \gexec
SELECT format('SELECT s FROM pgo_a WHERE id = %s;', g) FROM generate_series(1, 4000) g \gexec
SELECT format('SELECT count(*) FROM pgo_b WHERE s LIKE %L;', '%' || g || '%') FROM generate_series(1, 40) g \gexec
COMMIT;
-- updates by key (integer and text), deletes by key and by range
BEGIN;
SELECT format('UPDATE pgo_a SET v = %s WHERE id = %s;', (g * 31) % 100000, g) FROM generate_series(1, 12000) g \gexec
SELECT format('UPDATE pgo_a SET s = %L WHERE id = %s;', 'updated ' || g, g) FROM generate_series(1, 6000) g \gexec
SELECT format('UPDATE pgo_b SET v = v * 2 WHERE id >= %s AND id < %s;', g * 10, g * 10 + 10) FROM generate_series(0, 499) g \gexec
SELECT format('DELETE FROM pgo_a WHERE id = %s;', g) FROM generate_series(1, 2000) g \gexec
COMMIT;
DELETE FROM pgo_b WHERE v > 100000;
CREATE TABLE pgo_c AS SELECT * FROM pgo_a WHERE v < 50000;
SELECT format('INSERT INTO pgo_c VALUES(%s, %s, %L);', g, g, 'late ' || g) FROM generate_series(1, 3000) g \gexec
DROP TABLE pgo_a, pgo_b, pgo_c;
