-- ============================================================================
-- SMART INVENTORY - 05_indexes_views.sql
-- Vistas operativas para dashboard, índices estratégicos y benchmark EXPLAIN
-- ============================================================================

-- ----------------------------------------------------------------------------
-- PARTE A: VISTAS REUTILIZABLES PARA DASHBOARD (Solo lectura)
-- ----------------------------------------------------------------------------

-- Vista 1: Estado consolidado de inventario, vencimientos y reposición por SKU
CREATE OR REPLACE VIEW vw_dashboard_inventario_critico AS
WITH stock_vigente AS (
    SELECT
        l.sku_id,
        COALESCE(SUM(el.qty_on_hand), 0) AS stock_fisico_vigente,
        COALESCE(SUM(el.qty_reserved), 0) AS stock_reservado,
        COALESCE(SUM(el.qty_on_hand - el.qty_reserved), 0) AS stock_disponible,
        COUNT(DISTINCT l.lot_id) FILTER (
            WHERE l.vence_en IS NOT NULL
                AND l.vence_en > CURRENT_DATE
                AND l.vence_en <= CURRENT_DATE + INTERVAL '30 days'
                AND el.qty_on_hand > 0
            ) AS lotes_por_vencer_30d
    FROM lote l
             LEFT JOIN existencia_lote el ON el.lot_id = l.lot_id
    WHERE l.vence_en IS NULL OR l.vence_en > CURRENT_DATE
    GROUP BY l.sku_id
),
     stock_vencido AS (
         SELECT
             l.sku_id,
             COALESCE(SUM(el.qty_on_hand), 0) AS stock_vencido_bloqueado
         FROM lote l
                  JOIN existencia_lote el ON el.lot_id = l.lot_id
         WHERE l.vence_en IS NOT NULL
           AND l.vence_en <= CURRENT_DATE
         GROUP BY l.sku_id
     ),
     transito_compras AS (
         SELECT
             dc.sku_id,
             SUM(dc.qty_ordered - COALESCE(rec.qty_recibida, 0)) AS unidades_en_transito
         FROM detalle_compra dc
                  JOIN orden_compra oc ON oc.po_id = dc.po_id
                  LEFT JOIN (
             SELECT po_id, po_line_no, SUM(cantidad) AS qty_recibida
             FROM movimiento
             WHERE tipo = 'RECEPCION'
             GROUP BY po_id, po_line_no
         ) rec ON rec.po_id = dc.po_id AND rec.po_line_no = dc.line_no
         WHERE oc.estado IN ('ABIERTA', 'PARCIAL')
         GROUP BY dc.sku_id
     )
SELECT
    p.sku_id,
    p.sku_code,
    p.nombre AS producto,
    p.unidad,
    COALESCE(sv.stock_fisico_vigente, 0) AS stock_fisico_vigente,
    COALESCE(sv.stock_reservado, 0) AS stock_reservado,
    COALESCE(sv.stock_disponible, 0) AS stock_disponible,
    COALESCE(svx.stock_vencido_bloqueado, 0) AS stock_vencido_bloqueado,
    COALESCE(tc.unidades_en_transito, 0) AS unidades_en_transito,
    (COALESCE(sv.stock_fisico_vigente, 0) + COALESCE(tc.unidades_en_transito, 0) - COALESCE(sv.stock_reservado, 0)) AS posicion_inventario,
    p.stock_minimo,
    p.stock_objetivo,
    GREATEST(
            0,
            p.stock_objetivo - (COALESCE(sv.stock_fisico_vigente, 0) + COALESCE(tc.unidades_en_transito, 0) - COALESCE(sv.stock_reservado, 0))
    ) AS sugerencia_compra,
    COALESCE(sv.lotes_por_vencer_30d, 0) AS lotes_por_vencer_30d,
    pr.nombre AS proveedor_habitual,
    CASE
        WHEN (COALESCE(sv.stock_fisico_vigente, 0) + COALESCE(tc.unidades_en_transito, 0) - COALESCE(sv.stock_reservado, 0)) < p.stock_minimo
            THEN 'REPOSICION_URGENTE'
        WHEN COALESCE(sv.lotes_por_vencer_30d, 0) > 0
            THEN 'ALERTA_CADUCIDAD'
        ELSE 'NORMAL'
        END AS semaforo_operativo
