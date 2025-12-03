# Pharmacy RegulatoryControl 

## Introducción

**Pharmacy RegulatoryControl** sistema está pensado para la gestión de una farmacia, con control de inventario, ventas, recetas y auditoría de medicamentos controlados.

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
    p_id_lote INTEGER,
    p_cantidad INTEGER,
    p_id_receta INTEGER,
    p_id_paciente INTEGER,
    p_id_medico INTEGER,
    p_usuario VARCHAR(100)
) RETURNS TABLE(resultado TEXT, id_venta_generada INTEGER) AS $$
DECLARE
    v_stock_actual INTEGER;
    v_id_medicamento INTEGER;
    v_precio_venta DECIMAL(10,2);
    v_nueva_venta_id INTEGER;
    v_medicamento_nombre VARCHAR(200);
    v_requiere_receta BOOLEAN;
    v_receta_valida BOOLEAN;
    v_numero_venta VARCHAR(50);
BEGIN
    -- Validación básica
    IF p_cantidad <= 0 THEN
        RETURN QUERY SELECT 'ERROR: La cantidad debe ser mayor a 0'::TEXT, NULL::INTEGER;
        RETURN;
    END IF;

    -- BLOQUEO SIMULTÁNEO de lote Y receta (si aplica)
    IF p_id_receta IS NOT NULL THEN
        -- Verificar y bloquear receta primero
        SELECT EXISTS (
            SELECT 1 FROM recetas_medicas 
            WHERE id_receta = p_id_receta 
            AND estado = 'PENDIENTE'
            AND fecha_vencimiento >= CURRENT_DATE
            FOR UPDATE  -- BLOQUEO DE RECETA
        ) INTO v_receta_valida;
        
        IF NOT v_receta_valida THEN
            RETURN QUERY SELECT 'ERROR: Receta no válida'::TEXT, NULL::INTEGER;
            RETURN;
        END IF;
    END IF;

    -- Bloquear lote
    SELECT lm.cantidad_actual, lm.id_medicamento, m.precio_venta, m.nombre, m.requiere_receta
    INTO v_stock_actual, v_id_medicamento, v_precio_venta, v_medicamento_nombre, v_requiere_receta
    FROM lotes_medicamentos lm
    JOIN medicamentos m ON m.id_medicamento = lm.id_medicamento
    WHERE lm.id_lote = p_id_lote 
    AND lm.estado = 'ACTIVO'
    FOR UPDATE;  -- BLOQUEO DE LOTE

    -- Verificar lote
    IF NOT FOUND THEN
        RETURN QUERY SELECT 'ERROR: Lote no encontrado'::TEXT, NULL::INTEGER;
        RETURN;
    END IF;

    -- Verificar stock
    IF v_stock_actual < p_cantidad THEN
        RETURN QUERY SELECT 'ERROR: Stock insuficiente. Stock: ' || v_stock_actual::TEXT, NULL::INTEGER;
        RETURN;
    END IF;

    -- Verificar receta para medicamentos que la requieren
    IF v_requiere_receta AND p_id_receta IS NULL THEN
        RETURN QUERY SELECT 'ERROR: Medicamento requiere receta'::TEXT, NULL::INTEGER;
        RETURN;
    END IF;
    -- EJECUCIÓN DE LA TRANSACCIÓN
    BEGIN
        -- 1. Actualizar stock
        UPDATE lotes_medicamentos 
        SET cantidad_actual = cantidad_actual - p_cantidad
        WHERE id_lote = p_id_lote;

        -- 2. Generar número de venta único
        v_numero_venta := 'VENTA-' || TO_CHAR(CURRENT_TIMESTAMP, 'YYYYMMDD-HH24MISS-MS');
        
        -- 3. Crear venta
        INSERT INTO ventas (
            numero_venta, id_receta, id_paciente, subtotal, total, usuario_vendedor
        ) VALUES (
            v_numero_venta, p_id_receta, p_id_paciente, 
            v_precio_venta * p_cantidad, v_precio_venta * p_cantidad, p_usuario
        ) RETURNING id_venta INTO v_nueva_venta_id;

        -- 4. Crear detalle de venta
        INSERT INTO detalle_ventas (
            id_venta, id_medicamento, id_lote, cantidad, precio_unitario, subtotal
        ) VALUES (
            v_nueva_venta_id, v_id_medicamento, p_id_lote, p_cantidad,
            v_precio_venta, v_precio_venta * p_cantidad
        );

        -- 5. Actualizar receta (si aplica)
        IF p_id_receta IS NOT NULL THEN
            UPDATE recetas_medicas 
            SET estado = 'DISPENSADA'
            WHERE id_receta = p_id_receta;

            UPDATE detalle_recetas 
            SET cantidad_dispensada = cantidad_dispensada + p_cantidad,
                dispensado_completo = (cantidad_dispensada + p_cantidad >= cantidad_prescrita),
                fecha_dispensacion = CURRENT_TIMESTAMP
            WHERE id_receta = p_id_receta 
            AND id_medicamento = v_id_medicamento;
        END IF;

        -- ÉXITO
        RETURN QUERY SELECT 'OK: Venta exitosa - ' || v_medicamento_nombre::TEXT, v_nueva_venta_id;

    EXCEPTION
        WHEN unique_violation THEN
            RETURN QUERY SELECT 'ERROR: Número de venta duplicado'::TEXT, NULL::INTEGER;
        WHEN OTHERS THEN
            RETURN QUERY SELECT 'ERROR: ' || SQLERRM::TEXT, NULL::INTEGER;
    END;

