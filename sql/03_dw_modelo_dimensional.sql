-- =====================================================================
-- MODELO DIMENSIONAL (estrella) - Paros de producción / OEE
-- Esquema dw. Se alimenta con SQL desde el esquema de origen `produccion`.
-- Reproducible: se puede ejecutar completo varias veces (recrea dw).
-- =====================================================================
DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA dw;

-- ---------------------------------------------------------------------
-- DIMENSIONES (llave sustituta *_key; llave natural *_nk = id en `produccion`)
-- ---------------------------------------------------------------------
-- dim_fecha: construida por nosotros (no viene del Excel). Llave inteligente yyyymmdd.
CREATE TABLE dw.dim_fecha (
    fecha_key     INT PRIMARY KEY,                -- 20250328
    fecha         DATE NOT NULL UNIQUE,
    anio          SMALLINT NOT NULL,
    trimestre     SMALLINT NOT NULL,
    mes           SMALLINT NOT NULL,
    nombre_mes    VARCHAR(12) NOT NULL,
    anio_mes      CHAR(7) NOT NULL,               -- '2025-03' (ordena bien en Power BI)
    semana_iso    SMALLINT NOT NULL,
    dia_mes       SMALLINT NOT NULL,
    dia_semana    SMALLINT NOT NULL,              -- 1 = lunes ... 7 = domingo
    nombre_dia    VARCHAR(12) NOT NULL,
    es_fin_semana BOOLEAN NOT NULL
);

CREATE TABLE dw.dim_maquina (
    maquina_key  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    maquina_nk   SMALLINT NOT NULL UNIQUE,
    nombre       VARCHAR(30) NOT NULL,
    linea        VARCHAR(30) NOT NULL
);

CREATE TABLE dw.dim_turno (
    turno_key         SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    turno_nk          SMALLINT NOT NULL UNIQUE,
    descripcion       VARCHAR(30) NOT NULL,
    hora_inicio       TIME NOT NULL,
    hora_fin          TIME NOT NULL,
    minutos_turno     INT  NOT NULL,
    turno_conocido    BOOLEAN NOT NULL            -- FALSE = 'Sin especificar' (2022-2023)
);

CREATE TABLE dw.dim_referencia (
    referencia_key  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    referencia_nk   INT NOT NULL UNIQUE,
    nombre          VARCHAR(80) NOT NULL
);

-- Datos personales: el tablero usa operario_codigo (seudónimo); el nombre queda solo en la BD.
CREATE TABLE dw.dim_operario (
    operario_key     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operario_nk      INT NOT NULL UNIQUE,
    operario_codigo  VARCHAR(10) NOT NULL UNIQUE,   -- 'OP-0001'
    nombre           VARCHAR(80) NOT NULL
);

CREATE TABLE dw.dim_agente (
    agente_key  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre      VARCHAR(40) NOT NULL UNIQUE          -- incluye 'No aplica'
);

-- dim_causa_paro: jerarquía aplanada Área -> Código -> Subcódigo (drill-down en Power BI).
-- Cada código tiene un miembro 'Sin subcódigo' (clave '0') para que ninguna FK sea nula.
-- Lista para SCD Tipo 2 (vigente_desde / vigente_hasta / es_vigente).
CREATE TABLE dw.dim_causa_paro (
    causa_key             INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo_paro_id        SMALLINT NOT NULL,
    codigo_nombre         VARCHAR(100) NOT NULL,
    area_impacto          VARCHAR(30)  NOT NULL,
    es_planificado        BOOLEAN NOT NULL,
    afecta_oee            BOOLEAN NOT NULL,
    subcodigo_clave       VARCHAR(10)  NOT NULL,
    subcodigo_descripcion VARCHAR(120) NOT NULL,
    vigente_desde         DATE NOT NULL DEFAULT DATE '2022-01-01',
    vigente_hasta         DATE NOT NULL DEFAULT DATE '9999-12-31',
    es_vigente            BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE (codigo_paro_id, subcodigo_clave, vigente_desde)
);

