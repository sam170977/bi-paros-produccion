-- =====================================================================
-- Producción ideal y marca de atípicos en dw.fact_produccion_turno
--   pacas_ideales = (horas trabajadas - horas de paro) x tasa ideal de su máquina y referencia
--   es_atipico    = el registro produce más de 3 veces su producción ideal
-- Se conservan en el modelo (la conciliación con el Excel lo exige); Power BI y Grafana
-- excluyen los atípicos del cálculo de Rendimiento.
-- Requisito: la vista dw.vw_tasa_ideal (consulta Q8 de 04_consultas_analiticas.sql).
-- Reproducible: se puede ejecutar varias veces.
-- =====================================================================
ALTER TABLE dw.fact_produccion_turno
    ADD COLUMN IF NOT EXISTS pacas_ideales NUMERIC(12,2),
    ADD COLUMN IF NOT EXISTS es_atipico    BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE dw.fact_produccion_turno SET pacas_ideales = NULL, es_atipico = FALSE;

UPDATE dw.fact_produccion_turno f
SET pacas_ideales = round(((f.horas_trabajadas - f.min_paro_total / 60.0) * t.pph_ideal)::numeric, 2)
FROM dw.vw_tasa_ideal t
WHERE t.maquina_key    = f.maquina_key
  AND t.referencia_key = f.referencia_key
  AND f.horas_trabajadas * 60 > f.min_paro_total;

UPDATE dw.fact_produccion_turno
SET es_atipico = TRUE
WHERE pacas_ideales > 0 AND pacas_producidas > 3 * pacas_ideales;

-- Validación: deben salir cerca de 10 registros y 53.535 pacas
SELECT count(*) AS registros_atipicos, round(sum(pacas_producidas), 0) AS pacas
FROM dw.fact_produccion_turno
WHERE es_atipico;

SELECT count(*) AS registros_con_ideal FROM dw.fact_produccion_turno WHERE pacas_ideales IS NOT NULL;