END;
$$ LANGUAGE plpgsql;
```

**Uso:**
```sql
--PARA PROBAR 
--Atomicidad : Prueba 1: Intentar dispensar más stock del que hay
SELECT * FROM fn_dispensar(
    p_id_lote := 2,  -- LOTE-PARA-2024-01 (Paracetamol)
    p_cantidad := 9999,
    p_id_receta := NULL,
    p_id_paciente := 2,  
    p_id_medico := NULL,
    p_usuario := 'farmaceutico_ana'
);
--VEIFICAR
SELECT cantidad_actual 
FROM lotes_medicamentos WHERE id_lote = 2;

SELECT COUNT(*) FROM ventas;

SELECT * FROM ventas ORDER BY id_venta DESC LIMIT 10;

--------CONSISTENCIA
--Prueba 2: Intentar dispensar cantidad negativa
SELECT * FROM fn_dispensar(
    p_id_lote := 7,
    p_cantidad := 9999,
    p_id_receta := NULL,
    p_id_paciente := 1,
    p_id_medico := NULL,
    p_usuario := 'farmaceutico_maria'
);
--verificacion
SELECT cantidad_actual 
FROM lotes_medicamentos WHERE id_lote = 7;


-----AISLAMIENTO
/*CONTEXTO : 
Porque dos farmacéuticos 
pueden intentar dispensar el MISMO lote al mismo tiempo.
paso 1 : abrir dos transacciones manuales: */


INSERT INTO lotes_medicamentos (
    id_medicamento,
    numero_lote,
    fecha_fabricacion,
    fecha_vencimiento,
    cantidad_inicial,
    cantidad_actual,
    precio_compra,
    proveedor
) VALUES (
    1,                      -- Usa un medicamento existente (Paracetamol)
    'LOTE-TEST-ISO-01',     -- Nombre del lote para pruebas
    '2024-11-01',
    '2025-11-01',
    1,                      -- Cantidad inicial
    1,                      -- Cantidad actual
    1.50,
    'Proveedor de Pruebas'
);


--SESION A
BEGIN;
SELECT * FROM fn_dispensar(
    p_id_lote := 2,
    p_cantidad := 1,
    p_id_receta := NULL,
    p_id_paciente := 1,
    p_usuario := 'farmaceutico_maria'
);
SELECT pg_sleep(15);


