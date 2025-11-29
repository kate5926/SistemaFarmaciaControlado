# SistemaFarmaciaControlado


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
- [Modelo de Datos](#modelo-de-datos)
- [Casos de Uso](#casos-de-uso)
- [Seguridad y Cumplimiento](#seguridad-y-cumplimiento)
- [Instalación y Configuración](#instalación-y-configuración)
- [Pruebas del Sistema](#pruebas-del-sistema)

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
