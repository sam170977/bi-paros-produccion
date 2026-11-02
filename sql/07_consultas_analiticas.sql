-- =====================================================================
-- CONSULTAS ANALÍTICAS sobre el modelo dimensional (esquema dw)
-- Ejecutar cada una por separado (seleccionar + F5): pgAdmin muestra solo el último resultado.
-- Convención: disponibilidad = 1 - minutos de paro / (horas trabajadas x 60)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q0. Calidad de datos: registros cuyos paros superan el tiempo trabajado
--     (hallazgo para el diagnóstico; explica disponibilidades negativas)
-- ---------------------------------------------------------------------
SELECT d.anio, count(*) AS registros_inconsistentes,
       round(sum(f.min_paro_total - f.horas_trabajadas * 60) / 60.0, 1) AS horas_excedidas
FROM dw.fact_produccion_turno f
JOIN dw.dim_fecha d USING (fecha_key)
WHERE f.min_paro_total > f.horas_trabajadas * 60
GROUP BY d.anio
ORDER BY d.anio;

-- ---------------------------------------------------------------------
-- Q1. ¿Cómo evoluciona la disponibilidad de cada máquina mes a mes?  (agregación)
-- ---------------------------------------------------------------------
SELECT d.anio_mes, m.nombre AS maquina,
       round(sum(f.horas_trabajadas), 1)  AS horas_trabajadas,
       round(sum(f.pacas_producidas), 0)  AS pacas,
       round(100 * (1 - sum(f.min_paro_total) / NULLIF(sum(f.horas_trabajadas) * 60, 0)), 1) AS disponibilidad_pct
FROM dw.fact_produccion_turno f
JOIN dw.dim_fecha   d USING (fecha_key)
JOIN dw.dim_maquina m USING (maquina_key)
GROUP BY d.anio_mes, m.nombre
ORDER BY d.anio_mes, m.nombre;

