-- Tasa ideal (percentil 90 de pacas por hora de marcha) por máquina y referencia.
-- Proxy del Rendimiento: el Excel no guarda la meta por hora histórica.
CREATE OR REPLACE VIEW dw.vw_tasa_ideal AS
SELECT f.maquina_key, f.referencia_key,
       count(*) AS registros,
       percentile_cont(0.9) WITHIN GROUP (
           ORDER BY f.pacas_producidas / (f.horas_trabajadas - f.min_paro_total / 60.0)
       )::numeric(10,2) AS pph_ideal
FROM dw.fact_produccion_turno f
WHERE f.pacas_producidas > 0
  AND f.horas_trabajadas - f.min_paro_total / 60.0 >= 2      -- al menos 2 h de marcha
GROUP BY f.maquina_key, f.referencia_key
HAVING count(*) >= 10;
