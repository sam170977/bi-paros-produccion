-- =====================================================================
-- CARGA del modelo dimensional desde el esquema `produccion` (ELT en SQL)
-- Ejecutar después de 02_dw_modelo_dimensional.sql
-- =====================================================================

-- ---- dim_fecha (generada) --------------------------------------------
INSERT INTO dw.dim_fecha
SELECT to_char(d, 'YYYYMMDD')::int, d::date,
       extract(year    FROM d)::smallint,
       extract(quarter FROM d)::smallint,
       extract(month   FROM d)::smallint,
       (ARRAY['enero','febrero','marzo','abril','mayo','junio','julio','agosto',
              'septiembre','octubre','noviembre','diciembre'])[extract(month FROM d)::int],
       to_char(d, 'YYYY-MM'),
       extract(week   FROM d)::smallint,
       extract(day    FROM d)::smallint,
       extract(isodow FROM d)::smallint,
       (ARRAY['lunes','martes','miércoles','jueves','viernes','sábado','domingo'])[extract(isodow FROM d)::int],
       extract(isodow FROM d) >= 6
FROM generate_series(DATE '2022-01-01', DATE '2026-12-31', INTERVAL '1 day') AS g(d);

-- ---- dimensiones simples ---------------------------------------------
INSERT INTO dw.dim_maquina (maquina_nk, nombre, linea)
SELECT maquina_id, nombre, 'Vinilos' FROM produccion.maquinas ORDER BY maquina_id;

INSERT INTO dw.dim_turno (turno_nk, descripcion, hora_inicio, hora_fin, minutos_turno, turno_conocido)
SELECT turno_id, descripcion, hora_inicio, hora_fin, minutos_turno, descripcion <> 'Sin especificar'
FROM produccion.turnos ORDER BY turno_id;

INSERT INTO dw.dim_referencia (referencia_nk, nombre)
SELECT referencia_id, nombre FROM produccion.referencias ORDER BY referencia_id;

INSERT INTO dw.dim_operario (operario_nk, operario_codigo, nombre)
SELECT operario_id, 'OP-' || lpad(operario_id::text, 4, '0'), nombre
FROM produccion.operarios ORDER BY operario_id;

INSERT INTO dw.dim_agente (nombre)
SELECT nombre FROM produccion.agentes ORDER BY agente_id;
INSERT INTO dw.dim_agente (nombre) VALUES ('No aplica');

-- ---- dim_causa_paro: miembro 'Sin subcódigo' por código + cada subcódigo ----
INSERT INTO dw.dim_causa_paro
    (codigo_paro_id, codigo_nombre, area_impacto, es_planificado, afecta_oee, subcodigo_clave, subcodigo_descripcion)
SELECT c.codigo_paro_id, c.nombre, c.area_impacto, c.es_planificado, c.afecta_oee, '0', 'Sin subcódigo'
FROM produccion.codigos_paro c
UNION ALL
SELECT c.codigo_paro_id, c.nombre, c.area_impacto, c.es_planificado, c.afecta_oee, s.clave, s.descripcion
FROM produccion.subcodigos_paro s
JOIN produccion.codigos_paro c USING (codigo_paro_id);

-- ---- fact_produccion_turno -------------------------------------------
INSERT INTO dw.fact_produccion_turno
    (registro_id, fecha_key, maquina_key, turno_key, operario_key, referencia_key,
     horas_trabajadas, pacas_producidas, min_paro_total, min_paro_oee, min_paro_planificado, cantidad_paros)
SELECT r.registro_id,
       to_char(r.fecha, 'YYYYMMDD')::int,
       dm.maquina_key, dt.turno_key, dop.operario_key, dr.referencia_key,
       r.horas_trabajadas, r.pacas_producidas,
       COALESCE(p.min_total, 0), COALESCE(p.min_oee, 0), COALESCE(p.min_plan, 0), COALESCE(p.n, 0)
FROM produccion.registros_produccion r
JOIN dw.dim_maquina    dm  ON dm.maquina_nk     = r.maquina_id
JOIN dw.dim_turno      dt  ON dt.turno_nk       = r.turno_id
JOIN dw.dim_operario   dop ON dop.operario_nk   = r.operario_id
JOIN dw.dim_referencia dr  ON dr.referencia_nk  = r.referencia_id
LEFT JOIN (
    SELECT d.registro_id,
           sum(d.duracion_min)                                         AS min_total,
           sum(d.duracion_min) FILTER (WHERE c.afecta_oee)             AS min_oee,
           sum(d.duracion_min) FILTER (WHERE c.es_planificado)         AS min_plan,
           count(*)                                                    AS n
    FROM produccion.detalle_paros_produccion d
    JOIN produccion.codigos_paro c USING (codigo_paro_id)
    GROUP BY d.registro_id
) p ON p.registro_id = r.registro_id;

-- ---- fact_paro ---------------------------------------------------------
INSERT INTO dw.fact_paro
    (paro_id, registro_id, fecha_key, maquina_key, turno_key, operario_key, referencia_key,
     causa_key, agente_key, duracion_min)
SELECT d.detalle_id, f.registro_id, f.fecha_key, f.maquina_key, f.turno_key, f.operario_key, f.referencia_key,
       dc.causa_key, da.agente_key, d.duracion_min
FROM produccion.detalle_paros_produccion d
JOIN dw.fact_produccion_turno f ON f.registro_id = d.registro_id
LEFT JOIN produccion.subcodigos_paro s ON s.subcodigo_id = d.subcodigo_id
JOIN dw.dim_causa_paro dc
     ON dc.codigo_paro_id = d.codigo_paro_id
    AND dc.subcodigo_clave = COALESCE(s.clave, '0')
    AND dc.es_vigente
LEFT JOIN produccion.agentes a ON a.agente_id = d.agente_id
JOIN dw.dim_agente da ON da.nombre = COALESCE(a.nombre, 'No aplica');

-- =====================================================================
-- VALIDACIÓN: debe coincidir con la conciliación del ETL
--   registros 4941 | paros 14610 | horas paro 8386.1 | horas trabajadas 37666.9 | pacas 375897
-- =====================================================================
SELECT 'fact_produccion_turno' AS tabla, count(*) AS filas FROM dw.fact_produccion_turno
UNION ALL SELECT 'fact_paro', count(*) FROM dw.fact_paro
UNION ALL SELECT 'dim_fecha', count(*) FROM dw.dim_fecha
UNION ALL SELECT 'dim_maquina', count(*) FROM dw.dim_maquina
UNION ALL SELECT 'dim_turno', count(*) FROM dw.dim_turno
UNION ALL SELECT 'dim_operario', count(*) FROM dw.dim_operario
UNION ALL SELECT 'dim_referencia', count(*) FROM dw.dim_referencia
UNION ALL SELECT 'dim_causa_paro', count(*) FROM dw.dim_causa_paro
UNION ALL SELECT 'dim_agente', count(*) FROM dw.dim_agente;

SELECT round(sum(horas_trabajadas), 1) AS horas_trabajadas,
       round(sum(pacas_producidas), 0) AS pacas
FROM dw.fact_produccion_turno;

SELECT round(sum(duracion_min) / 60.0, 1) AS horas_paro FROM dw.fact_paro;