FROM producto p
         LEFT JOIN stock_vigente sv ON sv.sku_id = p.sku_id
         LEFT JOIN stock_vencido svx ON svx.sku_id = p.sku_id
         LEFT JOIN transito_compras tc ON tc.sku_id = p.sku_id
         LEFT JOIN proveedor pr ON pr.supplier_id = p.default_supplier_id
WHERE p.activo = TRUE;


-- Vista 2: Seguimiento operativo de pedidos y cumplimiento por línea
CREATE OR REPLACE VIEW vw_dashboard_seguimiento_pedidos AS
SELECT
    ped.order_id,
    ped.estado AS estado_pedido,
    ped.creado_en AS fecha_pedido,
    dp.line_no,
    p.sku_code,
    p.nombre AS producto,
    dp.qty_requested AS qty_solicitada,
    COALESCE(SUM(r.qty_reserved) FILTER (WHERE r.estado = 'ACTIVA'), 0) AS qty_reservada_activa,
    COALESCE(SUM(r.qty_reserved) FILTER (WHERE r.estado = 'CONSUMIDA'), 0) AS qty_despachada,
    dp.qty_requested - COALESCE(SUM(r.qty_reserved) FILTER (WHERE r.estado IN ('ACTIVA', 'CONSUMIDA')), 0) AS qty_pendiente_asignar,
    COUNT(DISTINCT r.lot_id) FILTER (WHERE r.estado IN ('ACTIVA', 'CONSUMIDA')) AS lotes_utilizados
FROM pedido ped
         JOIN detalle_pedido dp ON dp.order_id = ped.order_id
         JOIN producto p ON p.sku_id = dp.sku_id
         LEFT JOIN reserva r ON r.order_id = dp.order_id AND r.line_no = dp.line_no
GROUP BY ped.order_id, ped.estado, ped.creado_en, dp.line_no, p.sku_code, p.nombre, dp.qty_requested;


-- ----------------------------------------------------------------------------
-- PARTE B: SIMULACIÓN DE VOLUMEN (100,000 movimientos) PARA BENCHMARK DE ÍNDICES
-- Nota: Ejecutar PASO 1 -> PASO 2 (capturar planes ANTES) -> PASO 3 -> PASO 4 (capturar planes DESPUÉS)
-- ----------------------------------------------------------------------------

-- PASO 1: Inyectar 100,000 movimientos sintéticos para forzar decisiones reales del optimizador
INSERT INTO movimiento (lot_id, origen_location_id, destino_location_id, tipo, cantidad, fecha, observacion)
SELECT
    (floor(random() * 5) + 1)::BIGINT,
    NULL,
    (floor(random() * 2) + 1)::BIGINT,
    'AJUSTE_POS',
    (floor(random() * 5) + 1)::INTEGER,
    NOW() - (random() * INTERVAL '365 days'),
    'Benchmark carga sintética #' || g
FROM generate_series(1, 100000) AS g;

ANALYZE;


-- PASO 2: Ejecutar EXPLAIN (ANALYZE, BUFFERS) ANTES de crear los índices
-- Consulta Crítica A: Historial y rotación de movimientos por lote y rango de fechas
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    l.sku_id,
    DATE_TRUNC('month', m.fecha) AS mes,
    m.tipo,
    COUNT(*) AS num_movs,
    SUM(m.cantidad) AS total_unidades
FROM movimiento m
         JOIN lote l ON l.lot_id = m.lot_id
WHERE m.lot_id = 3
  AND m.fecha >= NOW() - INTERVAL '60 days'
GROUP BY l.sku_id, DATE_TRUNC('month', m.fecha), m.tipo;

-- Consulta Crítica B: Recepciones parciales de una orden de compra específica
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    dc.po_id,
    dc.line_no,
    dc.qty_ordered,
    COALESCE(SUM(m.cantidad), 0) AS qty_recibida
