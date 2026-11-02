"""Totales de control del Excel (para conciliar contra la base). Uso:
   python totales_excel.py SEGUIMIENTO_TEMPERAS_Y_VINILOS_Actividad.xlsm"""
import sys, re, warnings
import pandas as pd
warnings.filterwarnings("ignore")
df = pd.read_excel(sys.argv[1], sheet_name="Base De Datos", header=8)
df.columns = [re.sub(r"\s+", " ", str(c)).strip() for c in df.columns]
d = df[df["Fecha"].notna() & df["Maquina"].notna()]
cods = [f"Codigo de paro {i}" for i in range(1, 19)]
mins = d[cods].apply(pd.to_numeric, errors="coerce")
print("Filas con fecha y máquina :", len(d))
print("Horas de paro (Excel)     :", round(mins.sum().sum() / 60, 1))
print("Horas trabajadas (Excel)  :", round(pd.to_numeric(d["Horas trabajadas"], errors="coerce").sum(), 1))
print("Pacas producidas (Excel)  :", round(pd.to_numeric(d["Pacas producidas"], errors="coerce").sum(), 0))