-- ---------------------------------------------------------------------
-- HECHOS
-- ---------------------------------------------------------------------
-- Grano: una fila por máquina, fecha, turno, operario y referencia (un registro "hora a hora").
CREATE TABLE dw.fact_produccion_turno (
    registro_id        BIGINT PRIMARY KEY,                    -- dimensión degenerada
    fecha_key          INT      NOT NULL REFERENCES dw.dim_fecha,
    maquina_key        SMALLINT NOT NULL REFERENCES dw.dim_maquina,
    turno_key          SMALLINT NOT NULL REFERENCES dw.dim_turno,
    operario_key       INT      NOT NULL REFERENCES dw.dim_operario,
    referencia_key     INT      NOT NULL REFERENCES dw.dim_referencia,
    horas_trabajadas   NUMERIC(5,2)  NOT NULL CHECK (horas_trabajadas >= 0),
    pacas_producidas   NUMERIC(10,2) NOT NULL CHECK (pacas_producidas >= 0),
    min_paro_total     NUMERIC(8,1)  NOT NULL DEFAULT 0 CHECK (min_paro_total >= 0),
    min_paro_oee       NUMERIC(8,1)  NOT NULL DEFAULT 0 CHECK (min_paro_oee >= 0),
    min_paro_planificado NUMERIC(8,1) NOT NULL DEFAULT 0 CHECK (min_paro_planificado >= 0),
    cantidad_paros     INT NOT NULL DEFAULT 0
);

-- Grano: una fila por paro (registro x causa x subcódigo x agente).
CREATE TABLE dw.fact_paro (
    paro_id         BIGINT PRIMARY KEY,
    registro_id     BIGINT   NOT NULL REFERENCES dw.fact_produccion_turno,
    fecha_key       INT      NOT NULL REFERENCES dw.dim_fecha,
    maquina_key     SMALLINT NOT NULL REFERENCES dw.dim_maquina,
    turno_key       SMALLINT NOT NULL REFERENCES dw.dim_turno,
    operario_key    INT      NOT NULL REFERENCES dw.dim_operario,
    referencia_key  INT      NOT NULL REFERENCES dw.dim_referencia,
    causa_key       INT      NOT NULL REFERENCES dw.dim_causa_paro,
    agente_key      SMALLINT NOT NULL REFERENCES dw.dim_agente,
    duracion_min    NUMERIC(6,1) NOT NULL CHECK (duracion_min > 0)
);

-- Grano: una fila por máquina y hora. La llena el simulador (Grafana); vacía por ahora.
CREATE TABLE dw.fact_produccion_hora (
    fecha_hora       TIMESTAMP NOT NULL,
    maquina_key      SMALLINT  NOT NULL REFERENCES dw.dim_maquina,
    fecha_key        INT       NOT NULL REFERENCES dw.dim_fecha,
    turno_key        SMALLINT  NOT NULL REFERENCES dw.dim_turno,
    referencia_key   INT       NOT NULL REFERENCES dw.dim_referencia,
    causa_key        INT       NOT NULL REFERENCES dw.dim_causa_paro,   -- código 19 'No aplica' = sin paro
    pacas_producidas NUMERIC(8,2) NOT NULL CHECK (pacas_producidas >= 0),
    meta_pacas_hora  NUMERIC(8,2),
    min_paro         NUMERIC(4,1) NOT NULL DEFAULT 0 CHECK (min_paro BETWEEN 0 AND 60),
    PRIMARY KEY (maquina_key, fecha_hora)
);

-- ---------------------------------------------------------------------
-- ÍNDICES (las consultas filtran por fecha, máquina y causa, y agrupan por ellas)
-- ---------------------------------------------------------------------
CREATE INDEX ix_fpt_fecha_maq  ON dw.fact_produccion_turno (fecha_key, maquina_key);
CREATE INDEX ix_fpt_ref        ON dw.fact_produccion_turno (referencia_key);
CREATE INDEX ix_fp_fecha_maq   ON dw.fact_paro (fecha_key, maquina_key);
CREATE INDEX ix_fp_causa       ON dw.fact_paro (causa_key);          -- Pareto por causa
CREATE INDEX ix_fp_registro    ON dw.fact_paro (registro_id);
CREATE INDEX ix_fph_hora       ON dw.fact_produccion_hora (fecha_hora DESC);  -- rango de tiempo en Grafana