-- ---------------------------------------------------------------------
-- Q2. Pareto de causas de paro: ¿qué pocas causas explican la mayor parte del tiempo perdido?
--     (funciones de ventana: % y % acumulado)
-- ---------------------------------------------------------------------
WITH causas AS (
    SELECT c.codigo_paro_id, c.codigo_nombre, sum(p.duracion_min) / 60.0 AS horas
    FROM dw.fact_paro p
    JOIN dw.dim_causa_paro c USING (causa_key)
    GROUP BY c.codigo_paro_id, c.codigo_nombre
)
SELECT codigo_paro_id, codigo_nombre,
       round(horas, 1) AS horas_paro,
       round(100 * horas / sum(horas) OVER (), 1) AS pct,
       round(100 * sum(horas) OVER (ORDER BY horas DESC, codigo_paro_id
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                 / sum(horas) OVER (), 1) AS pct_acumulado
FROM causas
ORDER BY horas DESC, codigo_paro_id;

-- ---------------------------------------------------------------------
-- Q3. ¿Cuáles son los 3 meses con más horas de paro de cada máquina?  (RANK por partición)
-- ---------------------------------------------------------------------
SELECT *
FROM (
    SELECT m.nombre AS maquina, d.anio_mes,
           round(sum(p.duracion_min) / 60.0, 1) AS horas_paro,
           rank() OVER (PARTITION BY m.nombre ORDER BY sum(p.duracion_min) DESC) AS puesto
    FROM dw.fact_paro p
    JOIN dw.dim_fecha   d USING (fecha_key)
    JOIN dw.dim_maquina m USING (maquina_key)
    GROUP BY m.nombre, d.anio_mes
) t
WHERE puesto <= 3
ORDER BY maquina, puesto;

-- ---------------------------------------------------------------------
-- Q4. ¿Cómo está cada mes frente al mismo mes del año anterior?  (LAG de 12 meses)
-- ---------------------------------------------------------------------
WITH mensual AS (
    SELECT d.anio, d.mes, d.anio_mes,
           sum(f.pacas_producidas) AS pacas,
           100 * (1 - sum(f.min_paro_total) / NULLIF(sum(f.horas_trabajadas) * 60, 0)) AS disponibilidad
    FROM dw.fact_produccion_turno f
    JOIN dw.dim_fecha d USING (fecha_key)
    GROUP BY d.anio, d.mes, d.anio_mes
)
SELECT anio_mes,
       round(pacas, 0)                                  AS pacas,
       round(lag(pacas, 12) OVER (ORDER BY anio, mes), 0) AS pacas_anio_anterior,
       round(100 * (pacas / NULLIF(lag(pacas, 12) OVER (ORDER BY anio, mes), 0) - 1), 1) AS variacion_pacas_pct,
       round(disponibilidad, 1)                         AS disponibilidad_pct,
       round(disponibilidad - lag(disponibilidad, 12) OVER (ORDER BY anio, mes), 1) AS dif_disponibilidad_pp
FROM mensual
ORDER BY anio, mes;

-- ---------------------------------------------------------------------
-- Q5. Tendencia suavizada: media móvil de 3 meses de la disponibilidad por máquina
-- ---------------------------------------------------------------------
WITH mensual AS (
    SELECT m.nombre AS maquina, d.anio, d.mes, d.anio_mes,
           100 * (1 - sum(f.min_paro_total) / NULLIF(sum(f.horas_trabajadas) * 60, 0)) AS disponibilidad
    FROM dw.fact_produccion_turno f
    JOIN dw.dim_fecha   d USING (fecha_key)
    JOIN dw.dim_maquina m USING (maquina_key)
    GROUP BY m.nombre, d.anio, d.mes, d.anio_mes
)
SELECT maquina, anio_mes,
       round(disponibilidad, 1) AS disponibilidad_pct,
       round(avg(disponibilidad) OVER (PARTITION BY maquina ORDER BY anio, mes
                                       ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 1) AS media_movil_3m
FROM mensual
ORDER BY maquina, anio, mes;

-- ---------------------------------------------------------------------
-- Q6. ¿Qué turno rinde más? (solo turnos conocidos; 2022-2023 no traen turno)
-- ---------------------------------------------------------------------
SELECT t.descripcion AS turno,
       count(*) AS registros,
       round(sum(f.pacas_producidas) / NULLIF(sum(f.horas_trabajadas), 0), 1) AS pacas_por_hora,
       round(100 * (1 - sum(f.min_paro_total) / NULLIF(sum(f.horas_trabajadas) * 60, 0)), 1) AS disponibilidad_pct
FROM dw.fact_produccion_turno f
JOIN dw.dim_turno t USING (turno_key)
WHERE t.turno_conocido
GROUP BY t.descripcion
ORDER BY pacas_por_hora DESC;

-- ---------------------------------------------------------------------
-- Q7. Drill-down de la jerarquía: Área -> Código -> Subcódigo (top 15 en horas)
-- ---------------------------------------------------------------------
SELECT c.area_impacto, c.codigo_paro_id, c.codigo_nombre,
       c.subcodigo_clave, c.subcodigo_descripcion,
       round(sum(p.duracion_min) / 60.0, 1) AS horas_paro,
       round(100 * sum(p.duracion_min) / sum(sum(p.duracion_min)) OVER (), 1) AS pct_total
FROM dw.fact_paro p
JOIN dw.dim_causa_paro c USING (causa_key)
GROUP BY c.area_impacto, c.codigo_paro_id, c.codigo_nombre, c.subcodigo_clave, c.subcodigo_descripcion
ORDER BY sum(p.duracion_min) DESC
LIMIT 15;

-- ---------------------------------------------------------------------
-- Q8. Tasa ideal de producción (proxy del Rendimiento del OEE)
--     El Excel no guarda la meta por hora histórica; se estima como el percentil 90
--     de pacas por hora de marcha, por máquina y referencia (mínimo 10 registros).
-- ---------------------------------------------------------------------
-- (la vista dw.vw_tasa_ideal se crea en 05_vista_tasa_ideal.sql)

SELECT m.nombre AS maquina, r.nombre AS referencia, t.registros, t.pph_ideal
FROM dw.vw_tasa_ideal t
JOIN dw.dim_maquina    m USING (maquina_key)
JOIN dw.dim_referencia r USING (referencia_key)
ORDER BY m.nombre, t.registros DESC
LIMIT 20;

-- ---------------------------------------------------------------------
-- Q9. OEE parcial por máquina y año: Disponibilidad x Rendimiento
--     (Calidad queda pendiente: el Excel no registra unidades no conformes)
-- ---------------------------------------------------------------------
WITH base AS (
    SELECT d.anio, m.nombre AS maquina,
           sum(f.horas_trabajadas * 60)                                   AS min_programados,
           sum(f.min_paro_total)                                          AS min_paro,
           sum(f.pacas_producidas)                                        AS pacas,
           sum((f.horas_trabajadas - f.min_paro_total / 60.0) * t.pph_ideal) AS pacas_ideales
    FROM dw.fact_produccion_turno f
    JOIN dw.vw_tasa_ideal t USING (maquina_key, referencia_key)
    JOIN dw.dim_fecha     d USING (fecha_key)
    JOIN dw.dim_maquina   m USING (maquina_key)
    WHERE f.horas_trabajadas * 60 > f.min_paro_total
    GROUP BY d.anio, m.nombre
)
SELECT anio, maquina,
       round(100 * (1 - min_paro / NULLIF(min_programados, 0)), 1)  AS disponibilidad_pct,
       round(100 * pacas / NULLIF(pacas_ideales, 0), 1)             AS rendimiento_pct,
       round((1 - min_paro / NULLIF(min_programados, 0)) * (pacas / NULLIF(pacas_ideales, 0)) * 100, 1)
                                                                    AS oee_sin_calidad_pct
FROM base
ORDER BY anio, maquina;
