-- =====================================================================
-- PARTE 1 · Modelo relacional – Registro de paros de producción (P-MTO-22)
-- Motor: PostgreSQL 14+
-- Origen: SEGUIMIENTO_TEMPERAS_Y_VINILOS (hoja "Base De Datos", 58 columnas,
--         18 columnas "Código de paro N" en formato ancho -> se normaliza a
--         formato largo en DetalleParosProduccion)
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS produccion;
SET search_path = produccion, public;

-- ---------- 1. DIMENSIONES / MAESTROS ---------------------------------
CREATE TABLE maquinas (
    maquina_id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre       VARCHAR(30) NOT NULL UNIQUE,          -- Vinilos_1..4
    tipo_linea   VARCHAR(30) NOT NULL DEFAULT 'Vinilos',
    activa       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE turnos (
    turno_id         SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    descripcion      VARCHAR(30) NOT NULL UNIQUE,      -- '6am-4:30pm', '6am-2pm (Turno 1)', ...
    hora_inicio      TIME NOT NULL,
    hora_fin         TIME NOT NULL,
    minutos_turno    INT  NOT NULL CHECK (minutos_turno > 0)
);

CREATE TABLE operarios (
    operario_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre       VARCHAR(80) NOT NULL UNIQUE,
    activo       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE referencias (
    referencia_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre               VARCHAR(80) NOT NULL UNIQUE,  -- 'Alocolor 22cc (12 col)'
    unidades_por_minuto  NUMERIC(8,2),
    unidades_por_display SMALLINT,
    display_por_paca     SMALLINT
);

CREATE TABLE codigos_paro (
    codigo_paro_id  SMALLINT PRIMARY KEY,              -- 1..19 (coincide con el código del formato)
    nombre          VARCHAR(100) NOT NULL UNIQUE,
    area_impacto    VARCHAR(30)  NOT NULL,             -- Mantenimiento / Producción / ...
    es_planificado  BOOLEAN NOT NULL DEFAULT FALSE,    -- p.ej. 04 preventivo, 08 reunión, 17 pausa activa
    afecta_oee      BOOLEAN NOT NULL DEFAULT TRUE      -- 19 = 'No aplica'
);

CREATE TABLE subcodigos_paro (
    subcodigo_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo_paro_id  SMALLINT NOT NULL REFERENCES codigos_paro(codigo_paro_id),
    clave           VARCHAR(10) NOT NULL,              -- '1.2.B', '5.8', '3.2'
    descripcion     VARCHAR(120) NOT NULL,
    UNIQUE (codigo_paro_id, clave)
);

CREATE TABLE agentes (                                  -- quién atendió el paro (subcódigo 5)
    agente_id  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre     VARCHAR(40) NOT NULL UNIQUE              -- Operarios / Personal_de_mantenimiento
);

-- ---------- 2. TABLA DE HECHOS (1 fila = 1 máquina-turno-día-referencia)
CREATE TABLE registros_produccion (
    registro_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha                DATE     NOT NULL,
    maquina_id           SMALLINT NOT NULL REFERENCES maquinas(maquina_id),
    turno_id             SMALLINT NOT NULL REFERENCES turnos(turno_id),
    operario_id          INT      NOT NULL REFERENCES operarios(operario_id),
    referencia_id        INT      NOT NULL REFERENCES referencias(referencia_id),
    horas_trabajadas     NUMERIC(5,2) NOT NULL CHECK (horas_trabajadas >= 0),
    meta_por_hora        NUMERIC(8,2) CHECK (meta_por_hora >= 0),
    pacas_producidas     NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (pacas_producidas >= 0),
    pacas_no_conformes   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (pacas_no_conformes >= 0),  -- insumo de Calidad (ver notas)
    observacion          TEXT,
    fuente               VARCHAR(20) NOT NULL DEFAULT 'excel',
    creado_en            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_registro UNIQUE (fecha, maquina_id, turno_id, operario_id, referencia_id),
    CONSTRAINT ck_no_conformes CHECK (pacas_no_conformes <= pacas_producidas)
);

-- ---------- 3. DETALLE (1 fila = 1 paro dentro de un registro) ---------
CREATE TABLE detalle_paros_produccion (
    detalle_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registro_id        BIGINT   NOT NULL REFERENCES registros_produccion(registro_id) ON DELETE CASCADE,
    codigo_paro_id     SMALLINT NOT NULL REFERENCES codigos_paro(codigo_paro_id),
    subcodigo_id       INT      REFERENCES subcodigos_paro(subcodigo_id),
    duracion_min       NUMERIC(6,1) NOT NULL CHECK (duracion_min > 0),
    agente_id          SMALLINT REFERENCES agentes(agente_id),
    personal_involucrado VARCHAR(80),
    observacion        TEXT
);

-- ---------- 4. ÍNDICES --------------------------------------------------
CREATE INDEX ix_reg_fecha        ON registros_produccion (fecha);
CREATE INDEX ix_reg_maq_fecha    ON registros_produccion (maquina_id, fecha);
CREATE INDEX ix_det_registro     ON detalle_paros_produccion (registro_id);
CREATE INDEX ix_det_codigo       ON detalle_paros_produccion (codigo_paro_id, subcodigo_id);

-- ---------- 5. REGLAS DE NEGOCIO (triggers) ----------------------------
-- 5.1 Subcódigo debe pertenecer al código de paro indicado
CREATE OR REPLACE FUNCTION fn_valida_subcodigo() RETURNS trigger AS $$
BEGIN
    IF NEW.subcodigo_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM subcodigos_paro s
        WHERE s.subcodigo_id = NEW.subcodigo_id
          AND s.codigo_paro_id = NEW.codigo_paro_id) THEN
        RAISE EXCEPTION 'El subcódigo % no pertenece al código de paro %',
                        NEW.subcodigo_id, NEW.codigo_paro_id;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_valida_subcodigo
BEFORE INSERT OR UPDATE ON detalle_paros_produccion
FOR EACH ROW EXECUTE FUNCTION fn_valida_subcodigo();

-- 5.2 La suma de paros no puede exceder los minutos del turno
--     (equivale al "Tiempo faltante" del formulario de Excel)
CREATE OR REPLACE FUNCTION fn_valida_duracion_turno() RETURNS trigger AS $$
DECLARE
    v_paros  NUMERIC;
    v_turno  INT;
BEGIN
    SELECT COALESCE(SUM(d.duracion_min),0)
      INTO v_paros
      FROM detalle_paros_produccion d
     WHERE d.registro_id = NEW.registro_id
       AND d.detalle_id IS DISTINCT FROM NEW.detalle_id;
    v_paros := v_paros + NEW.duracion_min;

    SELECT t.minutos_turno INTO v_turno
      FROM registros_produccion r JOIN turnos t USING (turno_id)
     WHERE r.registro_id = NEW.registro_id;

    IF v_paros > v_turno THEN
        RAISE EXCEPTION 'Paros acumulados (% min) exceden el turno (% min) del registro %',
                        v_paros, v_turno, NEW.registro_id;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_valida_duracion
BEFORE INSERT OR UPDATE ON detalle_paros_produccion
FOR EACH ROW EXECUTE FUNCTION fn_valida_duracion_turno();

-- 5.3 Auditoría de cambios
CREATE TABLE auditoria_cambios (
    auditoria_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tabla        TEXT NOT NULL,
    operacion    CHAR(1) NOT NULL,
    pk_valor     TEXT,
    datos_antes  JSONB,
    datos_despues JSONB,
    usuario_db   TEXT NOT NULL DEFAULT current_user,
    cambiado_en  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION fn_auditoria() RETURNS trigger AS $$
BEGIN
    INSERT INTO auditoria_cambios (tabla, operacion, pk_valor, datos_antes, datos_despues)
    VALUES (TG_TABLE_NAME, left(TG_OP,1),
            COALESCE((to_jsonb(NEW)->>TG_ARGV[0]), (to_jsonb(OLD)->>TG_ARGV[0])),
            CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END);
    RETURN COALESCE(NEW, OLD);
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_aud_registros AFTER INSERT OR UPDATE OR DELETE
ON registros_produccion FOR EACH ROW EXECUTE FUNCTION fn_auditoria('registro_id');
CREATE TRIGGER trg_aud_detalle AFTER INSERT OR UPDATE OR DELETE
ON detalle_paros_produccion FOR EACH ROW EXECUTE FUNCTION fn_auditoria('detalle_id');

-- ---------- 6. VISTA BASE PARA GRAFANA / POWER BI ----------------------
CREATE OR REPLACE VIEW vw_registro_resumen AS
SELECT r.registro_id, r.fecha, m.nombre AS maquina, t.descripcion AS turno,
       o.nombre AS operario, ref.nombre AS referencia,
       r.horas_trabajadas, r.meta_por_hora, r.pacas_producidas, r.pacas_no_conformes,
       t.minutos_turno,
       COALESCE(SUM(d.duracion_min),0)                                   AS min_paro_total,
       COALESCE(SUM(d.duracion_min) FILTER (WHERE c.afecta_oee),0)       AS min_paro_oee
FROM registros_produccion r
JOIN maquinas m USING (maquina_id)
JOIN turnos t USING (turno_id)
JOIN operarios o USING (operario_id)
JOIN referencias ref USING (referencia_id)
LEFT JOIN detalle_paros_produccion d USING (registro_id)
LEFT JOIN codigos_paro c ON c.codigo_paro_id = d.codigo_paro_id
GROUP BY r.registro_id, m.nombre, t.descripcion, o.nombre, ref.nombre, t.minutos_turno;

-- Las funciones de los triggers deben encontrar sus tablas sin depender del search_path de la sesión
ALTER FUNCTION produccion.fn_auditoria()             SET search_path = produccion, public;
ALTER FUNCTION produccion.fn_valida_subcodigo()      SET search_path = produccion, public;
ALTER FUNCTION produccion.fn_valida_duracion_turno() SET search_path = produccion, public;