FROM detalle_compra dc
         LEFT JOIN movimiento m
                   ON m.po_id = dc.po_id
                       AND m.po_line_no = dc.line_no
                       AND m.tipo = 'RECEPCION'
WHERE dc.po_id = 1
GROUP BY dc.po_id, dc.line_no, dc.qty_ordered;

-- Consulta Crítica C: Selección FEFO de lotes elegibles por SKU ordenados por caducidad
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    el.lot_id,
    el.location_id,
    l.lot_code,
    l.vence_en,
    (el.qty_on_hand - el.qty_reserved) AS disponible
FROM existencia_lote el
         JOIN lote l ON l.lot_id = el.lot_id
WHERE l.sku_id = 1
  AND (l.vence_en IS NULL OR l.vence_en > CURRENT_DATE)
  AND (el.qty_on_hand - el.qty_reserved) > 0
ORDER BY l.vence_en ASC NULLS LAST, l.recibido_en ASC, el.lot_id ASC;


-- PASO 3: Creación de Índices Propuestos
-- 1. Índice compuesto para FEFO y control de caducidades (cubre FK sku_id + orden FEFO)
CREATE INDEX IF NOT EXISTS idx_lote_sku_fefo
    ON lote (sku_id, vence_en ASC NULLS LAST, recibido_en ASC);

-- 2. Índice compuesto para kardex y rotación por lote/fecha (cubre FK lot_id + filtro temporal)
CREATE INDEX IF NOT EXISTS idx_movimiento_lot_fecha
    ON movimiento (lot_id, fecha DESC);

-- 3. Índice parcial exclusivo para recepciones de órdenes de compra (alta selectividad, bajo costo de escritura)
CREATE INDEX IF NOT EXISTS idx_movimiento_po_recepcion
    ON movimiento (po_id, po_line_no)
    WHERE tipo = 'RECEPCION' AND po_id IS NOT NULL;

-- 4. Índice compuesto para trazabilidad de reservas por línea de pedido y estado
CREATE INDEX IF NOT EXISTS idx_reserva_order_line_estado
    ON reserva (order_id, line_no, estado);

ANALYZE;


-- PASO 4: Ejecutar nuevamente EXPLAIN (ANALYZE, BUFFERS) DESPUÉS de crear los índices
-- Consulta Crítica A (ahora debe usar Index Scan / Bitmap Index Scan en idx_movimiento_lot_fecha)

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    l.sku_id,
    DATE_TRUNC('month', m.fecha) AS mes,
    m.tipo,
    COUNT(*) AS num_movs,
    SUM(m.cantidad) AS total_unidades
FROM movimiento m
         JOIN lote l ON l.lot_id = m.lot_id
WHERE m.lot_id = 3
  AND m.fecha >= NOW() - INTERVAL '60 days'
GROUP BY l.sku_id, DATE_TRUNC('month', m.fecha), m.tipo;

-- Consulta Crítica B (ahora usa Index Scan en idx_movimiento_po_recepcion en lugar de Seq Scan sobre 100k filas)
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    dc.po_id,
    dc.line_no,
    dc.qty_ordered,
    COALESCE(SUM(m.cantidad), 0) AS qty_recibida
FROM detalle_compra dc
         LEFT JOIN movimiento m
                   ON m.po_id = dc.po_id
                       AND m.po_line_no = dc.line_no
                       AND m.tipo = 'RECEPCION'
WHERE dc.po_id = 1
GROUP BY dc.po_id, dc.line_no, dc.qty_ordered;

-- Consulta Crítica C (usa idx_lote_sku_fefo evitando ordenamiento en memoria Sort)
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    el.lot_id,
    el.location_id,
    l.lot_code,
    l.vence_en,
    (el.qty_on_hand - el.qty_reserved) AS disponible
FROM existencia_lote el
         JOIN lote l ON l.lot_id = el.lot_id
WHERE l.sku_id = 1
  AND (l.vence_en IS NULL OR l.vence_en > CURRENT_DATE)
  AND (el.qty_on_hand - el.qty_reserved) > 0
ORDER BY l.vence_en ASC NULLS LAST, l.recibido_en ASC, el.lot_id ASC;