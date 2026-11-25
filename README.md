# Deber-2-Base-de-datos-
Smart Inventory: modelo relacional, integridad y consultas
# Smart Inventory — Base de Datos Transaccional (USFQ)

Sistema relacional transaccional en **PostgreSQL 16** para gestión de inventario multi-bodega, lotes con caducidad, picking **FEFO** (*First-Expired, First-Out*), reposición por punto de reorden y control de concurrencia.

## Estructura del Repositorio

* `docker-compose.yml`: Despliegue local aislado de PostgreSQL 16 en el puerto `5433`.
* `01_schema.sql`: Definición DDL de las 12 tablas normalizadas (3FN/BCNF), restricciones (`PK`, `FK`, `UNIQUE`, `CHECK`) y triggers de inmutabilidad y sincronización Kardex $\leftrightarrow$ Existencias.
* `02_seed.sql`: Carga de datos semilla con casos límite (lotes vencidos, próximos a vencer, sin caducidad, agotados y recepciones parciales) + 5 pruebas automatizadas de integridad.
* `03_queries.sql`: Ocho consultas operativas y analíticas (incluye CTEs, agregaciones y funciones de ventana `OVER`).
* `04_transactions.sql`: Procedimiento almacenado `sp_reservar_fefo` con bloqueo `FOR UPDATE` y escenario reproducible de concurrencia entre dos sesiones.
* `05_indexes_views.sql`: Dos vistas operativas de solo lectura para dashboard, creación de índices estratégicos (compuestos y parciales) y benchmark `EXPLAIN (ANALYZE, BUFFERS)` con 100,000 movimientos sintéticos.

## Instrucciones de Ejecución

1. **Levantar PostgreSQL con Docker:**
   ```bash
   docker compose up -d
