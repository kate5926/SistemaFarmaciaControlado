# Pharmacy RegulatoryControl 

## Introducción

**Pharmacy RegulatoryControl** es un sistema de gestión integral para farmacias que garantiza el control riguroso de medicamentos, especialmente aquellos clasificados como controlados. El sistema está diseñado para cumplir con regulaciones sanitarias estrictas, implementando trazabilidad completa de medicamentos controlados, protección de datos sensibles de pacientes y gestión automatizada de inventarios.

El sistema utiliza PostgreSQL como motor de base de datos, aprovechando sus capacidades avanzadas de seguridad, transacciones ACID y triggers para garantizar la integridad y consistencia de los datos en todo momento.

---

## Tabla de Contenidos

- [Requisitos Funcionales y su Implementación](#requisitos-funcionales-y-su-implementación)
  - [Requisito 1: Transacciones ACID](#-requisito-1-transacciones-acid-para-ventas-y-dispensación)
  - [Requisito 2: Índices para Optimización](#-requisito-2-índices-para-optimización-de-consultas)
  - [Requisito 3: Control y Auditoría](#-requisito-3-control-especial-con-auditoría-para-medicamentos-controlados)
  - [Requisito 4: Alertas Automáticas](#-requisito-4-alertas-automáticas-de-vencimientos-mediante-triggers)
  - [Requisito 5: Encriptación de Datos](#-requisito-5-encriptación-de-datos-sensibles)
  - [Requisito 6: Optimización de Consultas](#-requisito-6-optimización-de-consultas-de-inventario)

---

## Requisitos Funcionales y su Implementación

### Requisito 1: Transacciones ACID para Ventas y Dispensación

**Objetivo:** Garantizar que todas las operaciones de venta sean atómicas, consistentes, aisladas y duraderas.

**Implementación:** Función `fn_dispensar()`

Esta función transaccional cumple con los principios ACID:

- **Atomicidad:** Si cualquier paso falla, toda la transacción se revierte automáticamente
- **Consistencia:** Valida stock, existencia de lotes y recetas antes de proceder
- **Aislamiento:** Usa `FOR UPDATE` para evitar condiciones de carrera
- **Durabilidad:** Los cambios persisten permanentemente tras el commit
```sql
CREATE OR REPLACE FUNCTION fn_dispensar(
    p_lote_id INT,
    p_cantidad INT,
    p_receta_id INT,
    p_paciente_id INT,
    p_medico_id INT,
    p_usuario VARCHAR
) RETURNS TABLE(resultado TEXT, venta_id INT) AS $$
DECLARE
    v_stock INT;
    v_med_id INT;
    v_precio NUMERIC(10,2);
    v_venta_id INT;
BEGIN
    -- Validación de cantidad
    IF p_cantidad <= 0 THEN
        RETURN QUERY SELECT 'ERROR: cantidad debe ser > 0'::text, NULL::int;
        RETURN;
    END IF;

    -- Bloqueo de fila para evitar condiciones de carrera (AISLAMIENTO)
    SELECT stock, medicamento_id INTO v_stock, v_med_id
    FROM lotes WHERE id = p_lote_id FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT 'ERROR: lote no encontrado'::text, NULL::int;
        RETURN;
    END IF;
	
    -- Verificación de stock (CONSISTENCIA)
    IF v_stock < p_cantidad THEN
        RETURN QUERY SELECT 'ERROR: stock insuficiente'::text, NULL::int;
        RETURN;
    END IF;

    -- Obtener precio del medicamento
    SELECT precio INTO v_precio 
    FROM medicamentos 
    WHERE id = v_med_id;

    -- Restar stock (ATOMICIDAD)
    UPDATE lotes 
    SET stock = stock - p_cantidad 
    WHERE id = p_lote_id;

    -- Registrar venta
    INSERT INTO ventas (receta_id, usuario) 
    VALUES (p_receta_id, p_usuario) 
    RETURNING id INTO v_venta_id;

    -- Registrar detalle de venta
    INSERT INTO detalles_venta (venta_id, lote_id, medicamento_id, cantidad, precio_unitario)
    VALUES (v_venta_id, p_lote_id, v_med_id, p_cantidad, v_precio);

    -- Auditoría automática para medicamentos controlados
    IF (SELECT tipo FROM medicamentos WHERE id = v_med_id) = 'Controlado' THEN
        INSERT INTO auditoria_controlados (
            venta_id, medicamento_controlado_id, paciente_id,
            medico_id, cantidad_dispensada, usuario_que_dispenso, numero_receta
        ) VALUES (
            v_venta_id, v_med_id, p_paciente_id, p_medico_id, p_cantidad, p_usuario,
            (SELECT id::text FROM recetas WHERE id = p_receta_id)
        );
    END IF;

    -- Resultado exitoso (DURABILIDAD)
    RETURN QUERY SELECT 'OK'::text, v_venta_id;
END;
$$ LANGUAGE plpgsql VOLATILE;
```

**Uso:**
```sql
SELECT * FROM fn_dispensar(
    p_lote_id := 1, 
    p_cantidad := 5, 
    p_receta_id := 1,
    p_paciente_id := 1,
    p_medico_id := 1,
    p_usuario := 'usuario1'
);
```

**Beneficios:**
- ✅ Garantiza que las ventas sean completas o no se realicen
- ✅ Previene sobreventa de stock
- ✅ Evita condiciones de carrera en ventas simultáneas
- ✅ Auditoría automática de medicamentos controlados

---

###  Requisito 2: Índices para Optimización de Consultas

**Objetivo:** Mejorar el rendimiento de búsquedas frecuentes en medicamentos, lotes, fechas de vencimiento y recetas.

**Implementación:** Índices estratégicos BTREE
```sql
-- Índice compuesto para búsquedas por nombre y tipo de medicamento
CREATE INDEX idx_medicamentos ON medicamentos USING btree(nombre, tipo);

-- Índice para búsquedas de lotes por medicamento y fecha de vencimiento
CREATE INDEX idx_lotes ON lotes USING btree(medicamento_id, fecha_vencimiento);

-- Índice parcial: solo lotes con stock disponible próximos a vencer
CREATE INDEX idx_fechas_vencimiento ON lotes USING btree(fecha_vencimiento) 
WHERE stock > 0;

-- Índice para consultas de recetas por paciente y fecha
CREATE INDEX idx_recetas ON recetas USING btree(paciente_id, fecha_emision);
```

**Verificación de índices:**
```sql
SELECT indexname, tablename 
FROM pg_indexes 
WHERE schemaname = 'public' 
AND indexname LIKE 'idx%';
```

**Resultado esperado:**
```
     indexname          |   tablename   
-----------------------+---------------
 idx_medicamentos      | medicamentos
 idx_lotes             | lotes
 idx_fechas_vencimiento| lotes
 idx_recetas           | recetas
```

**Beneficios:**
- Búsquedas de medicamentos: **10-100x más rápidas**
-  Consultas de inventario con filtros: **Reducción significativa de I/O**
-  Alertas de vencimiento: **Acceso directo sin escaneo completo de tabla**
-  Historial de recetas: **Búsqueda instantánea por paciente**

---

###  Requisito 3: Control Especial con Auditoría para Medicamentos Controlados

**Objetivo:** Registrar trazabilidad completa de cada dispensación de medicamentos controlados con información del prescriptor, paciente y cantidad.

**Implementación:** Tabla `auditoria_controlados`
```sql
CREATE TABLE IF NOT EXISTS auditoria_controlados (
    id SERIAL PRIMARY KEY,
    venta_id INT REFERENCES ventas(id),
    medicamento_controlado_id INT REFERENCES medicamentos(id),
    paciente_id INT REFERENCES pacientes(id),
    medico_id INT REFERENCES medicos(id),
    cantidad_dispensada INT NOT NULL,
    usuario_que_dispenso VARCHAR(50) NOT NULL,
    fecha_dispensacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    numero_receta VARCHAR(100),
    motivo_consulta TEXT
);
```

**Características:**
- **Trazabilidad completa:** Registro automático en cada dispensación
- **Información regulatoria:** Médico prescriptor, paciente, cantidad, fecha
- **Integración automática:** La función `fn_dispensar()` detecta medicamentos controlados y crea el registro de auditoría

**Ejemplo de registro automático:**
```sql
-- Al dispensar un medicamento controlado, se registra automáticamente en auditoría
SELECT * FROM fn_dispensar(
    p_lote_id := 2,  -- Lote de Codeína (medicamento controlado)
    p_cantidad := 3,
    p_receta_id := 1,
    p_paciente_id := 1,
    p_medico_id := 1,
    p_usuario := 'farmaceutico01'
);

-- Verificar registro de auditoría
SELECT * FROM auditoria_controlados ORDER BY id DESC LIMIT 1;
```

**Consulta de auditoría completa:**
```sql
SELECT 
    ac.fecha_dispensacion,
    m.nombre AS medicamento,
    ac.cantidad_dispensada,
    p.nombre AS paciente,
    med.nombre AS medico_prescriptor,
    ac.usuario_que_dispenso,
    ac.numero_receta
FROM auditoria_controlados ac
JOIN medicamentos m ON ac.medicamento_controlado_id = m.id
JOIN pacientes p ON ac.paciente_id = p.id
JOIN medicos med ON ac.medico_id = med.id
ORDER BY ac.fecha_dispensacion DESC;
```

**Cumplimiento regulatorio:**
- ✅ Registro de quién dispensó
- ✅ Registro de quién prescribió
- ✅ Registro de a quién se dispensó
- ✅ Registro de cantidad y fecha
- ✅ Asociación con receta médica

---

### Requisito 4: Alertas Automáticas de Vencimientos mediante Triggers

**Objetivo:** Detectar automáticamente lotes próximos a vencer (30 días o menos) y generar alertas sin intervención manual.

**Implementación:** Trigger `trigger_alerta_vencimiento`

**Tabla de alertas:**
```sql
CREATE TABLE IF NOT EXISTS alertas_vencimiento (
    id SERIAL PRIMARY KEY,
    lote_id INT REFERENCES lotes(id),
    mensaje TEXT,
    fecha TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    procesado BOOLEAN DEFAULT FALSE
);
```

**Función del trigger:**
```sql
CREATE OR REPLACE FUNCTION alerta_vencimiento() RETURNS TRIGGER AS $$
DECLARE
    dias int;
    existe_alerta boolean;
    vencimiento_date date;
BEGIN
    vencimiento_date := NEW.fecha_vencimiento::date;
    dias := (vencimiento_date - CURRENT_DATE);
    
    -- Crear alerta si faltan 30 días o menos y aún hay stock
    IF (dias <= 30) AND NEW.stock > 0 THEN
        -- Verificar si YA existe alerta no procesada del mismo lote
        SELECT EXISTS (
            SELECT 1 FROM alertas_vencimiento
            WHERE lote_id = NEW.id AND procesado = FALSE
        ) INTO existe_alerta;
        
        -- Crear alerta solo si NO existe
        IF NOT existe_alerta THEN
            INSERT INTO alertas_vencimiento (lote_id, mensaje)
            VALUES (
                NEW.id,
                'ALERTA: Lote ' || NEW.lote_numero || ' vence el ' || 
                TO_CHAR(vencimiento_date,'YYYY-MM-DD') || ' - Stock: ' || NEW.stock
            );
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

**Crear el trigger:**
```sql
CREATE TRIGGER trigger_alerta_vencimiento
AFTER INSERT OR UPDATE OF fecha_vencimiento, stock ON lotes
FOR EACH ROW EXECUTE FUNCTION alerta_vencimiento();
```

**Consulta de alertas activas:**
```sql
SELECT 
    a.mensaje,
    a.fecha AS fecha_alerta,
    l.lote_numero,
    l.fecha_vencimiento,
    l.stock,
    m.nombre AS medicamento,
    (l.fecha_vencimiento - CURRENT_DATE) AS dias_restantes
FROM alertas_vencimiento a 
JOIN lotes l ON a.lote_id = l.id 
JOIN medicamentos m ON l.medicamento_id = m.id
WHERE a.procesado = FALSE
ORDER BY l.fecha_vencimiento;
```

**Ejemplo de funcionamiento:**
```sql
-- Insertar un lote que vence en 15 días
INSERT INTO lotes (medicamento_id, lote_numero, fecha_vencimiento, stock)
VALUES (1, 'LOTE_VENCE_PRONTO', CURRENT_DATE + INTERVAL '15 days', 50);

-- La alerta se crea AUTOMÁTICAMENTE
-- Verificar:
SELECT * FROM alertas_vencimiento WHERE procesado = FALSE;
```

**Beneficios:**
-  Detección automática sin intervención manual
-  Evita pérdidas por vencimiento de productos
-  Permite planificar ofertas o devoluciones
-  No genera alertas duplicadas

---

### Requisito 5: Encriptación de Datos Sensibles

**Objetivo:** Proteger información confidencial de pacientes y recetas mediante encriptación simétrica.

**Implementación:** Extensión `pgcrypto` de PostgreSQL

**Activar encriptación:**
```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
```

**Tabla pacientes con campos encriptados:**
```sql
CREATE TABLE IF NOT EXISTS pacientes (
    id SERIAL PRIMARY KEY,
    nombre VARCHAR(255),          -- Visible (no sensible)
    dni VARCHAR(8) UNIQUE,        -- Visible (identificador público)
    direccion BYTEA,              -- 🔒 ENCRIPTADO
    telefono BYTEA,               -- 🔒 ENCRIPTADO
    alergias BYTEA,               -- 🔒 ENCRIPTADO
    historial_medico BYTEA,       -- 🔒 ENCRIPTADO
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

**Tabla recetas con campos encriptados:**
```sql
CREATE TABLE IF NOT EXISTS recetas (
    id SERIAL PRIMARY KEY,
    paciente_id INT REFERENCES pacientes(id),
    medico_id INT REFERENCES medicos(id),
    fecha_emision DATE DEFAULT CURRENT_DATE,
    fecha_vencimiento DATE,
    diagnostico BYTEA,            -- 🔒 ENCRIPTADO
    tratamiento BYTEA,            -- 🔒 ENCRIPTADO
    instrucciones BYTEA,          -- 🔒 ENCRIPTADO
    observaciones BYTEA,          -- 🔒 ENCRIPTADO
    estado VARCHAR(20) DEFAULT 'Válida'
);
```

**Inserción con encriptación:**
```sql
INSERT INTO pacientes (nombre, dni, direccion, telefono, alergias, historial_medico)
VALUES (
    'Juan Pérez',
    '12345678',
    pgp_sym_encrypt('Calle 123', 'clave_segura'),
    pgp_sym_encrypt('987654321', 'clave_segura'),
    pgp_sym_encrypt('Ninguna', 'clave_segura'),
    pgp_sym_encrypt('Cirugía 2020', 'clave_segura')
);
```

**Inserción de recetas encriptadas:**
```sql
INSERT INTO recetas (paciente_id, medico_id, diagnostico, tratamiento, instrucciones, observaciones, fecha_emision, fecha_vencimiento)
VALUES (
    1, 1,
    pgp_sym_encrypt('Infección respiratoria leve', 'clave_segura'),
    pgp_sym_encrypt('Amoxicilina 500 mg por 7 días', 'clave_segura'),
    pgp_sym_encrypt('Tomar cada 8 horas después de comidas', 'clave_segura'),
    pgp_sym_encrypt('Control en una semana', 'clave_segura'),
    CURRENT_DATE,
    CURRENT_DATE + INTERVAL '30 days'
);
```

**Sistema de vistas con control de acceso por roles:**

**Tabla de usuarios:**
```sql
CREATE TABLE usuarios (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE,
    rol VARCHAR(20) CHECK (rol IN ('admin', 'farmaceutico', 'invitado')),
    clave_desbloqueo TEXT  -- Clave para desencriptar (solo admin)
);

-- Insertar usuarios de ejemplo
INSERT INTO usuarios (username, rol, clave_desbloqueo) VALUES
('Mary', 'admin', 'clave_segura'),      -- Puede ver datos cifrados
('juan', 'farmaceutico', NULL),         -- Ve datos clínicos parciales
('pedro', 'invitado', NULL);            -- Solo datos NO sensibles
```

#### 👨‍💼 Vista Administrador (acceso completo)
```sql
CREATE OR REPLACE VIEW vista_pacientes_admin AS
SELECT
    id, nombre, dni,
    pgp_sym_decrypt(direccion, 'clave_segura')::text AS direccion,
    pgp_sym_decrypt(telefono, 'clave_segura')::text AS telefono,
    pgp_sym_decrypt(alergias, 'clave_segura')::text AS alergias,
    pgp_sym_decrypt(historial_medico, 'clave_segura')::text AS historial_medico,
    fecha_registro
FROM pacientes;

CREATE OR REPLACE VIEW vista_recetas_admin AS
SELECT
    id, paciente_id, medico_id,
    fecha_emision, fecha_vencimiento,
    pgp_sym_decrypt(diagnostico, 'clave_segura')::text AS diagnostico,
    pgp_sym_decrypt(tratamiento, 'clave_segura')::text AS tratamiento,
    pgp_sym_decrypt(instrucciones, 'clave_segura')::text AS instrucciones,
    pgp_sym_decrypt(observaciones, 'clave_segura')::text AS observaciones,
    estado
FROM recetas;

-- Uso:
SELECT * FROM vista_pacientes_admin WHERE dni = '12345678';
```

####  Vista Farmacéutico (acceso parcial - solo alergias)
```sql
CREATE OR REPLACE VIEW vista_pacientes_farmaceutico AS
SELECT
    id, nombre, dni,
    pgp_sym_decrypt(alergias, 'clave_segura')::text AS alergias, -- Solo alergias
    fecha_registro
FROM pacientes;

-- Vista de recetas para farmacéutico (solo instrucciones)
CREATE OR REPLACE VIEW vista_recetas_farmaceutico AS
SELECT
    id, paciente_id, medico_id,
    fecha_emision, fecha_vencimiento,
    pgp_sym_decrypt(instrucciones, 'clave_segura')::text AS instrucciones,
    estado
FROM recetas;

-- Uso:
SELECT * FROM vista_pacientes_farmaceutico;
```

#### 👤 Vista Invitado (acceso mínimo - solo datos públicos)
```sql
CREATE OR REPLACE VIEW vista_pacientes_invitado AS
SELECT
    id, nombre, dni
FROM pacientes;

CREATE OR REPLACE VIEW vista_recetas_invitado AS
SELECT
    id, paciente_id, medico_id,
    fecha_emision, fecha_vencimiento,
    estado
FROM recetas;

-- Uso:
SELECT * FROM vista_pacientes_invitado;
```

**Comparación de acceso por rol:**

| Campo | Admin | Farmacéutico | Invitado |
|-------|-------|--------------|----------|
| Nombre, DNI | ✅ | ✅ | ✅ |
| Dirección | ✅ | ❌ | ❌ |
| Teléfono | ✅ | ❌ | ❌ |
| Alergias | ✅ | ✅ | ❌ |
| Historial Médico | ✅ | ❌ | ❌ |
| Diagnóstico | ✅ | ❌ | ❌ |
| Tratamiento | ✅ | ❌ | ❌ |
| Instrucciones | ✅ | ✅ | ❌ |

**Beneficios:**
- 🔐 Protección de datos sensibles en reposo
- 🔐 Control granular de acceso por roles
- 🔐 Cumplimiento con leyes de protección de datos
- 🔐 Trazabilidad de quién accede a qué información

---

### Requisito 6: Optimización de Consultas de Inventario

**Objetivo:** Proporcionar consultas rápidas y eficientes para gestión de inventario, rotación de productos y control de vencimientos.

#### Consulta 1: Estado del inventario con alertas automáticas
```sql
SELECT 
    m.nombre,
    l.lote_numero, 
    l.stock,
    l.fecha_vencimiento,
    CASE 
        WHEN l.fecha_vencimiento <= CURRENT_DATE + INTERVAL '30 days' THEN 'VENCE PRONTO'
        WHEN l.stock < 10 THEN 'STOCK BAJO'
        ELSE 'NORMAL'
    END AS estado
FROM medicamentos m 
JOIN lotes l ON m.id = l.medicamento_id
WHERE l.stock > 0
ORDER BY l.fecha_vencimiento;
```

**Resultado esperado:**
```
    nombre    | lote_numero | stock | fecha_vencimiento |    estado    
--------------+-------------+-------+-------------------+--------------
 Ibuprofeno   | LOTE004     |    30 | 2025-11-30        | VENCE PRONTO
 Aspirina     | LOTE001     |   100 | 2025-12-15        | VENCE PRONTO
 Codeína      | LOTE003     |    80 | 2026-06-28        | NORMAL
```

**Optimización:** Usa el índice `idx_lotes` y `idx_fechas_vencimiento` para acceso rápido.

---

#### 📊 Consulta 2: Rotación de productos (más vendidos)
```sql
SELECT 
    m.nombre,
    m.tipo,
    SUM(dv.cantidad) AS total_vendido,
    COUNT(DISTINCT dv.venta_id) AS veces_vendido,
    SUM(dv.cantidad * dv.precio_unitario) AS ingreso_total
FROM detalles_venta dv
JOIN medicamentos m ON m.id = dv.medicamento_id
GROUP BY m.id, m.nombre, m.tipo
ORDER BY total_vendido DESC;
```

**Resultado esperado:**
```
    nombre    |    tipo     | total_vendido | veces_vendido | ingreso_total
--------------+-------------+---------------+---------------+---------------
 Aspirina     | Común       |           105 |            15 |       262.50
 Amoxicilina  | Controlado  |            45 |             8 |       360.00
 Ibuprofeno   | Común       |            30 |             6 |        90.00
 Codeína      | Controlado  |            12 |             4 |       144.00
```

**Uso:** Identificar productos de alta rotación para mantener stock adecuado.

---

####  Consulta 3: Control de vencimientos activos
```sql
SELECT 
    a.mensaje,
    a.fecha AS fecha_alerta,
    l.lote_numero,
    l.fecha_vencimiento,
    l.stock,
    m.nombre AS medicamento,
    (l.fecha_vencimiento - CURRENT_DATE) AS dias_restantes
FROM alertas_vencimiento a 
JOIN lotes l ON a.lote_id = l.id 
JOIN medicamentos m ON l.medicamento_id = m.id
WHERE a.procesado = FALSE
ORDER BY l.fecha_vencimiento;
```

**Resultado esperado:**
```
                        mensaje                         | fecha_alerta | lote_numero | dias_restantes
-------------------------------------------------------+--------------+-------------+---------------
 ALERTA: Lote LOTE004 vence el 2025-11-30 - Stock: 30 | 2025-11-15   | LOTE004     |            1
 ALERTA: Lote LOTE001 vence el 2025-12-15 - Stock: 100| 2025-11-20   | LOTE001     |           16
```

**Optimización:** Usa índice parcial `idx_fechas_vencimiento` que filtra automáticamente lotes con stock > 0.

---

#### 📈 Consulta 4: Análisis de ventas por período
```sql
SELECT 
    DATE_TRUNC('month', v.fecha_venta) AS mes,
    COUNT(v.id) AS total_ventas,
    SUM(dv.cantidad * dv.precio_unitario) AS ingresos_totales,
    COUNT(DISTINCT v.receta_id) AS recetas_procesadas
FROM ventas v
JOIN detalles_venta dv ON v.id = dv.venta_id
WHERE v.fecha_venta >= CURRENT_DATE - INTERVAL '6 months'
GROUP BY DATE_TRUNC('month', v.fecha_venta)
ORDER BY mes DESC;
```

**Uso:** Análisis financiero y de rendimiento mensual.

---

#### Consulta 5: Lotes críticos (próximos a vencer y stock bajo)
```sql
SELECT 
    m.nombre AS medicamento,
    l.lote_numero,
    l.stock,
    l.fecha_vencimiento,
    (l.fecha_vencimiento - CURRENT_DATE) AS dias_restantes,
    CASE 
        WHEN l.stock = 0 THEN 'SIN STOCK'
        WHEN l.stock < 5 THEN 'CRÍTICO'
        WHEN l.stock < 10 THEN 'BAJO'
        ELSE 'SUFICIENTE'
    END AS nivel_stock
FROM lotes l
JOIN medicamentos m ON l.medicamento_id = m.id
WHERE l.fecha_vencimiento <= CURRENT_DATE + INTERVAL '60 days'
ORDER BY l.fecha_vencimiento, l.stock;
```

**Optimizaciones aplicadas:**
- ✅ Uso de índices BTREE en campos de búsqueda frecuente
- ✅ Índice parcial en `fecha_vencimiento` (solo para stock > 0)
- ✅ Índice compuesto en `lotes(medicamento_id, fecha_vencimiento)`
- ✅ Consultas con JOINs optimizados
- ✅ Uso de `CASE` para clasificación dinámica

---