--SESION  quedará BLOQUEADA esperando
BEGIN;

SELECT * FROM fn_dispensar(
    p_id_lote := 2,
    p_cantidad := 1,
    p_id_receta := NULL,
    p_id_paciente := 2,
    p_usuario := 'farmaceutico_carlos'
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

```sql
--Medicamentos
CREATE INDEX idx_medicamentos_busqueda 
ON medicamentos(nombre, principio_activo, es_controlado);
--lotes 
CREATE INDEX idx_lotes_medicamento_vencimiento 
ON lotes_medicamentos(id_medicamento, fecha_vencimiento, estado);
--Recetas 
CREATE INDEX idx_recetas_paciente_fecha 
ON recetas_medicas(id_paciente, fecha_emision, estado);
--Alertas
CREATE INDEX idx_alertas_prioridad_estado 
ON alertas_vencimiento(prioridad, estado, fecha_creacion);
-- Auditoria
CREATE INDEX idx_auditoria_fecha_medicamento 
ON auditoria_controlados(fecha_dispensacion, id_medicamento);

```
---

###  Requisito 3: Control Especial con Auditoría para Medicamentos Controlados

**Objetivo:** Registrar trazabilidad completa de cada dispensación de medicamentos controlados con información del prescriptor, paciente y cantidad.

**Implementación:** Tabla `auditoria_controlados`
```sql
CREATE TABLE auditoria_controlados (
    id_auditoria SERIAL PRIMARY KEY,
    id_venta INTEGER REFERENCES ventas(id_venta),
    id_medicamento INTEGER REFERENCES medicamentos(id_medicamento),
    id_receta INTEGER REFERENCES recetas_medicas(id_receta) NOT NULL,
    id_medico INTEGER REFERENCES medicos(id_medico) NOT NULL,
    id_paciente INTEGER REFERENCES pacientes(id_paciente) NOT NULL,
    cantidad_dispensada INTEGER NOT NULL,
    numero_lote VARCHAR(50) NOT NULL,
    fecha_dispensacion TIMESTAMP NOT NULL,
    usuario_dispensador VARCHAR(100) NOT NULL,
    observaciones TEXT,
    datos_completos_encriptados BYTEA, -- JSON con toda la información
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

**Características:**
- **Trazabilidad completa:** Registro automático en cada dispensación
- **Información regulatoria:** Médico prescriptor, paciente, cantidad, fecha
- **Integración automática:** La función `fn_dispensar()` detecta medicamentos controlados y crea el registro de auditoría

**Funcion Implementada:**
```sql
CREATE OR REPLACE FUNCTION auditar_medicamento_controlado()
RETURNS TRIGGER AS $$
DECLARE
    med_record RECORD;
    rec_record RECORD;
    datos_json JSONB;
BEGIN
    -- Verificar si el medicamento es controlado
    SELECT m.*, l.numero_lote
    INTO med_record
    FROM medicamentos m
    JOIN lotes_medicamentos l ON l.id_lote = NEW.id_lote
    WHERE m.id_medicamento = NEW.id_medicamento
    AND m.es_controlado = TRUE;
    
    IF FOUND THEN
        -- Obtener datos de la receta
        SELECT r.*, m.numero_colegiatura, m.nombre as medico_nombre,
               p.id_paciente
        INTO rec_record
        FROM ventas v
        LEFT JOIN recetas_medicas r ON r.id_receta = v.id_receta
        LEFT JOIN medicos m ON m.id_medico = r.id_medico
        LEFT JOIN pacientes p ON p.id_paciente = r.id_paciente
        WHERE v.id_venta = NEW.id_venta;
        
        -- Crear JSON con datos completos
        datos_json := jsonb_build_object(
            'medicamento', med_record.nombre,
            'lote', med_record.numero_lote,
            'cantidad', NEW.cantidad,
            'clasificacion', med_record.clasificacion_control,
            'receta', rec_record.numero_receta,
            'medico_colegiatura', rec_record.numero_colegiatura
        );
        
        -- Insertar auditoría
        INSERT INTO auditoria_controlados (
            id_venta, id_medicamento, id_receta, id_medico, id_paciente,
            cantidad_dispensada, numero_lote, fecha_dispensacion,
            usuario_dispensador, datos_completos_encriptados
        )
        VALUES (
            NEW.id_venta, NEW.id_medicamento, rec_record.id_receta,
            rec_record.id_medico, rec_record.id_paciente,
            NEW.cantidad, med_record.numero_lote, CURRENT_TIMESTAMP,
            (SELECT usuario_vendedor FROM ventas WHERE id_venta = NEW.id_venta),
            pgp_sym_encrypt(datos_json::text, 'clave_segura_auditorias')
        );
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

```

**Trigger para auditoría automática:**
```sql
CREATE TRIGGER trigger_auditoria_controlados
AFTER INSERT ON detalle_ventas
FOR EACH ROW
EXECUTE FUNCTION auditar_medicamento_controlado();

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

**Función del trigger:**
```sql

-- Función para generar alertas de vencimiento
CREATE OR REPLACE FUNCTION generar_alerta_vencimiento()
RETURNS TRIGGER AS $$
DECLARE
    dias_para_vencer INTEGER;
    tipo_alerta VARCHAR(50);
    mensaje_alerta TEXT;
    prioridad_alerta VARCHAR(20);
BEGIN
 -- Calcular días para vencimiento
    dias_para_vencer := NEW.fecha_vencimiento - CURRENT_DATE;
    
-- Determinar tipo de alerta y prioridad
    IF dias_para_vencer <= 0 THEN
        tipo_alerta := 'VENCIDO';
        mensaje_alerta := 'Lote vencido: ' || NEW.numero_lote;
        prioridad_alerta := 'ALTA';
    ELSIF dias_para_vencer <= 30 THEN
        tipo_alerta := 'PROXIMO_VENCER';
        mensaje_alerta := 'Lote próximo a vencer en ' || dias_para_vencer || ' días: ' || NEW.numero_lote;
        prioridad_alerta := 'ALTA';
    ELSIF dias_para_vencer <= 60 THEN
        tipo_alerta := 'PROXIMO_VENCER';
        mensaje_alerta := 'Lote vence en ' || dias_para_vencer || ' días: ' || NEW.numero_lote;
        prioridad_alerta := 'MEDIA';
    ELSIF dias_para_vencer <= 90 THEN
        tipo_alerta := 'PROXIMO_VENCER';
        mensaje_alerta := 'Lote vence en ' || dias_para_vencer || ' días: ' || NEW.numero_lote;
        prioridad_alerta := 'BAJA';
    ELSE
        RETURN NEW; -- No generar alerta
    END IF;
    
 -- Insertar alerta si no existe una activa para este lote
    INSERT INTO alertas_vencimiento (
        id_lote, id_medicamento, tipo_alerta, mensaje, 
        fecha_vencimiento, dias_restantes, cantidad_afectada, prioridad
    )
    SELECT NEW.id_lote, NEW.id_medicamento, tipo_alerta, mensaje_alerta,
           NEW.fecha_vencimiento, dias_para_vencer, NEW.cantidad_actual, prioridad_alerta
    WHERE NOT EXISTS (
        SELECT 1 FROM alertas_vencimiento 
        WHERE id_lote = NEW.id_lote 
        AND estado = 'ACTIVA'
    );
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger para alertas al insertar/actualizar lotes
CREATE TRIGGER trigger_alerta_vencimiento
AFTER INSERT OR UPDATE OF cantidad_actual, fecha_vencimiento ON lotes_medicamentos
FOR EACH ROW
WHEN (NEW.estado = 'ACTIVO')
EXECUTE FUNCTION generar_alerta_vencimiento();



-- Función para alerta de stock bajo
CREATE OR REPLACE FUNCTION alerta_stock_bajo()
RETURNS TRIGGER AS $$
DECLARE
    stock_total INTEGER;
    stock_min INTEGER;
BEGIN
    -- Calcular stock total del medicamento
    SELECT COALESCE(SUM(cantidad_actual), 0), m.stock_minimo
    INTO stock_total, stock_min
    FROM lotes_medicamentos l
    JOIN medicamentos m ON m.id_medicamento = l.id_medicamento
    WHERE l.id_medicamento = NEW.id_medicamento
    AND l.estado = 'ACTIVO'
    GROUP BY m.stock_minimo;
    
    -- Generar alerta si está bajo el mínimo
    IF stock_total <= stock_min THEN
        INSERT INTO alertas_vencimiento (
            id_medicamento, tipo_alerta, mensaje, 
            cantidad_afectada, prioridad, estado
        )
        SELECT NEW.id_medicamento, 'STOCK_BAJO',
               'Stock bajo: ' || m.nombre || ' (Stock: ' || stock_total || ', Mínimo: ' || stock_min || ')',
               stock_total, 'ALTA', 'ACTIVA'
        FROM medicamentos m
        WHERE m.id_medicamento = NEW.id_medicamento
        AND NOT EXISTS (
            SELECT 1 FROM alertas_vencimiento
            WHERE id_medicamento = NEW.id_medicamento
            AND tipo_alerta = 'STOCK_BAJO'
            AND estado = 'ACTIVA'
        );
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- Trigger para alerta de stock bajo
CREATE TRIGGER trigger_stock_bajo
AFTER UPDATE OF cantidad_actual ON lotes_medicamentos
FOR EACH ROW
EXECUTE FUNCTION alerta_stock_bajo();

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
----- PRUEVA DE TRIGGER 
--Insertar un lote que vence pronto
INSERT INTO lotes_medicamentos (
    id_medicamento, numero_lote, fecha_fabricacion, fecha_vencimiento, 
    cantidad_inicial, cantidad_actual, precio_compra, proveedor
) VALUES (
    1, 
    'LOTE-PRUEBA-VENCE-7DIAS',
    CURRENT_DATE - 10,               -- fabricación hace 10 días
    CURRENT_DATE + 7,                -- vence en 7 días
    10, 10, 2.00, 'Proveedor Test'
);
-- Prueba 2: Lote ya vencido
INSERT INTO lotes_medicamentos (
    id_medicamento, numero_lote, fecha_fabricacion, fecha_vencimiento, 
    cantidad_inicial, cantidad_actual, precio_compra, proveedor
) VALUES (
    1, 
    'LOTE-PRUEBA-VENCIDO',
    CURRENT_DATE - 100,              -- fabricación hace 100 días
    CURRENT_DATE - 5,                -- venció hace 5 días
    20, 20, 3.00, 'Proveedor Test'
);

---VERIFICACION : 
SELECT * FROM alertas_vencimiento 
ORDER BY fecha_creacion DESC 
LIMIT 10;
---
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
-- Tabla de Pacientes (datos encriptados)
CREATE TABLE pacientes (
    id_paciente SERIAL PRIMARY KEY,
    dni_encriptado BYTEA NOT NULL, -- DNI encriptado
    nombre_encriptado BYTEA NOT NULL,
    apellido_encriptado BYTEA NOT NULL,
    fecha_nacimiento_encriptada BYTEA,
    telefono_encriptado BYTEA,
    direccion_encriptada BYTEA,
    email VARCHAR(150),
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    activo BOOLEAN DEFAULT TRUE
);
```

**Tabla recetas con campos encriptados:**
```sql
CREATE TABLE recetas_medicas (
    id_receta SERIAL PRIMARY KEY,
    numero_receta VARCHAR(50) UNIQUE NOT NULL,
    id_medico INTEGER REFERENCES medicos(id_medico),
    id_paciente INTEGER REFERENCES pacientes(id_paciente),
    fecha_emision DATE NOT NULL,
    fecha_vencimiento DATE NOT NULL,
    diagnostico_encriptado BYTEA,  
    observaciones_encriptadas BYTEA,
    estado VARCHAR(20) DEFAULT 'PENDIENTE', -- PENDIENTE, DISPENSADA, VENCIDA, ANULADA
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```



### Requisito 6: Optimización de Consultas de Inventario

**Objetivo:** Proporcionar consultas rápidas y eficientes para gestión de inventario, rotación de productos y control de vencimientos.

#### Consulta 1: Optimizar consultas de inventario
```sql
SELECT 
    m.nombre,
    m.codigo_barras,
    lm.numero_lote,
    lm.cantidad_actual as stock,
    lm.fecha_vencimiento,
    CASE 
        WHEN lm.fecha_vencimiento <= CURRENT_DATE THEN 'VENCIDO'
        WHEN lm.fecha_vencimiento <= CURRENT_DATE + INTERVAL '30 days' THEN 'VENCE PRONTO'
        WHEN lm.cantidad_actual <= m.stock_minimo THEN 'STOCK BAJO'
        ELSE 'NORMAL'
    END AS estado
FROM medicamentos m 
JOIN lotes_medicamentos lm ON m.id_medicamento = lm.id_medicamento
WHERE lm.estado = 'ACTIVO'
ORDER BY lm.fecha_vencimiento;

```
---
#### Consulta 2: Rotación de productos (más vendidos)
```sql
SELECT 
    m.nombre,
    m.codigo_barras,
    SUM(dv.cantidad) AS total_vendido,
    COUNT(DISTINCT dv.id_venta) AS veces_vendido,
    AVG(dv.cantidad) AS promedio_por_venta,
    SUM(dv.subtotal) AS ingresos_totales
FROM detalle_ventas dv
JOIN medicamentos m ON m.id_medicamento = dv.id_medicamento
GROUP BY m.id_medicamento, m.nombre, m.codigo_barras
ORDER BY total_vendido DESC;
```
---
####  Consulta 3: Control de vencimientos 
```sql
SELECT 
    a.id_alerta,
    a.tipo_alerta,
    a.prioridad,
    m.nombre as medicamento,
    lm.numero_lote,
    lm.fecha_vencimiento,
    a.dias_restantes,
    a.mensaje,
    a.fecha_creacion
FROM alertas_vencimiento a 
JOIN lotes_medicamentos lm ON a.id_lote = lm.id_lote
JOIN medicamentos m ON lm.id_medicamento = m.id_medicamento
WHERE a.estado = 'ACTIVA'
ORDER BY 
    CASE a.prioridad 
        WHEN 'ALTA' THEN 1
        WHEN 'MEDIA' THEN 2 
        WHEN 'BAJA' THEN 3
    END,
    lm.fecha_vencimiento ASC;
```

---

#### Consulta 4: Optimizar consultas de inventario 
```sql
SELECT 
    m.id_medicamento,
    m.nombre,
    m.stock_minimo,
    COALESCE(SUM(lm.cantidad_actual), 0) as stock_total,
    COUNT(lm.id_lote) as total_lotes_activos,
    CASE 
        WHEN COALESCE(SUM(lm.cantidad_actual), 0) = 0 THEN 'SIN STOCK'
        WHEN COALESCE(SUM(lm.cantidad_actual), 0) <= m.stock_minimo THEN 'STOCK BAJO'
        ELSE 'STOCK SUFICIENTE'
    END as estado_inventario
FROM medicamentos m
LEFT JOIN lotes_medicamentos lm ON m.id_medicamento = lm.id_medicamento 
    AND lm.estado = 'ACTIVO'
WHERE m.activo = TRUE
GROUP BY m.id_medicamento, m.nombre, m.stock_minimo
ORDER BY estado_inventario, stock_total ASC

```

---



