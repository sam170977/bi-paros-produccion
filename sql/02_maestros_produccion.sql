-- =====================================================================
-- Maestros del esquema produccion que no vienen del Excel
-- (turnos, operarios, referencias y subcódigos los carga el ETL)
-- =====================================================================
SET search_path = produccion;

INSERT INTO maquinas (nombre) VALUES ('Vinilos_1'),('Vinilos_2'),('Vinilos_3'),('Vinilos_4')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO agentes (nombre) VALUES ('Operarios'),('Personal_de_mantenimiento')
ON CONFLICT (nombre) DO NOTHING;

-- area_impacto y es_planificado son criterio del equipo (validar con la empresa)
INSERT INTO codigos_paro (codigo_paro_id, nombre, area_impacto, es_planificado, afecta_oee) VALUES
 (1,'Falla del sistema electromecánico y/o de control','Mantenimiento',false,true),
 (2,'Espera de soporte de mantenimiento','Mantenimiento',false,true),
 (3,'Novedad en los sistemas de potencia (Aire, energía, vapor)','Mantenimiento',false,true),
 (4,'Mantenimiento preventivo','Mantenimiento',true,true),
 (5,'Ajuste operativo','Producción',false,true),
 (6,'Limpieza por derrame operativo','Producción',false,true),
 (7,'Alistamiento de máquina / Cambio de referencia','Producción',true,true),
 (8,'Capacitación / Reunión','Producción',true,true),
 (9,'Falta de operario','Producción',false,true),
 (10,'Ventaja/Evacuación/Calidad','Producción',true,true),
 (11,'Reproceso','Calidad',false,true),
 (12,'Materia prima defectuosa','Calidad',false,true),
 (13,'En espera por el aval del laboratorio de microbiología','Calidad',false,true),
 (14,'Falta de materia prima','Logística',false,true),
 (15,'Cambio de insumos (Roscadores, O''ring, Etiquetas)','Producción',false,true),
 (16,'Alimentación y aseo de la zona de trabajo y la máquina','Producción',false,true),
 (17,'Pausa activa','Producción',true,true),
 (18,'Desinfección','Producción',true,true),
 (19,'No aplica','N/A',false,false)
ON CONFLICT (codigo_paro_id) DO NOTHING;
