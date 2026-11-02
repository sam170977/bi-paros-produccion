#!/usr/bin/env python3
"""
ETL – Registro de paros de producción (Excel -> PostgreSQL)
Origen : SEGUIMIENTO_TEMPERAS_Y_VINILOS_*.xlsm, hoja "Base De Datos" (encabezado en la fila 9)
Destino: esquema `produccion` (registros_produccion + detalle_paros_produccion)

Uso:
  pip install pandas openpyxl psycopg2-binary
  export PG_DSN="host=localhost dbname=paros_produccion user=postgres password=TU_CLAVE"

  python etl_paros.py --archivo SEGUIMIENTO.xlsm --dry-run        # solo valida, no toca la BD
  python etl_paros.py --archivo SEGUIMIENTO.xlsm                  # carga completa (idempotente)
  python etl_paros.py --archivo SEGUIMIENTO.xlsm --incremental    # solo últimos 7 días + nuevos
"""
import argparse, json, logging, os, re, sys
from datetime import time, timedelta
import pandas as pd

HOJA, FILA_ENCABEZADO = "Base De Datos", 8          # índice 0 -> fila 9 de Excel
SIN = "Sin especificar"
KEY = ["fecha", "maquina", "turno", "operario", "referencia"]
SUBCOL = {1: "Sub Codigo de paro 1", 3: "Subcodigo 3", 5: "Subcodigo 5"}
MIN_SIN_TURNO = 1440                                  # turno desconocido: no se limita a menos de 24 h

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                    handlers=[logging.FileHandler("etl_paros.log", encoding="utf-8"),
                              logging.StreamHandler(sys.stdout)])
log = logging.getLogger("etl")


# ----------------------------------------------------------------- utilidades
def txt(v, defecto=SIN):
    """Normaliza texto: espacios, vacíos y 'No aplica' -> valor por defecto."""
    if pd.isna(v):
        return defecto
    s = re.sub(r"\s+", " ", str(v)).strip()
    return defecto if s == "" or s.lower() in ("no aplica", "nan") else s


def parse_turno(desc):
    """'6am-4:30pm' / '10pm-6am (Turno 3)' -> (hora_inicio, hora_fin, minutos)."""
    m = re.match(r"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*-\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)", desc, re.I)
    if not m:
        return time(0, 0), time(0, 0), MIN_SIN_TURNO

    def a_min(h, mi, ap):
        h = int(h) % 12 + (12 if ap.lower() == "pm" else 0)
        return h * 60 + int(mi or 0)
    ini, fin = a_min(m[1], m[2], m[3]), a_min(m[4], m[5], m[6])
    dur = (fin - ini) % 1440 or 1440
    return time(ini // 60, ini % 60), time(fin // 60, fin % 60), dur


def parse_subcodigo(s):
    """'1.2.B Ajuste de sensor' -> ('1.2.B', 'Ajuste de sensor')."""
    s = txt(s, None)
    if not s:
        return None, None
    m = re.match(r"^(\d+(?:\.\d+)*(?:\.[A-Za-z])?)\.?\s+(.*)$", s)
    return (m[1].upper(), m[2].strip()) if m else (None, s)


# ------------------------------------------------------------------ EXTRACT
def extraer(ruta):
    df = pd.read_excel(ruta, sheet_name=HOJA, header=FILA_ENCABEZADO)
    df.columns = [re.sub(r"\s+", " ", str(c)).strip() for c in df.columns]
    df["_fila_excel"] = df.index + FILA_ENCABEZADO + 2
    log.info("Leídas %d filas de la hoja '%s'", len(df), HOJA)
    return df


# ---------------------------------------------------------------- TRANSFORM
def transformar(df):
    rechazos = []

    def rechazar(sub, motivo):
        for _, r in sub.iterrows():
            rechazos.append({"fila_excel": int(r["_fila_excel"]),
                             "fecha": r["Fecha"].date() if pd.notna(r["Fecha"]) else None,
                             "maquina": txt(r.get("Maquina"), None), "motivo": motivo})

    df = df.copy()
    df["Fecha"] = pd.to_datetime(df["Fecha"], errors="coerce")
    malas = df["Fecha"].isna() & df.drop(columns="_fila_excel").notna().any(axis=1)
    rechazar(df[malas], "Fecha vacía o inválida"); df = df[df["Fecha"].notna()]
    sin_maq = df["Maquina"].isna()
    rechazar(df[sin_maq], "Máquina vacía"); df = df[~sin_maq]

    df["fecha"] = df["Fecha"].dt.date
    df["maquina"] = df["Maquina"].map(txt)
    df["turno"] = df["Turno"].map(txt)
    df["operario"] = df["Operario"].map(txt)
    df["referencia"] = df["Referencia"].map(txt)
    for c in ("Horas trabajadas", "Pacas producidas"):
        df[c] = pd.to_numeric(df[c], errors="coerce")

    # --- detalle: 18 columnas anchas -> formato largo
    partes = []
    for i in range(1, 19):
        c = f"Codigo de paro {i}"
        if c not in df.columns:
            continue
        t = df[KEY + ["_fila_excel"]].copy()
        t["codigo_paro_id"] = i
        t["duracion_min"] = pd.to_numeric(df[c], errors="coerce")
        t["sub_raw"] = df[SUBCOL[i]] if i in SUBCOL else None
        t["agente"] = df["Área involucrada en subcodigo 5"].map(lambda v: txt(v, None)) if i == 5 else None
        t["personal"] = df["Personal involucrado"].map(lambda v: txt(v, None)) if i == 5 else None
        partes.append(t[t["duracion_min"].notna() & (t["duracion_min"] != 0)])
    det = pd.concat(partes, ignore_index=True)
    neg = det["duracion_min"] < 0
    rechazar(df[df["_fila_excel"].isin(det.loc[neg, "_fila_excel"])], "Duración de paro negativa")
    det = det[~neg]
    parsed = det["sub_raw"].map(parse_subcodigo)
    det["sub_clave"] = parsed.map(lambda x: x[0]); det["sub_desc"] = parsed.map(lambda x: x[1])
    # el subcódigo debe pertenecer al código (p. ej. '5.8' solo bajo el código 5)
    incoh = det["sub_clave"].notna() & (det["sub_clave"].str.split(".").str[0].astype(float) != det["codigo_paro_id"])
    log.warning("%d subcódigos no coinciden con su código; se cargan sin subcódigo", incoh.sum())
    det.loc[incoh, ["sub_clave", "sub_desc"]] = None
    det = (det.groupby(KEY + ["codigo_paro_id", "sub_clave", "agente", "personal"], dropna=False, as_index=False)
              .agg(duracion_min=("duracion_min", "sum"), sub_desc=("sub_desc", "first"),
                   fila_excel=("_fila_excel", "min")))

    # --- registros: las filas "Ingreso subcódigo" (sin horas ni pacas) se funden con su turno
    obs = lambda s: " | ".join(sorted({txt(x, "") for x in s} - {""})) or None
    reg = (df.groupby(KEY, as_index=False)
             .agg(horas_trabajadas=("Horas trabajadas", "sum"), pacas_producidas=("Pacas producidas", "sum"),
                  observacion=("Observaciones de paro", obs), fila_excel=("_fila_excel", "min")))
    # Con turno conocido, >24 h es un error de digitación. Con turno "Sin especificar" (2022-2023) los
    # turnos del mismo día quedan fundidos en un solo registro y pasar de 24 h es normal: se conservan.
    exceso = (reg["horas_trabajadas"] > 24) & (reg["turno"] != SIN)
    rechazar(df[df["_fila_excel"].isin(reg.loc[exceso, "fila_excel"])], "Horas trabajadas > 24 con turno conocido")
    reg = reg[~exceso]
    det = det.merge(reg[KEY], on=KEY, how="inner")          # descarta detalle de registros rechazados
    log.info("Transformación: %d registros, %d paros, %d filas rechazadas", len(reg), len(det), len(rechazos))
    return reg, det, rechazos


# --------------------------------------------------------------------- LOAD
def cargar(reg, det, rechazos, dsn, incremental=False, desde=None):
    import psycopg2, psycopg2.extras
    con = psycopg2.connect(dsn); con.autocommit = False
    cur = con.cursor(); cur.execute("SET search_path = produccion, public")
    cur.execute("""CREATE TABLE IF NOT EXISTS errores_etl (
        error_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ejecutado_en TIMESTAMPTZ DEFAULT now(),
        fila_excel INT, fecha DATE, maquina TEXT, motivo TEXT, datos JSONB)""")

    if incremental and not desde:
        cur.execute("SELECT max(fecha) FROM registros_produccion"); m = cur.fetchone()[0]
        desde = (m - timedelta(days=7)).isoformat() if m else None
    if desde:
        d0 = pd.to_datetime(desde).date()
        reg = reg[reg["fecha"] >= d0]; det = det.merge(reg[KEY], on=KEY)
        log.info("Carga desde %s: %d registros", d0, len(reg))

    # 1) dimensiones
    cur.execute("INSERT INTO turnos (descripcion,hora_inicio,hora_fin,minutos_turno) VALUES (%s,'00:00','00:00',%s) "
                "ON CONFLICT (descripcion) DO NOTHING", (SIN, MIN_SIN_TURNO))
    for t in reg["turno"].unique():
        if t != SIN:
            ini, fin, mins = parse_turno(t)
            cur.execute("INSERT INTO turnos (descripcion,hora_inicio,hora_fin,minutos_turno) VALUES (%s,%s,%s,%s) "
                        "ON CONFLICT (descripcion) DO NOTHING", (t, ini, fin, mins))
    for tabla, col, vals in (("maquinas", "nombre", reg["maquina"].unique()),
                             ("operarios", "nombre", reg["operario"].unique()),
                             ("referencias", "nombre", reg["referencia"].unique())):
        psycopg2.extras.execute_values(cur, f"INSERT INTO {tabla} ({col}) VALUES %s ON CONFLICT ({col}) DO NOTHING",
                                       [(v,) for v in vals])
    subs = det.dropna(subset=["sub_clave"]).groupby(["codigo_paro_id", "sub_clave"])["sub_desc"] \
              .agg(lambda s: s.mode().iat[0]).reset_index()      # descripción más frecuente por clave
    psycopg2.extras.execute_values(
        cur, "INSERT INTO subcodigos_paro (codigo_paro_id,clave,descripcion) VALUES %s "
             "ON CONFLICT (codigo_paro_id,clave) DO NOTHING",
        [(int(r.codigo_paro_id), r.sub_clave, r.sub_desc) for r in subs.itertuples()])
    agentes = {a for a in det["agente"].dropna().unique()}
    psycopg2.extras.execute_values(cur, "INSERT INTO agentes (nombre) VALUES %s ON CONFLICT (nombre) DO NOTHING",
                                   [(a,) for a in agentes])
    con.commit()

    def mapa(sql):
        cur.execute(sql); return {k: v for k, v in cur.fetchall()}
    M = mapa("SELECT nombre, maquina_id FROM maquinas"); T = mapa("SELECT descripcion, turno_id FROM turnos")
    O = mapa("SELECT nombre, operario_id FROM operarios"); R = mapa("SELECT nombre, referencia_id FROM referencias")
    A = mapa("SELECT nombre, agente_id FROM agentes")
    cur.execute("SELECT codigo_paro_id, clave, subcodigo_id FROM subcodigos_paro")
    S = {(c, k): i for c, k, i in cur.fetchall()}
    cur.execute("SELECT codigo_paro_id FROM codigos_paro"); codigos = {r[0] for r in cur.fetchall()}

    # 2) rechazos de la transformación
    for r in rechazos:
        cur.execute("INSERT INTO errores_etl (fila_excel,fecha,maquina,motivo) VALUES (%s,%s,%s,%s)",
                    (r["fila_excel"], r["fecha"], r["maquina"], r["motivo"]))

    # 3) hechos + detalle, un SAVEPOINT por registro (si un trigger rechaza, solo cae ese registro)
    det_por = {k: g for k, g in det.groupby(KEY)}
    ok = fallos = n_det = 0
    for r in reg.itertuples(index=False):
        k = (r.fecha, r.maquina, r.turno, r.operario, r.referencia)
        cur.execute("SAVEPOINT sp")
        n_reg = 0
        try:
            cur.execute("""INSERT INTO registros_produccion
                  (fecha,maquina_id,turno_id,operario_id,referencia_id,horas_trabajadas,pacas_producidas,observacion,fuente)
                  VALUES (%s,%s,%s,%s,%s,%s,%s,%s,'excel')
                  ON CONFLICT ON CONSTRAINT uq_registro DO UPDATE SET
                    horas_trabajadas=EXCLUDED.horas_trabajadas, pacas_producidas=EXCLUDED.pacas_producidas,
                    observacion=EXCLUDED.observacion
                  RETURNING registro_id""",
                        (r.fecha, M[r.maquina], T[r.turno], O[r.operario], R[r.referencia],
                         float(r.horas_trabajadas), float(r.pacas_producidas), r.observacion))
            rid = cur.fetchone()[0]
            cur.execute("DELETE FROM detalle_paros_produccion WHERE registro_id=%s", (rid,))
            for d in (det_por[k].itertuples(index=False) if k in det_por else []):
                if d.codigo_paro_id not in codigos:
                    raise ValueError(f"Código de paro {d.codigo_paro_id} no existe en codigos_paro")
                sid = S.get((d.codigo_paro_id, d.sub_clave)) if pd.notna(d.sub_clave) else None
                cur.execute("""INSERT INTO detalle_paros_produccion
                      (registro_id,codigo_paro_id,subcodigo_id,duracion_min,agente_id,personal_involucrado)
                      VALUES (%s,%s,%s,%s,%s,%s)""",
                            (rid, int(d.codigo_paro_id), sid, float(d.duracion_min),
                             A.get(d.agente) if pd.notna(d.agente) else None,
                             d.personal if pd.notna(d.personal) else None))
                n_reg += 1
            cur.execute("RELEASE SAVEPOINT sp"); ok += 1; n_det += n_reg
        except Exception as e:
            cur.execute("ROLLBACK TO SAVEPOINT sp")
            msg = str(e).splitlines()[0]
            cur.execute("INSERT INTO errores_etl (fila_excel,fecha,maquina,motivo,datos) VALUES (%s,%s,%s,%s,%s)",
                        (int(r.fila_excel), r.fecha, r.maquina, msg, json.dumps({"clave": [str(x) for x in k]})))
            fallos += 1
        if (ok + fallos) % 500 == 0:
            con.commit(); log.info("Progreso: %d registros (%d con error)", ok + fallos, fallos)
    con.commit(); con.close()
    log.info("CARGA TERMINADA: %d registros OK, %d con error, %d paros insertados, %d filas rechazadas antes de cargar",
             ok, fallos, n_det, len(rechazos))


# --------------------------------------------------------------------- MAIN
if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--archivo", required=True)
    ap.add_argument("--dsn", default=os.getenv("PG_DSN"))
    ap.add_argument("--dry-run", action="store_true", help="valida y resume, sin conectarse a la BD")
    ap.add_argument("--incremental", action="store_true")
    ap.add_argument("--desde", help="YYYY-MM-DD")
    a = ap.parse_args()

    reg, det, rech = transformar(extraer(a.archivo))
    if a.dry_run:
        print("\n== DRY-RUN ==")
        print("Registros:", len(reg), "| Paros:", len(det), "| Rechazos:", len(rech))
        print("Rango de fechas:", reg.fecha.min(), "->", reg.fecha.max())
        print("Turnos:", reg.turno.value_counts().to_dict())
        print("Registros con operario/referencia/turno sin especificar:",
              (reg.operario == SIN).sum(), "/", (reg.referencia == SIN).sum(), "/", (reg.turno == SIN).sum())
        print("Top códigos (horas):\n", (det.groupby("codigo_paro_id").duracion_min.sum() / 60).round(0)
              .sort_values(ascending=False).head(6).to_string())
        sys.exit(0)
    if not a.dsn:
        sys.exit("Falta la cadena de conexión: define PG_DSN o usa --dsn")
    cargar(reg, det, rech, a.dsn, a.incremental, a.desde)
